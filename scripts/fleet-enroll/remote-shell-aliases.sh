#!/usr/bin/env bash
# remote-shell-aliases.sh — runs ON the target as root. Installs the fleet shell aliases (hm, hmw, hmx, ...)
# for each named local account: the same file + rc source line that lib/30-shell.sh installs on fully
# bootstrapped hosts. Baseline-enrolled hosts never run 30-shell, so this is how they get the aliases.
#
#   remote-shell-aliases.sh <user>...     (e.g. root hermes)
#
# Additive and idempotent: copies one file per account and appends a marker + source line to each of the
# account's EXISTING .bashrc/.zshrc/.profile when missing. Never creates accounts or rc files.
# Safety: every write into a non-root home runs AS that account (runuser), so symlinks the account
# controls can only redirect writes to files it could already write. A symlinked alias file is treated
# as managed elsewhere (a full-bootstrap checkout) and left alone.
set -euo pipefail
src=/opt/hermes-host-bootstrap-baseline/dotfiles/aliases.sh
[[ -f "$src" ]] || { echo "missing $src"; exit 1; }
(( $# > 0 )) || { echo "usage: remote-shell-aliases.sh <user>..."; exit 2; }
n_aliases="$(grep -c '^alias ' "$src" || true)"
rc_status=0

# as_user <user> <uid> <cmd...>: root runs directly; anyone else runs via runuser, so the kernel enforces
# that account's own permissions (environment is inherited; nothing here depends on it). A failed write
# stops the script (set -e): fail closed, later accounts are not processed.
as_user() {
  local user="$1" uid="$2"; shift 2
  if [[ "$uid" == 0 ]]; then "$@"; else runuser -u "$user" -- "$@"; fi
}

for user in "$@"; do
  if [[ ! "$user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then echo "$user: invalid account name; skipped"; rc_status=1; continue; fi
  if ! entry="$(getent passwd "$user")"; then echo "$user: no such account; skipped (accounts are never created)"; rc_status=1; continue; fi
  uid="$(printf '%s' "$entry" | cut -d: -f3)"
  home="$(printf '%s' "$entry" | cut -d: -f6)"
  if [[ -z "$home" || "$home" == / || ! -d "$home" || -L "$home" ]]; then
    echo "$user: home '$home' unusable (missing, /, or a symlink); skipped"; rc_status=1; continue
  fi
  if [[ "$(stat -c %u "$home")" != "$uid" ]]; then
    echo "$user: home $home is not owned by uid $uid; skipped"; rc_status=1; continue
  fi
  dest="$home/.hermes-host-bootstrap.aliases.sh"
  if [[ -L "$dest" ]]; then
    echo "$user: $dest is a symlink (managed by a full bootstrap); left alone"; continue
  fi
  # Readable copy for the account; written by the account itself when not root.
  as_user "$user" "$uid" install -m 0644 /dev/stdin "$dest" <"$src"
  line="[ -f $dest ] && . $dest"
  wired=0
  for rc in "$home/.bashrc" "$home/.zshrc" "$home/.profile"; do
    [[ -f "$rc" ]] || continue
    # Loose match: any existing source of the alias file (30-shell's or ours) counts as wired.
    as_user "$user" "$uid" sh -c 'grep -qF ".hermes-host-bootstrap.aliases.sh" "$2" || printf "\n# ── hermes-host-bootstrap shell aliases ──\n%s\n" "$1" >>"$2"' _ "$line" "$rc"
    wired=$((wired + 1))
  done
  if (( wired == 0 )); then
    echo "$user: warning: no .bashrc/.zshrc/.profile in $home; aliases file installed but not sourced"
  else
    echo "$user: shell aliases installed ($n_aliases aliases, $wired rc files)"
  fi
done
exit "$rc_status"
