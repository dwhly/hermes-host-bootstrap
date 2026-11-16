#!/usr/bin/env bash
# S1-memguard: keep the control-plane host reachable under memory pressure. Control-plane host only.
#
# WHY (2026-11-15): h-do1 runs the fleet control plane AND ~18 agent sessions, their test runs and ~40 containers.
# A 4.3 GB pytest plus session growth filled RAM and swap; the kernel OOM-killed 78 processes in three days and
# tailnet SSH stopped answering. The interim memguard (loose in /root/work/memguard since 2026-10-22) hung under
# exactly that pressure and was killed by systemd. This module makes both guards bootstrap-owned:
#   hermes-memguard.{service,timer}  every 5 min: end Hermes sessions idle > 12 h under pressure, OOM priorities,
#                                    +2 GB swap. Every external call is time-boxed; runs at high priority.
#   hermes-testcap.service + testcap.slice
#                                    moves pytest/vitest/jest/playwright/cargo/go test runs started from user
#                                    sessions into capped scopes (6G per run, 12G total) so a runaway test dies
#                                    alone. hermes-capped <cmd> does the same for any command, explicitly.
# Gate: the host must own the control-plane tailnet IP (the session-reaper rules are h-do1 policy).
# Skip key: memguard.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONTROL_PLANE_IP="100.122.202.37"

step "Memory guard + capped test runs (systemd)"

if ! tier_allows E; then
  skip "memguard skipped (tier below E)"
  return 0 2>/dev/null || exit 0
fi
if is_skipped memguard; then
  skip "memguard skipped (HERMES_SKIP includes memguard)"
  return 0 2>/dev/null || exit 0
fi
if ! role_includes server; then
  skip "role=$ROLE — memguard runs on the server/control-plane host only"
  return 0 2>/dev/null || exit 0
fi
if [[ "$OS" == "macos" ]] || ! have systemctl; then
  skip "no systemd on this host — memguard not applicable"
  return 0 2>/dev/null || exit 0
fi
if ! ip -4 addr show 2>/dev/null | grep -q "inet ${CONTROL_PLANE_IP}/"; then
  skip "this host does not own the control-plane IP ${CONTROL_PLANE_IP} — memguard not applicable"
  return 0 2>/dev/null || exit 0
fi

for s in hermes-memguard hermes-testcap hermes-capped; do
  sudo install -m 0755 "$REPO_ROOT/scripts/$s" "/usr/local/bin/$s"
done
for u in hermes-memguard.service hermes-memguard.timer hermes-testcap.service testcap.slice; do
  sudo install -m 0644 "$REPO_ROOT/systemd/$u" "/etc/systemd/system/$u"
done
sudo systemctl daemon-reload
sudo systemctl reset-failed hermes-memguard.service >/dev/null 2>&1 || true
sudo systemctl enable hermes-memguard.timer hermes-testcap.service >/dev/null 2>&1 || warn "could not enable memguard units"
sudo systemctl restart hermes-testcap.service
sudo systemctl restart hermes-memguard.timer
if sudo systemctl start hermes-memguard.service && systemctl is-active --quiet hermes-testcap.service; then
  ok "memguard timer + testcap active (log: /root/.hermes/logs/testcap.jsonl)"
else
  warn "memguard/testcap not healthy: systemctl status hermes-memguard hermes-testcap"
fi
