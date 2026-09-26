#!/usr/bin/env bash
# Render/compare before refreshing the owned dashboard. Never adopt an occupied socket.
set -euo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$MODULE_DIR/.." && pwd)}"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/common.sh"
step "Hermes dashboard server"
if ! tier_allows R || is_skipped dashboard-server; then
  skip "dashboard-server skipped"
  return 0 2>/dev/null || exit 0
fi
platform=linux
[[ "$OS" != macos ]] || platform=macos
hermes_executable="$(command -v hermes)"
args=(install --platform "$platform" --home "$HOME" --hermes-home "${HERMES_HOME:-$HOME/.hermes}"
  --user "$(id -un)" --executable "$hermes_executable" --port "${HERMES_DASHBOARD_PORT:-9000}"
  --bind "${HERMES_DASHBOARD_BIND:-tailnet}"
  --registry "${HERMES_FLEET_INTENT:-${HERMES_HOME:-$HOME/.hermes}/fleet/hosts.yaml}")
if [[ "$platform" == linux && "$EUID" != 0 ]]; then
  sudo python3 "$REPO_ROOT/scripts/desktop-dashboard.py" "${args[@]}"
else
  python3 "$REPO_ROOT/scripts/desktop-dashboard.py" "${args[@]}"
fi
