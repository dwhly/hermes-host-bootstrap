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
  # Guard against pasted shell comments leaking in as arguments. zsh does not
  # treat `#` as a comment by default in interactive shells, so a pasted line
  # like `hssh code  # connect to code` arrives as ($1=code, $2=#, $3=connect, ...).
  # Drop a leading '#' so we fall through to HSSH_DEFAULT_HOST instead of trying
  # to ssh to a host literally named '#'.
  case "$host" in
    '#'*) host="${HSSH_DEFAULT_HOST:-}" ;;
  esac
  if [ -z "$host" ]; then
    echo "hssh: no host given and HSSH_DEFAULT_HOST is unset" >&2
    echo "usage: hssh <session> [user@host]   or   export HSSH_DEFAULT_HOST=user@host" >&2
    echo "(zsh tip: 'setopt interactive_comments' to make trailing '# notes' work like bash)" >&2
    return 2
  fi
  # -t forces a remote TTY (required by tmux).
  # Single-quote the remote command so $session expands locally only.
  #
  # We tried `ghostty +ssh` (auto-installs xterm-ghostty terminfo on the
  # remote) but it has bugs in Ghostty 1.3.1 that produce invalid-action
  # errors and SIGTRAPs. Use plain ssh and rely on either:
  #   (a) `term = xterm-256color` in ~/.config/ghostty/config, or
  #   (b) one-time terminfo install on the remote.
  # See https://ghostty.org/docs/help/terminfo
  ssh -t "$host" "tmux new -As '$session'"
}
