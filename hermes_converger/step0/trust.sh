#!/bin/sh
# Sourced only after the dispatcher has checked this file and all its parents.
# No caller-controlled executable lookup, Python startup, or shell evaluation.
# HOLD_REASON and read_state's value are outputs to the sourcing dispatcher.
# shellcheck disable=SC2034
set -eu
TRUST_OS=$(/usr/bin/uname -s)
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

hold() { HOLD_REASON=$*; printf 'chief Step 0 HOLD: %s\n' "$*" >&2; return 1; }

# Installed entries use a fixed, symlink-free chain. Check all of it in one stat
# and (on macOS) one ACL listing, before sourcing any file. No recursive forks.
# Darwin's state/config paths use /private directly, avoiding /var and /etc links.
trusted_entries() {
    STATE=/var/lib/chief/currency-step0
    CONFIG=/etc/chief/node.env
    REQUESTS=/var/lib/chief/requests
    if [ "$TRUST_OS" = Darwin ]; then
        STATE=/private/var/lib/chief/currency-step0
        CONFIG=/private/etc/chief/node.env
        REQUESTS=/private/var/lib/chief/requests
    fi
    # These are the complete fixed chains, not caller-supplied paths. stat uses
    # lstat (no -L); type bits reject links without one extra syscall per path.
    set -- / /opt /opt/chief /opt/chief/bin /opt/chief/lib \
        /opt/chief/lib/hermes-host-bootstrap "$BASE/.." "$BASE" \
        "$BASE/trust.sh" "$BASE/pulse.sh" "$BASE/supervise.sh" \
        /opt/chief/bin/hermes-converger /opt/chief/bin/chief-node-supervisor /opt/chief/bin/chief-update \
        "$STATE" "$CONFIG" "$REQUESTS"
    if [ "$TRUST_OS" = Darwin ]; then
        set -- "$@" /private /private/var /private/var/lib /private/var/lib/chief /private/etc /private/etc/chief /private/var/log
        # Include existing launchd logs in the same trust/ACL batch. Truncating
        # in place retains launchd's open append descriptors and adds no fork.
        for log in /private/var/log/com.chief.node-reconcile.log /private/var/log/com.chief.node-reconcile.err \
                   /private/var/log/com.chief.node-supervisor.log /private/var/log/com.chief.node-supervisor.err \
                   /private/var/log/com.chief.update-request.log /private/var/log/com.chief.update-request.err; do
            if [ -e "$log" ] || [ -L "$log" ]; then set -- "$@" "$log"; fi
        done
    else
        set -- "$@" /var /var/lib /var/lib/chief /etc /etc/chief
    fi
    if [ "$TRUST_OS" = Darwin ]; then
        mode_base=0
        meta=$(/usr/bin/stat -f '%u %p %z %N' "$@") || return 1
        acl=$(/bin/ls -lde "$@") || return 1
        # ACL records start with a numbered entry; '+' also marks an ACL.
        while IFS= read -r row; do
            row=${row#"${row%%[![:space:]]*}"}
            case "$row" in ??????????+*|[0-9]*:*) hold entry_acl; return 1;; esac
        done <<EOF
$acl
EOF
    else
        mode_base=0x
        meta=$(/usr/bin/stat -c '%u %f' "$@") || return 1
    fi
    while read -r uid mode size path; do
        permissions=$(( ${mode_base}${mode} ))
        [ "$uid" = 0 ] && [ $((permissions & 0022)) -eq 0 ] &&
            [ $((permissions & 0170000)) -ne $((0120000)) ] || { hold unsafe_entry_chain; return 1; }
        case "$path" in /private/var/log/com.chief.*)
            [ $((permissions & 0170000)) -eq $((0100000)) ] || { hold unsafe_log; return 1; }
            if [ "$size" -ge 1048576 ]; then : > "$path"; fi;;
        esac
    done <<EOF
$meta
EOF
}

