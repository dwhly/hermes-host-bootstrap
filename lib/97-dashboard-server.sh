#!/usr/bin/env bash
# 97-dashboard-server: serve the Hermes web dashboard (`hermes dashboard`) over
# the tailnet as a durable systemd service (Linux relay/server hosts only).
#
# WHY: `hermes dashboard` binds 127.0.0.1 by default and — in current versions —
# REFUSES a non-loopback bind unless an auth provider is configured (it exposes
# API keys). To give a click-from-any-tailnet-node URL we configure the
# basic_auth dashboard plugin (dashboard.basic_auth.* in ~/.hermes/config.yaml),
# which lets the auth gate permit the tailnet bind behind a login prompt. Running
# it by hand dies on reboot; this module makes it a first-class systemd unit
# (Restart=always, ordered after tailscaled) so the dashboard is always reachable.
#
# Serves: http://<tailnet-ip>:9119  (login: dashboard.basic_auth.username / password)
# Skip key: dashboard-server.
#
# PREREQ: dashboard.basic_auth.{username,password_hash,secret} must be set in
# ~/.hermes/config.yaml or the bind will be refused. This module installs the
# unit regardless; it warns if auth looks unconfigured.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"
# REPO_ROOT is exported by bootstrap.sh; self-derive so the module can run standalone.
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

step "Hermes web dashboard server (systemd)"

# Recommended tier (R): part of the observability surface, not a base essential.
if ! tier_allows R; then
  skip "dashboard-server skipped (tier below R)"
  return 0 2>/dev/null || exit 0
fi

if is_skipped dashboard-server; then
  skip "dashboard-server skipped (HERMES_SKIP includes dashboard-server)"
  return 0 2>/dev/null || exit 0
fi

# Server/relay role only — this is the fleet's dashboard host (h-do1), not a client.
if ! role_includes server; then
  skip "role=$ROLE — dashboard-server runs on the relay/server host only"
  return 0 2>/dev/null || exit 0
fi

# Linux/systemd only.
if [[ "$OS" == "macos" ]]; then
  skip "macOS host — dashboard-server systemd unit not applicable (dashboard host is Linux h-do1)"
  return 0 2>/dev/null || exit 0
fi
if ! have systemctl; then
  warn "systemctl not present — cannot install dashboard-server unit"
  return 0 2>/dev/null || exit 0
fi

# Warn (don't fail) if basic_auth appears unconfigured — the bind will be refused.
CFG="${HERMES_CONFIG:-/root/.hermes/config.yaml}"
if [[ -f "$CFG" ]] && ! grep -q "password_hash" "$CFG" 2>/dev/null; then
  warn "dashboard.basic_auth.password_hash not found in $CFG — the tailnet bind will be REFUSED until an auth provider is configured. See: hermes dashboard register, or set dashboard.basic_auth.{username,password_hash,secret}."
fi

# 1) install the launcher wrapper (waits for tailnet IP, binds, execs hermes dashboard)
info "installing /usr/local/bin/hermes-dashboard-server"
sudo install -m 0755 "$REPO_ROOT/scripts/hermes-dashboard-server.sh" /usr/local/bin/hermes-dashboard-server

# 2) install the systemd unit
info "installing hermes-dashboard-server.service"
sudo install -m 0644 "$REPO_ROOT/systemd/hermes-dashboard-server.service" /etc/systemd/system/hermes-dashboard-server.service

# 3) reload + enable + (re)start
sudo systemctl daemon-reload
sudo systemctl enable hermes-dashboard-server.service >/dev/null 2>&1 || true
# If a manual `hermes dashboard` is already holding :9119, the unit's bind would
# fail — stop any stray manual server first (best-effort; won't kill the unit).
if ss -ltn 2>/dev/null | grep -q ':9119 '; then
  stray="$(pgrep -f 'hermes dashboard' | head -1 || true)"
  if [[ -n "$stray" ]] && ! systemctl status hermes-dashboard-server.service 2>/dev/null | grep -q "$stray"; then
    info "stopping stray manual hermes dashboard (pid $stray) holding :9119"
    sudo kill "$stray" 2>/dev/null || true
    sleep 1
  fi
fi
sudo systemctl restart hermes-dashboard-server.service

sleep 3
if systemctl is-active --quiet hermes-dashboard-server.service; then
  ip="$(tailscale ip -4 2>/dev/null | head -1 || echo '<tailnet-ip>')"
  ok "dashboard-server active — http://$ip:9119 (enabled at boot, Restart=always)"
else
  warn "dashboard-server not active — check: sudo systemctl status hermes-dashboard-server.service (most likely the bind was refused: configure dashboard.basic_auth.*)"
fi
