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
    # NO trailing newline: the converger strips, but core's dir-read uses raw
    # read_bytes(); generating newline-free makes both sides agree byte-for-byte.
    python3 - <<'PY' > "$key_tmp"
import base64, secrets, sys
sys.stdout.write(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("="))
PY
    sudo install -m 0640 -o root -g chief "$key_tmp" /etc/chief/node-plan.key
    rm -f "$key_tmp"
  else
    skip "/etc/chief/node-plan.key already exists"
    sudo chown root:chief /etc/chief/node-plan.key
    sudo chmod 0640 /etc/chief/node-plan.key
  fi
  # Drop a user-readable copy for the control hub to PULL during provisioning.
  # The fleet key handshake is OPERATOR-PULL (control hub -> node over the tailnet
  # SSH it already has), NOT node-push-into-core. This copy is the ONLY thing the
  # puller reads; it carries the same bytes as /etc/chief/node-plan.key with no
  # trailing newline. 0600, owned by the SSH/login user. register-node-key on the
  # hub copies it into core's CHIEF_NODE_PLAN_SECRET_DIR as <node_id>.key.
  local luser="${SUDO_USER:-$(id -un)}"
  local lhome; lhome="$(eval echo "~${luser}")"
  if [[ -n "$lhome" && -d "$lhome" ]]; then
    sudo install -d -m 0700 -o "$luser" "$lhome/.hermes" 2>/dev/null || mkdir -p "$lhome/.hermes"
    sudo cat /etc/chief/node-plan.key | sudo tee "$lhome/.hermes/node-plan.key" >/dev/null
    sudo chown "$luser" "$lhome/.hermes/node-plan.key"
    sudo chmod 0600 "$lhome/.hermes/node-plan.key"
    ok "wrote operator-pull copy: $lhome/.hermes/node-plan.key (0600, $luser)"
  fi
}

# Scoped, passwordless sudo for the two convergence executors so they can run
# unattended (boot-reconcile, supervisor timer, cron-driven convergence) without
# a TTY/password. This is the ONLY ongoing root the convergence system needs —
# both binaries are HMAC-signed-plan-gated + allowlisted, so this is narrow, not
# blanket sudo. Validated with visudo before install (a bad file can't lock out
# sudo). Idempotent.
install_sudoers() {
  local user="${SUDO_USER:-$(id -un)}"
  local f=/etc/sudoers.d/chief-converger
  local tmp; tmp="$(mktemp)"
  {
    echo "# Chief fleet convergence: scoped NOPASSWD for the two root-write executors."
    echo "# Managed by hermes-host-bootstrap lib/94-chief-fleet-convergence.sh — do not edit by hand."
    echo "${user} ALL=(root) NOPASSWD: /usr/local/bin/hermes-converger"
    echo "${user} ALL=(root) NOPASSWD: /usr/local/bin/chief-node-supervisor"
  } > "$tmp"
  if sudo visudo -c -f "$tmp" >/dev/null 2>&1; then
    sudo install -m 0440 -o root -g wheel "$tmp" "$f" 2>/dev/null \
      || sudo install -m 0440 "$tmp" "$f"
    ok "installed scoped sudoers ($f) for $user -> hermes-converger + chief-node-supervisor"
  else
    warn "sudoers candidate failed visudo -c — NOT installing (convergence will need a password)"
  fi
  rm -f "$tmp"
}

# NOTE: key registration is OPERATOR-PULL, not node-push. The node only writes a
# user-readable copy of its plan key (see provision_plan_key). The control hub
# (h-do1, where core runs) pulls it over the tailnet SSH it already has and
# deposits it into core's CHIEF_NODE_PLAN_SECRET_DIR — via `register-node-key
# <host>` (folded into deploy-node.sh). This keeps a single trust direction
# (hub -> node, already required for deploys), needs no node->core inbound trust,
# and works identically on every OS. Until the hub pulls the key, convergence is
# fail-closed (plan endpoint 403) — safe, not silent-bad.

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
install_sudoers
write_node_env
install_supervisor_allowlist
install_systemd_units
install_launchd_plists

ok "Chief fleet convergence installed"
ok "Next (on the control hub): register-node-key ${node_id}   # pulls the key into core"
