#!/usr/bin/env bash
# 98-hermes-dashboard-500-patch: re-apply the dashboard password-only auto-SSO
# guard to the editable hermes-agent checkout.
#
# WHY: _auto_sso_response() in hermes_cli/dashboard_auth/middleware.py 500s when a
# lone password-only provider (the fleet's tailnet dashboard basic_auth) is
# registered — it auto-redirects to the OAuth /auth/login route, whose
# start_login() raises NotImplementedError. This is an UPSTREAM bug; `hermes
# update` overwrites the editable source, so this module re-applies the one-line
# guard after every update (mirrors 91-hermes-tui-theme.sh). The real work lives
# in scripts/hermes-dashboard-500-patch so it can also be run by hand.
#
# Ordered 98 so it runs after 97-dashboard-server installs the service and before
# 99-register-host. Idempotent + safe (no-op if already patched).
#
# Skip key: dashboard-500-patch

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Hermes dashboard password-only 500 guard"

if is_skipped dashboard-500-patch; then
  skip "dashboard-500-patch — opted out via --skip"
  return 0 2>/dev/null || exit 0
fi

PATCH_SCRIPT="$(dirname "$0")/../scripts/hermes-dashboard-500-patch"
if [[ ! -f "$PATCH_SCRIPT" ]]; then
  warn "patch script not found at $PATCH_SCRIPT"
  return 0 2>/dev/null || exit 0
fi

# python3 is a hard dep of Hermes itself, so it's always present.
result="$(python3 "$PATCH_SCRIPT" 2>&1 || true)"
case "$result" in
  *already-patched*) ok "dashboard 500 guard already present" ;;
  *RESULT=patched*)  ok "dashboard 500 guard applied — restart the dashboard service to load it" ;;
  *no-middleware-file*) skip "no hermes-agent middleware.py found — nothing to patch on this host" ;;
  *anchor-not-found*) warn "dashboard 500 guard anchor not found — upstream may have refactored; review manually. ($result)" ;;
  *) info "$result" ;;
esac
