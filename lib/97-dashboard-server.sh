#!/usr/bin/env bash
# 97-dashboard-server: serve the Hermes web dashboard (`hermes dashboard`) over
# the tailnet as a durable service on EVERY fleet host — systemd on Linux,
# launchd (per-user LaunchAgent) on macOS. Port 9000 fleet-wide.
#
# WHY: `hermes dashboard` binds 127.0.0.1 by default and — in current versions —
# REFUSES a non-loopback bind unless an auth provider is configured (it exposes
# API keys). The fleet configures the basic_auth dashboard plugin via env vars
# sourced from the host's local ~/.hermes/.env (HERMES_DASHBOARD_BASIC_AUTH_*,
# resolved from the 1Password DashboardAuth-fleet item by op inject in
# lib/35-secrets.sh — NOT stored in the fleet-synced config.yaml). The auth gate
# then permits the tailnet bind behind a login prompt. Running it by hand dies on
# restart; this module makes it a first-class service (Restart=always / KeepAlive)
# so every node's dashboard is always reachable at http://<tailnet-ip>:9000.
#
# Skip key: dashboard-server.
#
# PREREQ: HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH + _SECRET must resolve into
# ~/.hermes/.env (needs the DashboardAuth-fleet 1Password item + a secrets run).
# This module installs the service regardless; it warns if auth looks unset.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"
# REPO_ROOT is exported by bootstrap.sh; self-derive so the module can run standalone.
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

PORT="${HERMES_DASHBOARD_PORT:-9000}"

step "Hermes web dashboard server (port ${PORT})"

# Recommended tier (R): part of the observability surface, not a base essential.
if ! tier_allows R; then
  skip "dashboard-server skipped (tier below R)"
  return 0 2>/dev/null || exit 0
fi

if is_skipped dashboard-server; then
  skip "dashboard-server skipped (HERMES_SKIP includes dashboard-server)"
  return 0 2>/dev/null || exit 0
fi

# Runs on EVERY fleet host (each node gets its own dashboard at :PORT). No role
# gate — clients and the server all expose their own local dashboard.

# Warn (don't fail) if the dashboard auth env vars aren't resolved yet — the
# tailnet bind will be refused until they are.
HERMES_ENV="${HERMES_HOME:-$HOME/.hermes}/.env"
if [[ -f "$HERMES_ENV" ]] && ! grep -q '^HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=' "$HERMES_ENV" 2>/dev/null; then
  warn "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH not found in $HERMES_ENV — the tailnet bind will be REFUSED until the dashboard auth secrets resolve. Ensure the DashboardAuth-fleet 1Password item exists and re-run the secrets module (r --only=35-secrets)."
fi

# --- macOS: per-user LaunchAgent -----------------------------------------------
if [[ "$OS" == "macos" ]]; then
  home="$HOME"
  label="com.hermes.dashboard-server"
  agent_dir="$home/Library/LaunchAgents"
  plist_dst="$agent_dir/$label.plist"

  info "installing /usr/local/bin/hermes-dashboard-server"
  sudo install -m 0755 "$REPO_ROOT/scripts/hermes-dashboard-server.sh" /usr/local/bin/hermes-dashboard-server 2>/dev/null \
    || install -m 0755 "$REPO_ROOT/scripts/hermes-dashboard-server.sh" /usr/local/bin/hermes-dashboard-server

  mkdir -p "$agent_dir" "$home/.hermes/logs"
  info "installing $label LaunchAgent"
  sed "s|__HOME__|$home|g" "$REPO_ROOT/launchd/$label.plist" > "$plist_dst"
  chmod 0644 "$plist_dst"

  uid="$(id -u)"
  # Reload: bootout then bootstrap so an edited plist is picked up (kickstart
  # alone won't reload a changed plist). Tolerate not-loaded on first install.
  launchctl bootout "gui/$uid/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$uid" "$plist_dst" 2>/dev/null \
    || launchctl load -w "$plist_dst" 2>/dev/null || true
  launchctl kickstart -k "gui/$uid/$label" 2>/dev/null || true

  sleep 3
  ip="$(tailscale ip -4 2>/dev/null | head -1 || echo '<tailnet-ip>')"
  if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
    ok "dashboard-server LaunchAgent loaded — http://$ip:$PORT (RunAtLoad, KeepAlive)"
  else
    warn "dashboard-server LaunchAgent not loaded — check: launchctl print gui/$uid/$label ; log: $home/.hermes/logs/dashboard-server.err"
  fi
  return 0 2>/dev/null || exit 0
fi

# --- Linux: systemd unit -------------------------------------------------------
if ! have systemctl; then
  warn "systemctl not present — cannot install dashboard-server unit"
  return 0 2>/dev/null || exit 0
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
# If a manual `hermes dashboard` is already holding :PORT, the unit's bind would
# fail — stop any stray manual server first (best-effort; won't kill the unit).
if ss -ltn 2>/dev/null | grep -q ":${PORT} "; then
  stray="$(pgrep -f 'hermes dashboard' | head -1 || true)"
  if [[ -n "$stray" ]] && ! systemctl status hermes-dashboard-server.service 2>/dev/null | grep -q "$stray"; then
    info "stopping stray manual hermes dashboard (pid $stray) holding :${PORT}"
    sudo kill "$stray" 2>/dev/null || true
    sleep 1
  fi
fi
sudo systemctl restart hermes-dashboard-server.service

sleep 3
if systemctl is-active --quiet hermes-dashboard-server.service; then
  ip="$(tailscale ip -4 2>/dev/null | head -1 || echo '<tailnet-ip>')"
  ok "dashboard-server active — http://$ip:${PORT} (enabled at boot, Restart=always)"
else
  warn "dashboard-server not active — check: sudo systemctl status hermes-dashboard-server.service (most likely the bind was refused: dashboard auth secrets not resolved in ~/.hermes/.env)."
fi
