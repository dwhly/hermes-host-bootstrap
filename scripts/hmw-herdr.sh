#!/usr/bin/env bash
# hmw-herdr — EXPERIMENTAL prototype: the hmw workflow, but backed by herdr
# (the agent multiplexer) instead of tmux. See research/herdr.md.
#
# This mirrors hermes-workspace (hmw): resolve the host via the fleet registry,
# ssh -t to it, and bring up a persistent multi-pane workspace of hermes-pane
# sessions — except the persistence + panes come from herdr's server, not tmux.
# herdr's sidebar then shows each pane's agent state (blocked/working/done/idle).
#
# STATUS: prototype. Does NOT replace hmw. Requires `herdr` installed on the
# TARGET host (currently h-do1). Safe to delete.
#
# USAGE
#   hmw-herdr                 # attach/create herdr workspace on the default host (h-do1)
#   hmw-herdr <host>          # ... on <host>
#   hmw-herdr <host> N        # ensure N hermes-pane agents exist, then attach
#   hmw-herdr N               # N agents on the default host
set -uo pipefail

DEFAULT_HOST="${HMW_DEFAULT_HOST:-h-do1}"
SESSION="${HERDR_SESSION:-ws}"

# ── parse args: bare int = pane count, else host (order-independent, like hmw)
host=""; panes=""
for arg in "$@"; do
  if [[ "$arg" =~ ^[0-9]+$ ]]; then panes="$arg"; else host="$arg"; fi
done
panes="${panes:-2}"

# ── default-target resolution (skip self-ssh when already on the default host)
if [ -z "$host" ]; then
  default_bare="${DEFAULT_HOST##*@}"; default_bare="${default_bare%%.*}"
  here="$(hostname -s 2>/dev/null || hostname)"
  [ "$here" != "$default_bare" ] && host="$DEFAULT_HOST"
fi

# ── resolve ssh target through the fleet registry (same as hmw/hssh)
ssh_target=""
if [ -n "$host" ]; then
  case "$host" in
    *@*) ssh_target="$host" ;;
    *)
      if command -v hermes-host-resolve >/dev/null 2>&1; then
        ssh_target="$(hermes-host-resolve "$host" 2>/dev/null || true)"
      fi
      [ -n "$ssh_target" ] || ssh_target="$host"
      ;;
  esac
fi

# The remote command: ensure N hermes-pane agents exist in the herdr session via
# the socket API (idempotent-ish: only starts panes if the server has none), then
# attach the herdr TUI. If herdr isn't installed on the target, fail with a hint.
remote_cmd=$(cat <<REMOTE
export PATH="\$HOME/.local/bin:\$PATH"
if ! command -v herdr >/dev/null 2>&1; then
  echo "hmw-herdr: 'herdr' not installed on this host — install it (see research/herdr.md) first." >&2
  exit 1
fi
# Start the headless server if not running (nohup so it survives our attach).
if ! herdr status server 2>/dev/null | grep -q "status: running"; then
  nohup herdr server >/dev/null 2>&1 &
  sleep 1
fi
# If no agents yet, spawn N hermes-pane sessions labeled H1..HN over the socket API.
have=\$(herdr agent list 2>/dev/null | grep -o '"pane_id"' | wc -l | tr -d ' ')
n=\$have
while [ "\$n" -lt "$panes" ]; do
  n=\$((n+1))
  herdr agent start "H\$n" --split right -- hermes-pane "H\$n" >/dev/null 2>&1 || true
done
# Attach the herdr TUI (interactive).
exec herdr --session "$SESSION"
REMOTE
)

if [ -n "$ssh_target" ]; then
  exec ssh -t "$ssh_target" "\"\$SHELL\" -lc '$remote_cmd'"
else
  # local mode (already on the default host)
  export PATH="$HOME/.local/bin:$PATH"
  bash -lc "$remote_cmd"
fi
