#!/usr/bin/env bash
# hermes-wiki-server — serve the published Hermes automation wiki + agent reports
# over the tailnet. Waits for the Tailscale IP to exist (survives reboot ordering
# and IP changes), then binds the artifact HTTP server to it.
#
# Managed by systemd unit hermes-wiki-server.service. Root-owned; do not hand-edit
# on a live host — this is git-tracked in hermes-host-bootstrap.
set -euo pipefail

SERVE_DIR="${HERMES_WIKI_SERVE_DIR:-/root/code/agent-report-kit/examples}"
PORT="${HERMES_WIKI_PORT:-8765}"

# Resolve the tailnet IP, waiting up to ~60s for tailscaled to assign one on boot.
ip=""
for _ in $(seq 1 30); do
  ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  [[ -n "$ip" ]] && break
  sleep 2
done

if [[ -z "$ip" ]]; then
  echo "hermes-wiki-server: no Tailscale IPv4 after wait — cannot bind" >&2
  exit 1
fi

cd "$SERVE_DIR"
echo "hermes-wiki-server: serving $SERVE_DIR on http://$ip:$PORT" >&2
exec python3 -m http.server "$PORT" --bind "$ip"
