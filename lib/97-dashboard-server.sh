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
# A held row returns successfully even before a runtime has been installed.
hermes_executable="$(command -v hermes || true)"
# Resolve PyYAML in the invoking runtime's environment before sudo resets it.
dashboard_python() {
  local candidate
  if [[ -n "${HERMES_FLEET_PYTHON:-}" ]]; then
    candidate="$HERMES_FLEET_PYTHON"
    if [[ ! -f "$candidate" || ! -x "$candidate" ]] || ! "$candidate" -c 'import yaml' >/dev/null 2>&1; then
      echo 'desktop-dashboard: HERMES_FLEET_PYTHON is not an executable Python with PyYAML' >&2
      return 1
    fi
    printf '%s\n' "$candidate"
    return 0
  fi
  # Arguments are the ordered discovery candidates; the last is the system Python.
  for candidate in "$@"; do
    if [[ -n "$candidate" && -x "$candidate" ]] && "$candidate" -c 'import yaml' >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf '%s\n' "${!#}"
}
if [[ -n "${HERMES_FLEET_PYTHON:-}" ]]; then
  py="$(dashboard_python)"
else
  py="$(command -v python3)"
  hermes_python="$("$py" -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve().parent / "python3")' "$hermes_executable")"
  py="$(dashboard_python "$HOME/hermes-agent/venv/bin/python3" \
    "$HOME/hermes-agent/.venv/bin/python3" "$hermes_python" \
    /usr/local/lib/hermes-agent/venv/bin/python3 "$py")"
fi
if [[ -n "${HERMES_FLEET_INTENT:-}" && ! -e "$HERMES_FLEET_INTENT" ]]; then
  echo 'desktop-dashboard: HERMES_FLEET_INTENT file does not exist' >&2
  exit 1
fi
args=(install --platform "$platform" --home "$HOME" --hermes-home "${HERMES_HOME:-$HOME/.hermes}"
  --user "$(id -un)" --executable "$hermes_executable" --port "${HERMES_DASHBOARD_PORT:-9000}"
  --bind "${HERMES_DASHBOARD_BIND:-tailnet}"
  --registry "${HERMES_FLEET_INTENT:-}")
if [[ "$platform" == linux && "$EUID" != 0 ]]; then
  sudo "$py" "$REPO_ROOT/scripts/desktop-dashboard.py" "${args[@]}"
else
  "$py" "$REPO_ROOT/scripts/desktop-dashboard.py" "${args[@]}"
fi
