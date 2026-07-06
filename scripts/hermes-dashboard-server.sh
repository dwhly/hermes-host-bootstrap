#!/usr/bin/env bash
# hermes-dashboard-server — serve the Hermes web dashboard (hermes dashboard)
# over the tailnet. Waits for the Tailscale IP to exist (survives reboot ordering
# and IP changes), then binds the dashboard HTTP server to it.
#
# The dashboard exposes API keys, so a non-loopback bind is refused UNLESS an auth
# provider is configured. The fleet uses the basic_auth dashboard plugin, with the
# password hash + session secret provided as env vars sourced from the host's local
# ~/.hermes/.env (HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH / _SECRET, resolved from
# the 1Password DashboardAuth-fleet item by op inject). The auth gate then permits
# the tailnet bind behind a login prompt.
#
# Cross-platform: Linux hosts run it via systemd (hermes-dashboard-server.service);
# macOS hosts via launchd (com.hermes.dashboard-server). Root/user-owned; do not
# hand-edit on a live host — this is git-tracked in hermes-host-bootstrap.
set -euo pipefail

PORT="${HERMES_DASHBOARD_PORT:-9000}"

# --- Locate hermes + tailscale across OSes -------------------------------------
# systemd/launchd run a non-login shell that skips profile PATH, so we build a
# PATH covering every place hermes/tailscale live on our fleet.
_os="$(uname -s)"
if [[ "$_os" == "Darwin" ]]; then
  # macOS: hermes installed under the user's ~/.local/bin; Tailscale ships its
  # CLI inside the app bundle (and Homebrew symlinks it too).
  export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/Applications/Tailscale.app/Contents/MacOS:$PATH"
else
  # Linux: packaged install venv + user-local bin.
  export PATH="/usr/local/lib/hermes-agent/venv/bin:$HOME/.local/bin:/root/.local/bin:/usr/local/bin:$PATH"
fi

# --- Load per-host dashboard auth from ~/.hermes/.env --------------------------
# systemd/launchd do NOT load the user's .env, and the auth secrets live there
# (resolved from 1Password). Source only the dashboard vars we need, tolerating
# a missing file (the bind will then be refused with a clear message).
HERMES_ENV="${HERMES_HOME:-$HOME/.hermes}/.env"
if [[ -f "$HERMES_ENV" ]]; then
  while IFS= read -r line; do
    case "$line" in
      HERMES_DASHBOARD_BASIC_AUTH_*=*)
        export "${line?}"
        ;;
    esac
  done < "$HERMES_ENV"
fi

# --- Resolve the tailnet IP, waiting up to ~60s for tailscaled on boot ---------
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
