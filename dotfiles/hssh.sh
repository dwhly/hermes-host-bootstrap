# ── hermes-host-bootstrap hssh helper ──
# shellcheck shell=sh
# A small wrapper to ssh into a remote host and attach (or create) a named
# tmux session in one shot. Pairs with the server-side tmux auto-attach.
#
# Usage:
#   hssh <session>                  → ssh into $HSSH_DEFAULT_HOST, attach session
#   hssh <session> <host>           → ssh into <host>, attach session
#   hssh                            → ssh into $HSSH_DEFAULT_HOST, attach "main"
#
# Configure the default host once in your shell rc, e.g.:
#   export HSSH_DEFAULT_HOST="root@hermes-do1"
#
# Disconnect/reconnect-safe: `tmux new -As <name>` attaches if the session
# already exists, otherwise creates it. Detach with the tmux prefix + d.

hssh() {
  session="${1:-main}"
  host="${2:-${HSSH_DEFAULT_HOST:-}}"
  if [ -z "$host" ]; then
    echo "hssh: no host given and HSSH_DEFAULT_HOST is unset" >&2
    echo "usage: hssh <session> [user@host]   or   export HSSH_DEFAULT_HOST=user@host" >&2
    return 2
  fi
  # -t forces a remote TTY (required by tmux).
  # Single-quote the remote command so $session expands locally only.
  ssh -t "$host" "tmux new -As '$session'"
}
