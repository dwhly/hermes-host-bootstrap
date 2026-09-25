#!/usr/bin/env bash
# Behavioral test for lib/M6-mac-desktop-power.sh.
# Runs the module against shimmed pmset/launchctl/plutil/sudo/uname in a
# throwaway HOME so it never touches the real launchd domain or pmset.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODULE="$ROOT/lib/M6-mac-desktop-power.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

bash -n "$MODULE"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN"

# Shims. Behavior is controlled by FAKE_* env vars; calls are logged.
cat >"$BIN/uname" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-s" ]]; then echo Darwin; else /usr/bin/uname "$@"; fi
SH
cat >"$BIN/pmset" <<'SH'
#!/usr/bin/env bash
echo "pmset $*" >>"$FAKE_LOG"
case "$*" in
  "-g batt")
    echo "Now drawing from 'AC Power'"
    [[ "${FAKE_BATTERY:-0}" == "1" ]] && echo " -InternalBattery-0 (id=1)	100%; charged; 0:00 remaining present: true"
    ;;
  "-g custom")
    printf 'AC Power:\n'
    printf ' sleep                %s\n' "${FAKE_SLEEP:-1}"
    printf ' womp                 %s\n' "${FAKE_WOMP:-0}"
    printf ' autorestart          %s\n' "${FAKE_AUTORESTART:-0}"
    printf ' displaysleep         %s\n' "${FAKE_DISPLAYSLEEP:-10}"
    ;;
esac
exit 0
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
cat >"$BIN/plutil" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$BIN/sudo" <<'SH'
#!/usr/bin/env bash
echo "sudo $*" >>"$FAKE_LOG"
[[ "${FAKE_SUDO_OK:-0}" == "1" ]] || exit 1
shift  # drop -n
[[ "$1" == "true" ]] && exit 0
"$@"
SH
chmod +x "$BIN"/*

run_case() {
  # usage: run_case <name> [VAR=value ...]; sets OUT, LOG, PLIST
  local name="$1"; shift
  local home="$WORK/$name"
  mkdir -p "$home"
  LOG="$home/calls.log"; : >"$LOG"
  PLIST="$home/Library/LaunchAgents/com.hermes.keepawake.plist"
  OUT="$(env -i PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$home" \
    HERMES_HOSTNAME="test-$name" FAKE_LOG="$LOG" FAKE_LOADED="$home/loaded" \
    "$@" bash "$MODULE" 2>&1)" || fail "$name: module exited non-zero:\n$OUT"
}

# 1. Desktop, default (auto), no sudo: agent installed, exact pmset hint printed.
run_case desktop-auto
[[ -f "$PLIST" ]] || fail "desktop-auto: keepawake plist not written"
grep -q '/usr/bin/caffeinate' "$PLIST" || fail "desktop-auto: plist missing caffeinate"
grep -q 'launchctl bootstrap' "$LOG" || fail "desktop-auto: agent not bootstrapped"
grep -q 'sudo pmset -c sleep 0 womp 1 autorestart 1 displaysleep 30' <<<"$OUT" \
  || fail "desktop-auto: missing exact pmset hint:\n$OUT"
grep -q '^sudo -n pmset' "$LOG" && fail "desktop-auto: pmset applied without sudo"

# 2. Desktop with passwordless sudo: only the drifted keys are applied.
run_case desktop-sudo FAKE_SUDO_OK=1 FAKE_WOMP=1 FAKE_DISPLAYSLEEP=30
grep -q '^pmset -c sleep 0 autorestart 1$' "$LOG" \
  || fail "desktop-sudo: expected minimal pmset apply, got:\n$(cat "$LOG")"

# 3. Desktop already compliant: no pmset writes, no warning.
run_case desktop-ok FAKE_SLEEP=0 FAKE_WOMP=1 FAKE_AUTORESTART=1 FAKE_DISPLAYSLEEP=30
grep -q '^pmset -c' "$LOG" && fail "desktop-ok: unexpected pmset write"
grep -q 'pmset AC policy in place' <<<"$OUT" || fail "desktop-ok: missing in-place confirmation"

# 4. Laptop: never installed, even when explicitly opted in; stale plist removed.
mkdir -p "$WORK/laptop/Library/LaunchAgents"
echo stale >"$WORK/laptop/Library/LaunchAgents/com.hermes.keepawake.plist"
run_case laptop FAKE_BATTERY=1 HERMES_MAC_DESKTOP_ALWAYS_ON=1 FAKE_SUDO_OK=1
[[ -f "$PLIST" ]] && fail "laptop: keepawake plist present"
grep -q 'ignored' <<<"$OUT" || fail "laptop: opt-in not reported as ignored"
grep -q -E '^(sudo -n )?pmset -c' "$LOG" && fail "laptop: pmset modified on a laptop"

# 5. Desktop explicit opt-out: existing agent removed, no pmset writes.
mkdir -p "$WORK/optout/Library/LaunchAgents"
echo stale >"$WORK/optout/Library/LaunchAgents/com.hermes.keepawake.plist"
run_case optout HERMES_MAC_DESKTOP_ALWAYS_ON=0 FAKE_SUDO_OK=1
[[ -f "$PLIST" ]] && fail "optout: keepawake plist not removed"
grep -q '^pmset -c' "$LOG" && fail "optout: pmset modified after opt-out"

# 6. Invalid knob fails loudly.
if env -i PATH="$BIN:/usr/bin:/bin" HOME="$WORK" FAKE_LOG=/dev/null FAKE_LOADED=/dev/null \
     HERMES_MAC_DESKTOP_ALWAYS_ON=maybe bash "$MODULE" >/dev/null 2>&1; then
  fail "invalid HERMES_MAC_DESKTOP_ALWAYS_ON accepted"
fi

printf 'PASS: desktop Macs get keepawake + pmset policy; laptops and opt-outs never do\n'
