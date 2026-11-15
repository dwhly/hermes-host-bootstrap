#!/usr/bin/env bash
# Behavioral test for lib/M9-mac-config-pull.sh: scope gates, install, idempotence, removal.
# Shims uname/launchctl/plutil in a throwaway HOME; never touches the real launchd domain.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODULE="$ROOT/lib/M9-mac-config-pull.sh"
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
  bootout) [[ -n "${FAKE_STICKY:-}" ]] || rm -f "$FAKE_LOADED" ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/plutil"
chmod +x "$BIN"/*

mkdir -p "$WORK/r/lib"
cp "$ROOT/lib/common.sh" "$MODULE" "$WORK/r/lib/"

mk_home() { # mk_home <dir> [nogit|noscript]
  mkdir -p "$1/.hermes/scripts"
  [[ "${2:-}" == nogit ]] || mkdir -p "$1/.hermes/.git"
  [[ "${2:-}" == noscript ]] || printf '#!/bin/bash\n' >"$1/.hermes/scripts/hermes-config-pull.sh"
}

run_case() { # run_case <name> <home-variant> [VAR=value ...]
  local name="$1" variant="$2"; shift 2
  H="$WORK/$name"; mk_home "$H" "$variant"
  LOG="$H/calls.log"; : >"$LOG"
  PLIST="$H/Library/LaunchAgents/com.hermes.config-pull.plist"
  OUT="$(env -i PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$H" HERMES_HOSTNAME=h-test \
    ROLE=client TIER=recommended FAKE_LOG="$LOG" FAKE_LOADED="$H/loaded" "$@" \
    bash "$WORK/r/lib/M9-mac-config-pull.sh" 2>&1)" || { RC=$?; return 0; }
  RC=0
}

# 1. Mac client: agent written, scheduled, loaded; never --adopt-fleet.
run_case install ok
[[ $RC == 0 ]] || fail "install: rc=$RC $OUT"
grep -q 'StartInterval<' "$PLIST" && fail "install: StartInterval skips runs missed in sleep"
[[ "$(grep -c '<key>Minute</key>' "$PLIST")" == 2 ]] || fail "install: want 2 calendar slots"
grep -q '<integer>7</integer>' "$PLIST" && grep -q '<integer>37</integer>' "$PLIST" || fail "install: slots 7,37"
grep -q "<string>$H/.hermes/scripts/hermes-config-pull.sh</string><string>--quiet</string>" "$PLIST" || fail "install: args"
grep -q 'adopt-fleet' "$PLIST" && fail "install: must never adopt fleet"
grep -q "<key>HERMES_HOME</key><string>$H/.hermes</string>" "$PLIST" || fail "install: HERMES_HOME"
grep -q 'launchctl bootstrap' "$LOG" || fail "install: not bootstrapped"

# 2. Re-run with no change: no reload.
: >"$LOG"
OUT="$(env -i PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$H" HERMES_HOSTNAME=h-test ROLE=client TIER=recommended \
  FAKE_LOG="$LOG" FAKE_LOADED="$H/loaded" bash "$WORK/r/lib/M9-mac-config-pull.sh" 2>&1)" || fail "rerun: $OUT"
grep -q 'bootout\|bootstrap' "$LOG" && fail "rerun: reloaded an unchanged agent"

# 3. Changed interval on a loaded agent: reload with the new definition.
: >"$LOG"
OUT="$(env -i PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$H" HERMES_HOSTNAME=h-test ROLE=client TIER=recommended \
  HERMES_CONFIG_PULL_INTERVAL_MIN=60 FAKE_LOG="$LOG" FAKE_LOADED="$H/loaded" bash "$WORK/r/lib/M9-mac-config-pull.sh" 2>&1)" || fail "change: $OUT"
[[ "$(grep -c '<key>Minute</key>' "$PLIST")" == 1 ]] || fail "change: interval not updated"
grep -q 'launchctl bootout' "$LOG" && grep -q 'launchctl bootstrap' "$LOG" || fail "change: not reloaded"

# 3b. Reload whose bootout never completes must fail, not report success.
OUT="$(env -i PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$H" HERMES_HOSTNAME=h-test ROLE=client TIER=recommended \
  HERMES_CONFIG_PULL_INTERVAL_MIN=15 FAKE_STICKY=1 FAKE_LOG="$LOG" FAKE_LOADED="$H/loaded" bash "$WORK/r/lib/M9-mac-config-pull.sh" 2>&1)" \
  && fail "sticky: reported success with the old agent still loaded"
[[ -f "$H/loaded" ]] || fail "sticky: shim state"

# 4. Opt-out removes the agent.
OUT="$(env -i PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$H" HERMES_HOSTNAME=h-test ROLE=client TIER=recommended \
  HERMES_CONFIG_PULL_SCHEDULE=0 FAKE_LOG="$LOG" FAKE_LOADED="$H/loaded" bash "$WORK/r/lib/M9-mac-config-pull.sh" 2>&1)" || fail "optout: $OUT"
[[ -f "$PLIST" ]] && fail "optout: plist left"

# 5. Linux / server role / untracked home / missing script: no agent.
run_case linux ok FAKE_UNAME=Linux;  [[ $RC == 0 && ! -f "$PLIST" ]] || fail "linux: $OUT"
run_case server ok ROLE=server;      [[ $RC == 0 && ! -f "$PLIST" ]] || fail "server: $OUT"
run_case nogit nogit;                [[ $RC == 0 && ! -f "$PLIST" ]] || fail "nogit: $OUT"
run_case noscript noscript;          [[ $RC == 0 && ! -f "$PLIST" ]] || fail "noscript: $OUT"

# 6. Bad knobs fail loudly.
run_case badint ok HERMES_CONFIG_PULL_INTERVAL_MIN=2; [[ $RC != 0 ]] || fail "badint accepted"
run_case badknob ok HERMES_CONFIG_PULL_SCHEDULE=yes;  [[ $RC != 0 ]] || fail "badknob accepted"
run_case octal ok HERMES_CONFIG_PULL_INTERVAL_MIN=030; [[ $RC != 0 ]] || fail "030 accepted"
run_case octal8 ok HERMES_CONFIG_PULL_INTERVAL_MIN=08; [[ $RC != 0 ]] || fail "08 accepted"

# 7. XML metacharacters in HERMES_HOME still give a well-formed plist.
AMP="$WORK/amp/A & <B>/.hermes"; mkdir -p "$AMP/.git" "$AMP/scripts"; printf '#!/bin/bash\n' >"$AMP/scripts/hermes-config-pull.sh"
run_case amp ok "HERMES_HOME=$AMP"
[[ $RC == 0 ]] || fail "amp: $OUT"
python3 -c 'import sys,xml.dom.minidom as m; m.parse(sys.argv[1])' "$PLIST" || fail "amp: plist not well-formed XML"

# 8. --skip reaches the module through the real entry point (arrays don't cross `bash "$path"`).
B="$WORK/b"; mkdir -p "$B"; cp -R "$ROOT/bootstrap.sh" "$ROOT/lib" "$B/"
H="$WORK/viaboot"; mk_home "$H" ok; LOG="$H/calls.log"; : >"$LOG"
OUT="$(env -i PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$H" USER=t HERMES_HOSTNAME=h-test HERMES_NONINTERACTIVE=1 \
  FAKE_LOG="$LOG" FAKE_LOADED="$H/loaded" bash "$B/bootstrap.sh" --role=client --only=M9-mac-config-pull \
  --skip=config-pull-schedule </dev/null 2>&1)" || true
grep -q 'config-pull schedule: opted out via --skip' <<<"$OUT" || fail "viaboot: skip not honoured:\n$OUT"
[[ -f "$H/Library/LaunchAgents/com.hermes.config-pull.plist" ]] && fail "viaboot: agent installed despite --skip"
# ...and without --skip the same entry point installs it.
OUT="$(env -i PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$H" USER=t HERMES_HOSTNAME=h-test HERMES_NONINTERACTIVE=1 \
  FAKE_LOG="$LOG" FAKE_LOADED="$H/loaded" bash "$B/bootstrap.sh" --role=client --only=M9-mac-config-pull </dev/null 2>&1)" || true
[[ -f "$H/Library/LaunchAgents/com.hermes.config-pull.plist" ]] || fail "viaboot: not installed without --skip:\n$OUT"

echo "PASS test_mac_config_pull_module"
