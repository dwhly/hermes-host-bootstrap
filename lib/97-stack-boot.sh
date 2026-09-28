#!/usr/bin/env bash
# 97-stack-boot: bring the control-plane Docker stacks (Chief, Buzz relay) up after EVERY boot (server hosts only).
#
# WHY: the stacks' compose services use `restart: unless-stopped`. Docker does not restart a container that was
# explicitly stopped, so after a maintenance quiesce (`docker compose stop`, then power-off, as in the h-do1 resize)
# Chief Core stayed DOWN after boot. For ~45 min every fleet node lost its boss and the converger check-ins failed.
# These oneshot units re-assert the desired state at boot, whatever stopped the containers.
#
# Installs: chief-stack.service, buzz-prod.service (enabled; only when that stack's directory exists).
# Skip key: stack-boot.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

step "Control-plane stacks come up after every boot (systemd)"

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

declare -A STACK_DIR=([chief-stack]=/root/code/chief/chief-stack [buzz-prod]=/root/services/buzz)
installed=0
for unit in chief-stack buzz-prod; do
  if [[ ! -d "${STACK_DIR[$unit]}" ]]; then
    skip "$unit: ${STACK_DIR[$unit]} not present on this host"
    continue
  fi
  info "installing $unit.service"
  sudo install -m 0644 "$REPO_ROOT/systemd/$unit.service" "/etc/systemd/system/$unit.service"
  installed=1
done
if [[ "$installed" == 1 ]]; then
  sudo systemctl daemon-reload
  for unit in chief-stack buzz-prod; do
    [[ -f "/etc/systemd/system/$unit.service" ]] || continue
    sudo systemctl enable "$unit.service" >/dev/null 2>&1 || warn "could not enable $unit.service"
    # Starting is idempotent (`compose up -d` on running services is a no-op), and it proves the unit works now.
    if sudo systemctl start "$unit.service"; then ok "$unit.service enabled + started"; else warn "$unit.service failed: sudo systemctl status $unit.service"; fi
  done
fi
