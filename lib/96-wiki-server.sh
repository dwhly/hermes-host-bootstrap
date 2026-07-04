#!/usr/bin/env bash
# 96-wiki-server: serve the published Hermes automation wiki + agent reports over
# the tailnet as a durable systemd service (Linux relay/server hosts only).
#
# WHY: the wiki/report artifact server was historically a manual
# `python3 -m http.server 8765 --bind <tailnet-ip>` in /root/code/agent-report-kit/
# examples — which DIES on reboot, so the clickable Tailscale doc URLs the
# documentation-loop emits would 404 until someone restarted it by hand. This
# module makes it a first-class systemd unit (Restart=always, ordered after
# tailscaled) so the wiki is always reachable. macOS/client hosts skip it.
#
# Serves: http://<tailnet-ip>:8765  (custom /wiki/, mkdocs /wiki-mkdocs/, reports)
# Skip key: wiki-server.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"
# REPO_ROOT is exported by bootstrap.sh; self-derive so the module can run standalone.
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

step "Hermes wiki/report artifact server (systemd)"

# Recommended tier (R): part of the docs/observability surface, not a base essential.
if ! tier_allows R; then
  skip "wiki-server skipped (tier below R)"
  return 0 2>/dev/null || exit 0
fi

if is_skipped wiki-server; then
  skip "wiki-server skipped (HERMES_SKIP includes wiki-server)"
  return 0 2>/dev/null || exit 0
fi

# Server/relay role only — this is the fleet's artifact host (h-do1), not a client.
if ! role_includes server; then
  skip "role=$ROLE — wiki-server runs on the relay/server host only"
  return 0 2>/dev/null || exit 0
fi

# Linux/systemd only. macOS relay would need a launchd plist (not wired — the
# artifact host is h-do1/Linux by design).
if [[ "$OS" == "macos" ]]; then
  skip "macOS host — wiki-server systemd unit not applicable (artifact host is Linux h-do1)"
  return 0 2>/dev/null || exit 0
fi
if ! have systemctl; then
  warn "systemctl not present — cannot install wiki-server unit"
  return 0 2>/dev/null || exit 0
fi

SERVE_DIR="${HERMES_WIKI_SERVE_DIR:-/root/code/agent-report-kit/examples}"
if [[ ! -d "$SERVE_DIR" ]]; then
  warn "serve dir $SERVE_DIR missing — the wiki isn't published on this host yet; installing unit anyway (it will serve once the dir exists)"
fi

# 1) install the launcher wrapper (waits for tailnet IP, binds, execs http.server)
info "installing /usr/local/bin/hermes-wiki-server"
sudo install -m 0755 "$REPO_ROOT/scripts/hermes-wiki-server.sh" /usr/local/bin/hermes-wiki-server

# 2) install the systemd unit
info "installing hermes-wiki-server.service"
sudo install -m 0644 "$REPO_ROOT/systemd/hermes-wiki-server.service" /etc/systemd/system/hermes-wiki-server.service

# 3) reload + enable + (re)start
sudo systemctl daemon-reload
sudo systemctl enable hermes-wiki-server.service >/dev/null 2>&1 || true
# If a manual `python -m http.server` is already holding :8765, the unit's bind
# would fail — stop any stray manual server first (best-effort; won't kill the unit).
if ss -ltn 2>/dev/null | grep -q ':8765 '; then
  stray="$(pgrep -f 'http.server 8765' | head -1 || true)"
  if [[ -n "$stray" ]] && ! systemctl status hermes-wiki-server.service 2>/dev/null | grep -q "$stray"; then
    info "stopping stray manual http.server (pid $stray) holding :8765"
    sudo kill "$stray" 2>/dev/null || true
    sleep 1
  fi
fi
sudo systemctl restart hermes-wiki-server.service

sleep 2
if systemctl is-active --quiet hermes-wiki-server.service; then
  ip="$(tailscale ip -4 2>/dev/null | head -1 || echo '<tailnet-ip>')"
  ok "wiki-server active — http://$ip:8765 (enabled at boot, Restart=always)"
else
  warn "wiki-server not active — check: sudo systemctl status hermes-wiki-server.service"
fi
