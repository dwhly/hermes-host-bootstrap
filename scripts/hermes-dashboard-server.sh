#!/usr/bin/env bash
# hermes-dashboard-server — serve the Hermes web dashboard (hermes dashboard)
# over the tailnet. Waits for the Tailscale IP to exist (survives reboot ordering
# and IP changes), then binds the dashboard HTTP server to it.
#
# The dashboard exposes API keys, so a non-loopback bind is refused UNLESS an auth
# provider is configured. This host uses the basic_auth dashboard plugin
# (dashboard.basic_auth.{username,password_hash,secret} in ~/.hermes/config.yaml);
# the auth gate then permits the tailnet bind behind a login prompt.
#
# Managed by systemd unit hermes-dashboard-server.service. Root-owned; do not
# hand-edit on a live host — this is git-tracked in hermes-host-bootstrap.
set -euo pipefail

PORT="${HERMES_DASHBOARD_PORT:-9119}"
# hermes lives in ~/.local/bin (user install) or the venv; ensure it's on PATH
# since systemd runs a non-login shell (skill fleet-hermes-dashboard gotcha #1).
export PATH="/usr/local/lib/hermes-agent/venv/bin:/root/.local/bin:${PATH}"

# Resolve the tailnet IP, waiting up to ~60s for tailscaled to assign one on boot.
ip=""
for _ in $(seq 1 30); do
  ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  [[ -n "$ip" ]] && break
  sleep 2
done

if [[ -z "$ip" ]]; then
  echo "hermes-dashboard-server: no Tailscale IPv4 after wait — cannot bind" >&2
  exit 1
fi

echo "hermes-dashboard-server: binding dashboard to http://$ip:$PORT (auth-gated)" >&2
exec hermes dashboard --host "$ip" --port "$PORT"
