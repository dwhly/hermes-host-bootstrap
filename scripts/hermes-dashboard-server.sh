#!/usr/bin/env bash
# hermes-dashboard-server — serve the Hermes web dashboard (hermes dashboard)
# over the tailnet. Waits for the Tailscale IP to exist (survives reboot ordering
# and IP changes), then binds the dashboard HTTP server to it.
#
# The dashboard exposes API keys, so a non-loopback bind is refused UNLESS an auth
# provider is configured. The fleet uses the basic_auth dashboard plugin, with the
# password hash + session secret provided as env vars sourced from the host's local
# ~/.hermes/.env (HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH / _SECRET, resolved from
# the approved per-host dashboard item by local projection). The auth gate then permits
# the tailnet bind behind a login prompt.
#
# Cross-platform: Linux hosts run it via systemd (hermes-dashboard-server.service);
# macOS hosts via launchd (com.hermes.dashboard-server). Root/user-owned; do not
# hand-edit on a live host — this is git-tracked in hermes-host-bootstrap.
set -euo pipefail

PORT="${HERMES_DASHBOARD_PORT:-9000}"
# A server must never inherit the Desktop/SSH auth exemption. Refuse, do not mask it.
for forbidden in HERMES_DESKTOP HERMES_DASHBOARD_SESSION_TOKEN HERMES_DESKTOP_OWNER_NONCE HERMES_SSH_PASSWORD HERMES_SSH_PRIVATE_KEY; do
  if [[ -n "${!forbidden:-}" ]]; then
    echo "hermes-dashboard-server: forbidden desktop/SSH environment: $forbidden" >&2
    exit 1
  fi
done

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
  export PATH="/usr/local/lib/hermes-agent/venv/bin:$HOME/.local/bin:/usr/local/bin:$PATH"
fi

# --- Load per-host dashboard auth from ~/.hermes/.env --------------------------
# systemd/launchd do NOT load the user's .env, and the auth secrets live there
# (resolved from 1Password). Source only the dashboard vars we need, tolerating
# a missing file (the bind will then be refused with a clear message).
HERMES_ENV="${HERMES_HOME:-$HOME/.hermes}/.env"
if [[ -f "$HERMES_ENV" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#export }"
    case "$line" in
      HERMES_DASHBOARD_BASIC_AUTH_*=*|HERMES_DASHBOARD_PUBLIC_URL=*)
        export "${line?}"
        ;;
    esac
  done < "$HERMES_ENV"
fi

# --- Resolve the tailnet IP, waiting up to ~60s for tailscaled on boot ---------
ip="${HERMES_DASHBOARD_BIND:-tailnet}"
if [[ "$ip" == tailnet ]]; then
  ip=""
  for _ in $(seq 1 30); do
    ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"
    [[ -n "$ip" ]] && break
    sleep 2
  done
fi

if [[ -z "$ip" ]]; then
  echo "hermes-dashboard-server: no Tailscale IPv4 after wait — cannot bind" >&2
  exit 1
fi

echo "hermes-dashboard-server: binding dashboard to http://$ip:$PORT (auth-gated)" >&2
exec "${HERMES_DASHBOARD_EXECUTABLE:-hermes}" dashboard --host "$ip" --port "$PORT" --no-open
