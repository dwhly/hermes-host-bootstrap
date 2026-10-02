#!/usr/bin/env bash
# Behavioral test for lib/M7-desktop-switcher-carry.sh: scope gates, install, removal.
# Shims uname/launchctl/plutil in a throwaway HOME; never touches the real launchd domain.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODULE="$ROOT/lib/M7-desktop-switcher-carry.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
bash -n "$MODULE"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
cat >"$BIN/uname" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-s" ]]; then echo "${FAKE_UNAME:-Darwin}"; else /usr/bin/uname "$@"; fi
SH
cat >"$BIN/launchctl" <<'SH'
#!/usr/bin/env bash
echo "launchctl $*" >>"$FAKE_LOG"
case "$1" in
  print) [[ -f "$FAKE_LOADED" ]] || exit 1 ;;
  bootstrap) touch "$FAKE_LOADED" ;;
  bootout) rm -f "$FAKE_LOADED" ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/plutil"
chmod +x "$BIN"/*

# Copy of the repo layout so the hosts file can vary per case.
mk_repo() { # mk_repo <dir> <hosts...>
  mkdir -p "$1/lib" "$1/scripts" "$1/config"
  cp "$ROOT/lib/common.sh" "$MODULE" "$1/lib/"
  cp "$ROOT/scripts/hermes-desktop-carry-sync" "$1/scripts/"
  printf '# hosts\n' >"$1/config/desktop-switcher-carry.hosts"
  local d="$1"; shift; for h in "$@"; do printf '%s\n' "$h" >>"$d/config/desktop-switcher-carry.hosts"; done
}

run_case() { # run_case <name> <host> [VAR=value ...]
  local name="$1" host="$2"; shift 2
  H="$WORK/$name"; mkdir -p "$H"
  LOG="$H/calls.log"; : >"$LOG"
  PLIST="$H/Library/LaunchAgents/com.hermes.desktop-carry.plist"
  OUT="$(env -i PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$H" HERMES_HOSTNAME="$host" \
    FAKE_LOG="$LOG" FAKE_LOADED="$H/loaded" "$@" bash "$WORK/r/lib/M7-desktop-switcher-carry.sh" 2>&1)" \
    || fail "$name: module exited non-zero:\n$OUT"
}

mk_repo "$WORK/r" h-air2

# 1. Listed Mac client: script installed byte-identical, agent written and loaded.
run_case listed h-air2
[[ -x "$H/.local/bin/hermes-desktop-carry-sync" ]] || fail "listed: sync not installed"
cmp -s "$ROOT/scripts/hermes-desktop-carry-sync" "$H/.local/bin/hermes-desktop-carry-sync" || fail "listed: digest"
grep -q '<integer>10800</integer>' "$PLIST" || fail "listed: interval"
grep -q 'launchctl bootstrap' "$LOG" || fail "listed: not bootstrapped"

# 2. Rerun unchanged: no bootout/bootstrap churn.
: >"$LOG"; OUT="$(env -i PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$H" HERMES_HOSTNAME=h-air2 \
  FAKE_LOG="$LOG" FAKE_LOADED="$H/loaded" bash "$WORK/r/lib/M7-desktop-switcher-carry.sh" 2>&1)"
grep -q -E 'bootout|bootstrap' "$LOG" && fail "rerun: churned the agent: $(cat "$LOG")"

# 3. .local suffix on hostname still matches.
run_case suffix h-air2.local
[[ -f "$PLIST" ]] || fail "suffix: not installed"

# 4. Unlisted host: nothing installed.
run_case unlisted h-mini
[[ -f "$PLIST" ]] && fail "unlisted: plist written"
grep -q 'launchctl bootstrap' "$LOG" && fail "unlisted: bootstrapped"

# 5. Host removed from the list: agent booted out and plist removed.
mkdir -p "$WORK/removed/Library/LaunchAgents"; echo stale >"$WORK/removed/Library/LaunchAgents/com.hermes.desktop-carry.plist"
run_case removed h-old
[[ -f "$PLIST" ]] && fail "removed: plist kept"
grep -q 'launchctl bootout' "$LOG" || fail "removed: not booted out"

# 6. Linux, server role, minimal tier: all skip without installing.
run_case linux h-air2 FAKE_UNAME=Linux;  [[ -f "$PLIST" ]] && fail "linux installed"
run_case server h-air2 ROLE=server;      [[ -f "$PLIST" ]] && fail "server installed"
run_case minimal h-air2 TIER=minimal;    [[ -f "$PLIST" ]] && fail "minimal installed"
grep -q 'desktop-switcher-carry needs' <<<"$OUT" || fail "minimal: no skip message"

# 7. A host name that is a prefix/regex of a listed one does not match.
run_case prefix h-air;  [[ -f "$PLIST" ]] && fail "prefix matched"
run_case regex 'h-air.'; [[ -f "$PLIST" ]] && fail "regex matched"

# 8. Multi-host list with comments, CRLF and trailing spaces: every listed host matches.
mk_repo "$WORK/r" h-mini2 'h-air2  # canary' "$(printf 'h-air\r')"
run_case multi1 h-air2; [[ -f "$PLIST" ]] || fail "multi: h-air2 not matched"
run_case multi2 h-mini2; [[ -f "$PLIST" ]] || fail "multi: h-mini2 not matched"
run_case multi3 h-air; [[ -f "$PLIST" ]] || fail "multi: CRLF h-air not matched"
run_case multi4 h-mini; [[ -f "$PLIST" ]] && fail "multi: unlisted h-mini matched"

printf 'PASS: test_desktop_switcher_carry_module (listed hosts only; idempotent; removal)\n'