# State is root-written data beneath a verified directory, never shell code.
# Avoid forks, symlinks and special files on the minute path.
read_state() {
    value=$2
    if [ -f "$STATE/$1" ] && [ ! -L "$STATE/$1" ]; then
        IFS= read -r value < "$STATE/$1" || value=$2
    fi
}

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
        mode=$(/bin/ls -lde "$p") || exit 1
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

trusted_tree() (
    tree_depth=${2:-0}
    [ "$tree_depth" -lt 16 ] || { hold tree_symlink_cycle; exit 1; }
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
        trusted_path "$link" || exit 1
        if [ -d "$link" ]; then
            target=$(/usr/bin/readlink "$link")
            case "$target" in /*) ;; *) target=${link%/*}/$target;; esac
            trusted_tree "$target" "$((tree_depth + 1))" || exit 1
        fi
    done || return 1
    return 0
)

select_python() {
    if [ -x /opt/chief/python/bin/python3 ]; then
        PY=/opt/chief/python/bin/python3
        PY_TREE=/opt/chief/python
    elif [ "$TRUST_OS" = Darwin ]; then
        # Resolve Apple's xcrun shim by pinning CLT, never xcode-select/PATH.
        PY=/Library/Developer/CommandLineTools/usr/bin/python3
        PY_TREE=/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework
    else
        PY=/usr/bin/python3
        PY_TREE=/usr/lib
    fi
    export PY
}

trusted_python() {
    select_python
    trusted_path "$PY" || return 1
    if [ "$PY_TREE" = /usr/lib ]; then
        for lib in /usr/lib/python3.* /usr/lib/python3*.zip; do
            [ ! -e "$lib" ] || trusted_tree "$lib" || return 1
        done
    else
        trusted_tree "$PY_TREE" || return 1
    fi
    "$PY" -I -S -B -c 'import sys; sys.exit(sys.version_info < (3,9))' || {
        hold 'trusted Python >=3.9 unavailable'; return 1;
    }
}

# Full scans once per boot or root-managed identity change. Root-only trees
# cannot be changed by the login account after verification. Root updaters must
# replace their tree (or remove trust-cache before an in-place runtime update).
# No Python or find on a cache hit. Cache contents are compared, never sourced.
trusted_runtime() {
    select_python
    cache=/var/lib/chief/currency-step0/trust-cache
    trusted_path "${cache%/*}" || return 1
    trusted_path "$PY" || return 1
    trusted_path "$PY_TREE" || return 1
    trusted_path "$BASE" || return 1
    if [ "$TRUST_OS" = Darwin ]; then
        boot_id=$(/usr/sbin/sysctl -n kern.bootsessionuuid) || return 1
        identity=$(/usr/bin/stat -L -f '%d:%i:%u:%g:%p:%z:%m:%c' "$PY" "$PY_TREE" "$BASE" "$BASE/.." "$BASE/trust.sh" "$BASE/pulse.sh" "$BASE/supervise.sh") || return 1
    else
        boot_id=$(/bin/cat /proc/sys/kernel/random/boot_id) || return 1
        identity=$(/usr/bin/stat -L -c '%d:%i:%u:%g:%f:%s:%y:%z' "$PY" "$PY_TREE" "$BASE" "$BASE/.." "$BASE/trust.sh" "$BASE/pulse.sh" "$BASE/supervise.sh") || return 1
    fi
    key="$boot_id
$PY
$identity"
    if [ -f "$cache" ]; then
        trusted_path "$cache" || return 1
        [ "$(/bin/cat "$cache")" != "$key" ] || return 0
    fi
    trusted_tree "$BASE/.." || return 1
    trusted_python || return 1
    tmp=$(/usr/bin/mktemp "${cache%/*}/.trust-cache.XXXXXX") || return 1
    printf '%s\n' "$key" > "$tmp"
    /bin/chmod 0600 "$tmp"
    /bin/mv -f "$tmp" "$cache"
}
