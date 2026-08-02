#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODULE="$ROOT/lib/43-fluidvoice.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

bash -n "$MODULE" "$ROOT/lib/99-register-host.sh" "$ROOT/verify.sh"
grep -q 'brew install --cask fluidvoice' "$MODULE" || fail "official cask install missing"
grep -q 'OS.*macos' "$MODULE" || fail "macOS gate missing"
grep -q 'role_includes client' "$MODULE" || fail "client role gate missing"
grep -q 'login item.*FluidVoice' "$MODULE" || fail "login item registration missing"
grep -q 'repairing stale FluidVoice login item path' "$MODULE" || fail "stale login-item repair missing"
grep -q 'ShowMainWindowAtLoginLaunch -bool false' "$MODULE" || fail "silent-login preference missing"
grep -q 'LaunchAtStartupCompatibilityFallback -bool true' "$MODULE" || fail "compatibility marker missing"
grep -q 'FluidVoice' "$ROOT/tiers/recommended.txt" || fail "tier manifest missing"
grep -q 'FLUIDVOICE_VER=' "$ROOT/lib/99-register-host.sh" || fail "version probe missing"
grep -q 'fluidvoice:' "$ROOT/lib/99-register-host.sh" || fail "registry version field missing"
grep -q 'verify_check "fluidvoice"' "$ROOT/verify.sh" || fail "app verification missing"
grep -q 'verify_check "fluidvoice-login-item"' "$ROOT/verify.sh" || fail "login-item verification missing"
grep -q 'verify_fluidvoice_login_item' "$ROOT/verify.sh" || fail "runtime login-item verifier missing"

# Merely sourcing verify.sh must not invoke uname/defaults/osascript. The
# commands are definitions and should execute only when a check is run.
stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT
for name in uname defaults osascript; do
  cat > "$stub_dir/$name" <<'SH'
#!/usr/bin/env bash
printf 'unexpected eager verifier command: %s\n' "$0" >&2
exit 97
SH
  chmod +x "$stub_dir/$name"
done
PATH="$stub_dir:/usr/bin:/bin" bash -c 'source "$1"' _ "$ROOT/verify.sh" \
  || fail "verify.sh eagerly executed a FluidVoice probe"

output="$(TIER=recommended ROLE=server HERMES_SKIP= bash "$MODULE")"
grep -q 'macOS client-only' <<<"$output" || fail "Linux/server path did not skip"

pass "FluidVoice package contract and platform gate"
