#!/usr/bin/env bash
# 91-hermes-tui-theme: restore legible diff colors in the Hermes Ink TUI and
# rebuild the bundle. Runs after 90-agents (hermes binary exists) and before
# 92-hermes-config. Idempotent.
#
# Upstream's GitHub-style pale-background diff lines are hard to read on dark
# terminals; this re-applies the bright-foreground/no-fill scheme. The real
# work lives in scripts/hermes-tui-theme-patch so it can also be run by hand
# after a `hermes update` (which overwrites theme.ts in this editable install).
#
# Skip key:
#   hermes-tui-theme    skip this module

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Hermes TUI diff-color theme patch"

if is_skipped hermes-tui-theme; then
  skip "hermes-tui-theme — opted out via --skip"
  return 0 2>/dev/null || exit 0
fi

if ! have hermes; then
  skip "hermes not on PATH — skipping TUI theme patch"
  return 0 2>/dev/null || exit 0
fi

PATCH_SCRIPT="$(dirname "$0")/../scripts/hermes-tui-theme-patch"
if [[ ! -f "$PATCH_SCRIPT" ]]; then
  warn "scripts/hermes-tui-theme-patch missing — cannot apply TUI theme"
  return 0 2>/dev/null || exit 0
fi

if bash "$PATCH_SCRIPT"; then
  ok "Hermes TUI diff colors restored + bundle rebuilt"
else
  warn "TUI theme patch did not complete (see output above) — non-fatal, continuing"
fi
