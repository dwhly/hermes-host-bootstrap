#!/usr/bin/env bash
# S0-stack-boot: bring the control-plane Docker stacks (Chief, Buzz relay) up after EVERY boot. Control-plane host only.
#
# WHY: the stacks' compose services use `restart: unless-stopped`. Docker does not restart a container that was
# explicitly stopped, so after a maintenance quiesce (`docker compose stop`, then power-off, as in the h-do1 resize)
# Chief Core stayed DOWN after boot. For ~45 min every fleet node lost its boss and the converger check-ins failed.
# These oneshot units re-assert the desired state at boot, whatever stopped the containers.
#
# Deliberately untiered beyond E: this is incident-driven infrastructure for the boss host.
# Gate: the host must actually own the control-plane tailnet IP that the compose overlays bind to (100.122.202.37).
# Any other headless Linux box with a Chief checkout counts as role=server but must NOT start an h-do1-shaped stack.
# Installs: chief-stack.service, buzz-prod.service (enabled + restarted; only when that stack's dir exists).
# Skip key: stack-boot.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONTROL_PLANE_IP="100.122.202.37"

step "Control-plane stacks come up after every boot (systemd)"

if ! tier_allows E; then
  skip "stack-boot skipped (tier below E)"
  return 0 2>/dev/null || exit 0
fi
if is_skipped stack-boot; then
  skip "stack-boot skipped (HERMES_SKIP includes stack-boot)"
  return 0 2>/dev/null || exit 0
fi
if ! role_includes server; then
  skip "role=$ROLE — the Chief/Buzz stacks run on the server/control-plane host only"
  return 0 2>/dev/null || exit 0
fi
if [[ "$OS" == "macos" ]] || ! have systemctl; then
  skip "no systemd on this host — stack-boot units not applicable"
  return 0 2>/dev/null || exit 0
fi
if ! ip -4 addr show 2>/dev/null | grep -q "inet ${CONTROL_PLANE_IP}/"; then
  skip "this host does not own the control-plane IP ${CONTROL_PLANE_IP} — not the boss; stack-boot not applicable"
  return 0 2>/dev/null || exit 0
fi

declare -A STACK_DIR=([chief-stack]=/root/code/chief/chief-stack [buzz-prod]=/root/services/buzz)
installed=()
for unit in chief-stack buzz-prod; do
  if [[ ! -d "${STACK_DIR[$unit]}" ]]; then
    skip "$unit: ${STACK_DIR[$unit]} not present on this host"
    continue
  fi
  info "installing $unit.service"
  sudo install -m 0644 "$REPO_ROOT/systemd/$unit.service" "/etc/systemd/system/$unit.service"
  installed+=("$unit")
done
if (( ${#installed[@]} )); then
  sudo systemctl daemon-reload
  for unit in "${installed[@]}"; do
    sudo systemctl enable "$unit.service" >/dev/null 2>&1 || warn "could not enable $unit.service"
    # restart (not start): an active oneshot ignores `start`, so only restart re-runs ExecStart with the new unit file.
    # Safe: `compose up -d` on the named, already-running services is a no-op.
    if sudo systemctl restart "$unit.service"; then ok "$unit.service enabled + re-asserted"; else warn "$unit.service failed: sudo systemctl status $unit.service"; fi
  done
fi
