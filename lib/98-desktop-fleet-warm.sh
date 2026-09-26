#!/usr/bin/env bash
# Installs before native-bots builds the app. Compatibility is checked by verify.sh AFTER build.
set -euo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$MODULE_DIR/.." && pwd)}"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/common.sh"
if ! tier_allows R || ! role_includes client || [[ "$OS" != macos ]] || is_skipped desktop-fleet-warm; then
  skip "desktop-fleet-warm requires recommended tier and a Mac client"
  return 0 2>/dev/null || exit 0
fi
fleet_home="${HERMES_HOME:-$HOME/.hermes}"
intent="${HERMES_FLEET_INTENT:-$fleet_home/fleet/hosts.yaml}"
revision="${HERMES_FLEET_REVISION:-$(git -C "$(dirname "$intent")" rev-parse HEAD)}"
args=(install --registry "$intent" --revision "$revision" --hermes-home "$fleet_home")
if [[ -n "${HERMES_DESKTOP_APP_PIN:-}" ]]; then
  args+=(--app-pin "$HERMES_DESKTOP_APP_PIN")
fi
python3 "$REPO_ROOT/scripts/desktop-fleet.py" "${args[@]}"
