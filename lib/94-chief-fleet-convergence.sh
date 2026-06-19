#!/usr/bin/env bash
# 94-chief-fleet-convergence: install converger/supervisor, units, and plan key.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

# REPO_ROOT is exported by bootstrap.sh when run through the normal chain. When
# this module is run STANDALONE (e.g. `sudo bash lib/94-chief-fleet-convergence.sh`
# during a manual Mac convergence install), derive it from this script's own
# location so the `$REPO_ROOT/...` install paths resolve.
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

step "Chief fleet convergence"

if is_skipped chief-convergence; then
  skip "Chief fleet convergence skipped"
  exit 0
fi

require_sudo

node_id="${HERMES_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"
core_url="${CHIEF_CORE_URL:-http://100.122.202.37:8088}"

install_bin() {
  local src="$1" dst="$2"
  sudo install -m 0755 "$REPO_ROOT/$src" "$dst"
}

ensure_chief_group() {
  if [[ "$OS" == "macos" ]]; then
    if ! dscl . -read /Groups/chief >/dev/null 2>&1; then
      sudo dseditgroup -o create chief
    fi
  elif ! getent group chief >/dev/null 2>&1; then
    sudo groupadd --system chief
  fi
}

provision_plan_key() {
  sudo install -d -m 0750 -o root -g chief /etc/chief
  if [[ ! -f /etc/chief/node-plan.key ]]; then
    info "generating /etc/chief/node-plan.key"
    umask 077
    key_tmp="$(mktemp)"
    python3 - <<'PY' > "$key_tmp"
import base64, secrets
print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("="))
PY
    sudo install -m 0640 -o root -g chief "$key_tmp" /etc/chief/node-plan.key
    rm -f "$key_tmp"
  else
    skip "/etc/chief/node-plan.key already exists"
    sudo chown root:chief /etc/chief/node-plan.key
    sudo chmod 0640 /etc/chief/node-plan.key
  fi
}

write_node_env() {
  tmp="$(mktemp)"
  {
    printf 'CHIEF_NODE_ID=%s\n' "$node_id"
    printf 'CHIEF_CORE_URL=%s\n' "$core_url"
    printf 'CHIEF_NODE_PLAN_KEY=/etc/chief/node-plan.key\n'
    printf 'CHIEF_NODE_AUTH_TOKEN=/etc/chief/node-auth.token\n'
  } > "$tmp"
  sudo install -m 0640 -o root -g chief "$tmp" /etc/chief/node.env
  rm -f "$tmp"
}

install_supervisor_allowlist() {
  if [[ ! -f /etc/chief/supervisor-allowlist.json ]]; then
    tmp="$(mktemp)"
    printf '%s\n' '{"units":["chief-node.service","chief-loop-watchdog.service","chief-stack-core-1"]}' > "$tmp"
    sudo install -m 0640 -o root -g chief "$tmp" /etc/chief/supervisor-allowlist.json
    rm -f "$tmp"
  else
    skip "/etc/chief/supervisor-allowlist.json already exists"
  fi
}

install_systemd_units() {
  [[ "$OS" != "macos" ]] || return 0
  if ! have systemctl; then
    warn "systemctl not present; skipping systemd units"
    return 0
  fi
  sudo install -m 0644 "$REPO_ROOT/systemd/chief-node.service" /etc/systemd/system/chief-node.service
  sudo install -m 0644 "$REPO_ROOT/systemd/chief-node-reconcile.service" /etc/systemd/system/chief-node-reconcile.service
  sudo install -m 0644 "$REPO_ROOT/systemd/chief-node-supervisor.service" /etc/systemd/system/chief-node-supervisor.service
  sudo install -m 0644 "$REPO_ROOT/systemd/chief-node-supervisor.timer" /etc/systemd/system/chief-node-supervisor.timer
  sudo install -m 0644 "$REPO_ROOT/systemd/chief-node-converger.service" /etc/systemd/system/chief-node-converger.service
  sudo systemctl daemon-reload
  ok "installed chief node systemd units"
}

install_launchd_plists() {
  [[ "$OS" == "macos" ]] || return 0
  sudo install -m 0644 "$REPO_ROOT/launchd/com.chief.node-reconcile.plist" /Library/LaunchDaemons/com.chief.node-reconcile.plist
  sudo install -m 0644 "$REPO_ROOT/launchd/com.chief.node-supervisor.plist" /Library/LaunchDaemons/com.chief.node-supervisor.plist
  ok "installed chief node launchd plists"
}

ensure_chief_group
sudo install -d -m 0750 -o root -g chief /var/lib/chief/converger
if [[ "$OS" == "macos" ]]; then
  sudo install -d -m 0750 -o root -g chief /var/run/chief
else
  sudo install -d -m 0750 -o root -g chief /run/chief/convergence 2>/dev/null || true
fi
install_bin scripts/hermes-converger /usr/local/bin/hermes-converger
install_bin scripts/chief-node-supervisor /usr/local/bin/chief-node-supervisor
sudo install -d -m 0755 /usr/local/lib/hermes-host-bootstrap
sudo rm -rf /usr/local/lib/hermes-host-bootstrap/hermes_converger
sudo cp -R "$REPO_ROOT/hermes_converger" /usr/local/lib/hermes-host-bootstrap/
sudo chmod -R go-w /usr/local/lib/hermes-host-bootstrap/hermes_converger
provision_plan_key
write_node_env
install_supervisor_allowlist
install_systemd_units
install_launchd_plists

ok "Chief fleet convergence installed"
