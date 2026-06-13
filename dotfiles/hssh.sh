# ── hermes-host-bootstrap hssh helper ──
# shellcheck shell=sh
# A small wrapper to ssh into a remote host and attach (or create) a named
# tmux session in one shot. Pairs with the server-side tmux auto-attach.
#
# Usage:
#   hssh                         → ssh into $HSSH_DEFAULT_HOST, attach "main"
#   hssh <session>               → ssh into $HSSH_DEFAULT_HOST, attach session
#   hssh <host>                  → ssh into <host>, attach "main"
#   hssh <session> <host>        → ssh into <host>, attach session
#
# Host resolution:
#   - user@host is used verbatim
#   - host looks up ~/.hermes/hosts/<host>.yaml and prepends default_user
#   - HSSH_DEFAULT_HOST is used when no host is supplied
#
# Configure the default host once in your shell rc, e.g.:
#   export HSSH_DEFAULT_HOST="h-do1"
#
# Disconnect/reconnect-safe: `tmux new -As <name>` attaches if the session
# already exists, otherwise creates it. Detach with the tmux prefix + d.

_hssh_field() {
  _hssh_file="$1"
  _hssh_key="$2"
  [ -f "$_hssh_file" ] || return 1
  awk -v key="$_hssh_key" '
    $0 ~ "^[[:space:]]*"key":" {
      sub("^[[:space:]]*"key":[[:space:]]*", "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$_hssh_file"
}

_hssh_known_host() {
  _hssh_name="$1"
  _hssh_home="${HERMES_HOME:-$HOME/.hermes}"
  [ -n "$_hssh_name" ] && [ -f "$_hssh_home/hosts/$_hssh_name.yaml" ]
}

_hssh_resolve_host() {
  _hssh_host="$1"
  case "$_hssh_host" in
    *@*|'') printf '%s\n' "$_hssh_host"; return 0 ;;
  esac

  _hssh_home="${HERMES_HOME:-$HOME/.hermes}"
  _hssh_file="$_hssh_home/hosts/$_hssh_host.yaml"
  if [ -f "$_hssh_file" ]; then
    _hssh_user="$(_hssh_field "$_hssh_file" ssh_user)"
    [ -n "$_hssh_user" ] || _hssh_user="$(_hssh_field "$_hssh_file" default_user)"

    _hssh_target="$(_hssh_field "$_hssh_file" ssh_host)"
    [ -n "$_hssh_target" ] || _hssh_target="$(_hssh_field "$_hssh_file" tailscale_ip)"
    [ -n "$_hssh_target" ] || _hssh_target="$(_hssh_field "$_hssh_file" tailscale_name)"
    [ -n "$_hssh_target" ] || _hssh_target="$_hssh_host"

    if [ -n "$_hssh_user" ] && [ "$_hssh_user" != "unknown" ]; then
      printf '%s@%s\n' "$_hssh_user" "$_hssh_target"
      return 0
    fi
    printf '%s\n' "$_hssh_target"
    return 0
  fi

  # No registry default: leave the host alone so ~/.ssh/config can still
  # supply User/HostName, or ssh can fall back to the local username.
  printf '%s\n' "$_hssh_host"
}

hssh() {
  session="main"
  host=""

  case "$#" in
    0)
      host="${HSSH_DEFAULT_HOST:-}"
      ;;
    1)
      # Guard against pasted shell comments leaking in as arguments. zsh does not
      # treat `#` as a comment by default in interactive shells.
      case "$1" in
        '#'* ) host="${HSSH_DEFAULT_HOST:-}" ;;
        *@* ) host="$1" ;;
        *.* ) host="$1" ;;
        * )
          if _hssh_known_host "$1"; then
            host="$1"
          else
            session="$1"
            host="${HSSH_DEFAULT_HOST:-}"
          fi
          ;;
      esac
      ;;
    *)
      session="$1"
      host="$2"
      case "$host" in
        '#'* ) host="${HSSH_DEFAULT_HOST:-}" ;;
      esac
      ;;
  esac

  if [ -z "$host" ]; then
    echo "hssh: no host given and HSSH_DEFAULT_HOST is unset" >&2
    echo "usage: hssh [session] [user@host|host]" >&2
    echo "examples: hssh              # main on default host" >&2
    echo "          hssh h-do1        # main on h-do1 (uses hosts/h-do1.yaml default_user)" >&2
    echo "          hssh code h-do1   # code on h-do1" >&2
    echo "(zsh tip: 'setopt interactive_comments' to make trailing '# notes' work like bash)" >&2
    return 2
  fi

  host="$(_hssh_resolve_host "$host")"

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
