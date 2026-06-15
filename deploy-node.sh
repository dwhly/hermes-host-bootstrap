#!/usr/bin/env bash
# deploy-node — idempotent, verified deploy of the Chief hermes-node agent to a fleet host.
#
# WHY: deploying a hermes-node change is a multi-step, per-host ritual (sync node code +
# sync chief-spec SDK + reinstall venv + restart the daemon + confirm the new-shape emit
# landed). Doing it by hand, half-finished, is how nodes end up silently serving
# stale/absent data (manifest vanishes, version-drift shows unknown). This script makes
# the ritual atomic and SELF-VERIFYING so it can't be half-done without you noticing.
#
# Usage:
#   deploy-node h-do1                # local systemd host (run on h-do1)
#   deploy-node h-mini2              # remote Mac (launchd) over ssh
#   deploy-node h-mini
#   deploy-node all                  # every known host
#
# Read-only-safe: only syncs code, reinstalls the venv, restarts the daemon, and emits.
set -euo pipefail

CORE="${CHIEF_CORE_URL:-http://100.122.202.37:8088}"
SRC_ROOT="${CHIEF_SRC_ROOT:-/root/code/chief}"          # source of truth on h-do1
BOOTSTRAP_SRC="${CHIEF_BOOTSTRAP_SRC:-/root/projects/hermes-host-bootstrap}"

# host  -> "ssh_target|home|role"   (ssh_target empty = local)
declare -A HOSTS=(
  [h-do1]="|/root|server"
  [h-mini2]="dano@h-mini2|/Users/dano|both"
  [h-mini]="danz@h-mini|/Users/dan_1|both"
)

log() { printf '\033[36m[deploy-node %s]\033[0m %s\n' "$1" "$2" >&2; }
err() { printf '\033[31m[deploy-node %s] ERROR:\033[0m %s\n' "$1" "$2" >&2; }

deploy_one() {
  local host="$1"
  local spec="${HOSTS[$host]:-}"
  [[ -z "$spec" ]] && { err "$host" "unknown host"; return 2; }
  local ssh_target="${spec%%|*}" rest="${spec#*|}"
  local home="${rest%%|*}" role="${rest##*|}"
  local node_dir="$home/code/chief/hermes-node"
  local spec_dir="$home/code/chief/chief-spec/sdk/python"
  local bootstrap_dir="$home/projects/hermes-host-bootstrap"

  # --- reachability (Macs sleep) ---
  if [[ -n "$ssh_target" ]]; then
    if ! ssh -o ConnectTimeout=10 "$ssh_target" 'true' 2>/dev/null; then
      err "$host" "unreachable (asleep/offline) — skipping; re-run when it's online"
      return 1
    fi
  fi

  # --- 1. sync node code + chief-spec SDK + verify.sh ---
  log "$host" "syncing node code + chief-spec SDK + verify.sh"
  local RS=(rsync -a --delete --exclude '.venv' --exclude '.git' --exclude '__pycache__')
  # h-mini's openrsync chokes on -z; drop compression universally (small payload).
  if [[ -z "$ssh_target" ]]; then
    : # local h-do1 is the source; nothing to sync
  else
    "${RS[@]}" "$SRC_ROOT/hermes-node/"      "$ssh_target:$node_dir/"
    "${RS[@]}" "$SRC_ROOT/chief-spec/sdk/"   "$ssh_target:$home/code/chief/chief-spec/sdk/"
    rsync -a "$BOOTSTRAP_SRC/verify.sh"      "$ssh_target:$bootstrap_dir/verify.sh"
  fi

  # --- 2. set role (idempotent) ---
  log "$host" "setting role=$role"
  if [[ -z "$ssh_target" ]]; then
    mkdir -p "$home/.hermes"; printf '%s\n' "$role" > "$home/.hermes/node-role"
  else
    ssh "$ssh_target" "mkdir -p ~/.hermes && printf '%s\n' '$role' > ~/.hermes/node-role"
  fi

  # --- 3. reinstall venv (editable: node + spec SDK) ---
  log "$host" "reinstalling venv (uv pip install -e spec + node)"
  local PIP="export PATH=\"\$HOME/.local/bin:\$PATH\"; cd $node_dir && uv pip install --python .venv/bin/python -q -e ../chief-spec/sdk/python -e ."
  if [[ -z "$ssh_target" ]]; then bash -lc "$PIP"; else ssh "$ssh_target" "$PIP"; fi

  # --- 4. restart the daemon so it loads the new code (NOT just file-sync) ---
  log "$host" "restarting the node daemon"
  if [[ -z "$ssh_target" ]]; then
    systemctl restart chief-node.service
  else
    ssh "$ssh_target" 'launchctl kickstart -k "gui/$(id -u)/com.chief.node" 2>/dev/null || launchctl kickstart -k "user/$(id -u)/com.chief.node"'
  fi

  # --- 5. nudge a fresh provisioning emit (don't wait for the loop) ---
  log "$host" "emitting provisioning + state to confirm the pipeline"
  local EMIT="export PATH=\"\$HOME/.local/bin:\$PATH\"; cd $node_dir && .venv/bin/python -m hermes_node.daemon emit-provisioning --node-id $host --core $CORE >/dev/null 2>&1 && .venv/bin/python -m hermes_node.daemon state --node-id $host --core $CORE --repo-dir $bootstrap_dir >/dev/null 2>&1"
  if [[ -z "$ssh_target" ]]; then bash -lc "$EMIT"; else ssh "$ssh_target" "$EMIT"; fi

  # --- 6. VERIFY the emit landed (the step that makes half-deploys impossible) ---
  sleep 2
  log "$host" "verifying provisioning landed in core"
  local checks
  checks="$(curl -s "$CORE/v1/fleet/nodes/$host" | python3 -c "
import sys,json
d=json.load(sys.stdin)
prov=d.get('provisioning') or {}
ch=prov.get('checks') or []
cats=sorted(set(c.get('category') for c in ch if c.get('category')))
ok = len(ch)>0 and len(cats)>0 and d.get('role') is not None
print(('OK' if ok else 'FAIL'), 'checks=%d cats=%s role=%r' % (len(ch), cats, d.get('role')))
")"
  if [[ "$checks" == OK* ]]; then
    log "$host" "✓ DEPLOY VERIFIED — $checks"
    return 0
  else
    err "$host" "deploy did NOT verify — $checks (node may not be emitting the new shape)"
    return 1
  fi
}

main() {
  local target="${1:-}"
  [[ -z "$target" ]] && { err "-" "usage: deploy-node <host|all>"; exit 2; }
  local rc=0
  if [[ "$target" == "all" ]]; then
    for h in "${!HOSTS[@]}"; do deploy_one "$h" || rc=1; done
  else
    deploy_one "$target" || rc=$?
  fi
  exit $rc
}
main "$@"
