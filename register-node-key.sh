#!/usr/bin/env bash
# register-node-key — operator-pull of a fleet node's convergence plan key into
# core's key directory, so core can HMAC-verify the signed plans that node runs.
#
# THE FLEET KEY HANDSHAKE (no special-casing, rides existing infra):
#   1. The node's `lib/94-chief-fleet-convergence.sh` generates /etc/chief/node-plan.key
#      AND a user-readable copy at ~/.hermes/node-plan.key (0600).
#   2. This script (run on the control hub, h-do1, where core runs) resolves the
#      host from the host registry (~/.hermes/hosts/<host>.yaml), SSHes over the
#      tailnet (the same channel deploy-node.sh uses), reads that copy, and writes
#      it into core's CHIEF_NODE_PLAN_SECRET_DIR as <node_id>.key.
#   3. Core reads <dir>/<node_id>.key for any node — no per-node env wiring.
#
# Trust direction is hub -> node only (already required for deploys). No node->core
# inbound trust, works identically Linux/macOS. Secret travels host-to-host over
# the tailnet, never through a clipboard.
#
# Usage:
#   register-node-key h-air2          # one host
#   register-node-key all             # every host in the registry with a key
set -euo pipefail

HOSTS_DIR="${HERMES_HOME:-$HOME/.hermes}/hosts"
# Core's host-side key dir = the bind-mount source in docker-compose.hdo1.yml
# (core sees it at /etc/chief/node-keys via the ro mount).
KEY_DIR="${CHIEF_NODE_KEY_DIR:-/root/code/chief/chief-stack/node-keys}"

log() { printf '\033[36m[register-node-key %s]\033[0m %s\n' "$1" "$2" >&2; }
err() { printf '\033[31m[register-node-key %s] ERROR:\033[0m %s\n' "$1" "$2" >&2; }

# Resolve ssh_user@ssh_host from the registry (canonical fleet SSH resolution).
resolve_ssh() {
  local host="$1" yaml="$HOSTS_DIR/$1.yaml"
  [[ -f "$yaml" ]] || { err "$host" "no registry entry $yaml"; return 2; }
  local user ip
  user="$(grep -E '^ssh_user:' "$yaml" | head -1 | sed -E 's/.*:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')"
  ip="$(grep -E '^ssh_host:' "$yaml" | head -1 | sed -E 's/.*:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')"
  [[ -z "$ip" ]] && ip="$(grep -E '^tailscale_ip:' "$yaml" | head -1 | sed -E 's/.*:[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')"
  [[ -n "$user" && -n "$ip" ]] || { err "$host" "could not resolve ssh_user/ssh_host from $yaml"; return 2; }
  printf '%s@%s' "$user" "$ip"
}

register_one() {
  local host="$1"
  # h-do1 (the hub itself) reads its key locally, not over SSH.
  if [[ "$host" == "$(hostname -s 2>/dev/null)" || "$host" == "h-do1" ]]; then
    log "$host" "local hub — copying /etc/chief/node-plan.key"
    [[ -r /etc/chief/node-plan.key ]] || { err "$host" "/etc/chief/node-plan.key not readable here"; return 1; }
    mkdir -p "$KEY_DIR"; umask 077
    tr -d '\n' < /etc/chief/node-plan.key > "$KEY_DIR/$host.key"
    chmod 600 "$KEY_DIR/$host.key"
    log "$host" "✓ wrote $KEY_DIR/$host.key ($(wc -c < "$KEY_DIR/$host.key") bytes)"
    return 0
  fi
  local tgt; tgt="$(resolve_ssh "$host")" || return $?
  if ! ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$tgt" 'true' 2>/dev/null; then
    err "$host" "unreachable over tailnet ($tgt) — skip; re-run when online"
    return 1
  fi
  log "$host" "pulling plan key from $tgt:~/.hermes/node-plan.key"
  mkdir -p "$KEY_DIR"; umask 077
  # Pull the user-readable copy; strip any trailing newline to match core's raw read.
  if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$tgt" 'cat ~/.hermes/node-plan.key' 2>/dev/null \
       | tr -d '\n' > "$KEY_DIR/$host.key" && [[ -s "$KEY_DIR/$host.key" ]]; then
    chmod 600 "$KEY_DIR/$host.key"
    log "$host" "✓ registered $KEY_DIR/$host.key ($(wc -c < "$KEY_DIR/$host.key") bytes)"
  else
    rm -f "$KEY_DIR/$host.key"
    err "$host" "could not read ~/.hermes/node-plan.key on $tgt (did lib/94 run there?)"
    return 1
  fi
}

main() {
  local target="${1:-}"
  [[ -z "$target" ]] && { err "-" "usage: register-node-key <host|all>"; exit 2; }
  local rc=0
  if [[ "$target" == "all" ]]; then
    for y in "$HOSTS_DIR"/*.yaml; do
      [[ -e "$y" ]] || continue
      local h; h="$(basename "$y" .yaml)"
      [[ "$h" == *.live ]] && continue
      register_one "$h" || rc=1
    done
  else
    register_one "$target" || rc=$?
  fi
  [[ $rc -eq 0 ]] && log "-" "done. Core reads these on the next plan request (no restart needed)."
  exit $rc
}
main "$@"
