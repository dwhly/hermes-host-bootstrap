#!/bin/sh
# Sourced only after the dispatcher has checked this file and all its parents.
# No caller-controlled executable lookup, Python startup, or shell evaluation.
set -eu
TRUST_OS=$(/usr/bin/uname -s)
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

hold() { printf 'chief Step 0 HOLD: %s\n' "$*" >&2; return 1; }

# Check both sides of every symlink, including directory symlinks (/var on Macs).
# Root-owned symlinks may have mode 0777; their parents must not be writable.
trusted_path() (
    depth=${2:-0}
    [ "$depth" -lt 64 ] || { hold symlink_cycle; exit 1; }
    p=${1%/}; [ -n "$p" ] || p=/
    case "$p" in /*) ;; *) hold "non-absolute path: $p"; exit 1;; esac
    [ "$p" = / ] || trusted_path "${p%/*}/" "$((depth + 1))" || exit 1
    p=${p%/}; [ -n "$p" ] || p=/
    if [ "$TRUST_OS" = Darwin ]; then
        mode=$(/bin/ls -lde "$p")
        case "$mode" in ??????????+*) hold "ACL on trusted path: $p"; exit 1;; esac
        if printf '%s\n' "$mode" | /usr/bin/grep -Eq '^[[:space:]]*[0-9]+:'; then
            hold "ACL on trusted path: $p"; exit 1
        fi
        meta=$(/usr/bin/stat -f '%u %Lp' "$p") || exit 1
    else
        meta=$(/usr/bin/stat -c '%u %a' "$p") || exit 1
    fi
    set -- $meta
    [ "$1" = 0 ] || { hold "not root-owned: $p"; exit 1; }
    if [ -L "$p" ]; then
        target=$(/usr/bin/readlink "$p") || exit 1
        case "$target" in /*) ;; *) target=${p%/*}/$target;; esac
        # Validate the lexical target chain too. Resolving to a safe realpath
        # alone would miss an attacker-owned intermediate directory/link.
        trusted_path "$target" "$((depth + 1))"
    else
        [ $((0$2 & 0022)) -eq 0 ] || { hold "writable path: $p"; exit 1; }
    fi
)

trusted_tree() {
    trusted_path "$1" || return 1
    # Do not follow tree symlinks. Validate their targets separately.
    bad=$(/usr/bin/find "$1" \( ! -user root -o \( ! -type l -perm -0020 \) -o \( ! -type l -perm -0002 \) \) -print -quit) || return 1
    [ -z "$bad" ] || { hold "untrusted tree: $bad"; return 1; }
    if [ "$TRUST_OS" = Darwin ]; then
        acl=$(/usr/bin/find "$1" -exec /bin/ls -lde {} +) || return 1
        if printf '%s\n' "$acl" | /usr/bin/grep -Eq '^[[:space:]]*[0-9]+:'; then
            hold "ACL in code/runtime tree: $1"; return 1
        fi
    fi
    /usr/bin/find "$1" -type l -print | while IFS= read -r link; do
        [ ! -d "$link" ] || { hold "directory symlink in runtime: $link"; exit 1; }
        trusted_path "$link" || exit 1
    done || return 1
    return 0
}

trusted_python() {
    # A standalone root-provisioned runtime is preferred; no Homebrew or venv.
    if [ -x /opt/chief/python/bin/python3 ]; then
        trusted_tree /opt/chief/python || return 1
        PY=/opt/chief/python/bin/python3
    elif [ "$TRUST_OS" = Linux ]; then
        PY=/usr/bin/python3
        trusted_path "$PY" || return 1
        # Check all possible system stdlib startup/import locations before Python.
        for lib in /usr/lib/python3.* /usr/lib/python3*.zip; do
            [ ! -e "$lib" ] || trusted_tree "$lib" || return 1
        done
    else
        # /usr/bin/python3 on macOS is an xcrun shim; Homebrew belongs to the
        # login user. Neither is a qualified pinned runtime.
        hold 'trusted Python unavailable; provision /opt/chief/python'; return 1
    fi
    export PY
}
