#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODULE="$ROOT/lib/M6-mac-desktop-power.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

bash -n "$MODULE"
grep -q 'h-mini|h-mini2' "$MODULE" || fail "Mini hostname allowlist missing"
grep -q 'removed Mini-only keepawake policy' "$MODULE" || fail "non-Mini cleanup path missing"

# Static safety invariant: an opt-in alone is insufficient. The host must also
# match the explicit Mini allowlist before the LaunchAgent render path.
mini_line="$(grep -n 'h-mini|h-mini2' "$MODULE" | cut -d: -f1 | head -1)"
render_line="$(grep -n 'cat >"\$plist"' "$MODULE" | cut -d: -f1 | head -1)"
[[ -n "$mini_line" && -n "$render_line" && "$mini_line" -lt "$render_line" ]] \
  || fail "Mini scope gate must precede LaunchAgent rendering"

printf 'PASS: keepawake policy is hard-scoped to h-mini/h-mini2\n'