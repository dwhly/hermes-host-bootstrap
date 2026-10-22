#!/usr/bin/env bash
# Scenario tests for scripts/hermes-desktop-carry-check (runs on the test Mac).
# Real git + node; npm/npx/vitest are fakes driven by env, so every verdict rule is
# exercised without building Desktop.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$HERE/scripts/hermes-desktop-carry-check"
W="$(mktemp -d)"
trap 'kill "${SLEEPER:-}" 2>/dev/null; rm -rf "$W"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
NODE="$(command -v node)" || { echo "SKIP: node not installed"; exit 0; }

UPB="$W/up.git"; FORKB="$W/fork.git"
git init -q --bare -b main "$UPB"; git init -q --bare -b main "$FORKB"
U="$W/u"; git init -q -b main "$U"; mkdir -p "$U/apps/desktop/src"
echo base >"$U/apps/desktop/src/a.ts"; git -C "$U" add -A; git -C "$U" commit -qm base; git -C "$U" push -q "$UPB" main
BASE="$(git -C "$U" rev-parse HEAD)"
git -C "$U" checkout -q -b cand; echo sw >"$U/apps/desktop/src/switcher.tsx"; git -C "$U" add -A; git -C "$U" commit -qm sw
CAND="$(git -C "$U" rev-parse HEAD)"
git -C "$U" push -q "$FORKB" cand:refs/heads/fleet/desktop-switcher-candidate

export HOME="$W/home"; mkdir -p "$HOME/.local/bin"
export HERMES_CARRY_CI_DIR="$HOME/build/switcher-ci" CAND_ID="$CAND"
ln -s "$NODE" "$HOME/.local/bin/node"
cat >"$HOME/.local/bin/npm" <<'SH'
#!/bin/bash
case "$*" in *typecheck*) exit "${FAKE_TC_RC:-0}" ;; esac
exit "${FAKE_NPM_RC:-0}"
SH
cat >"$HOME/.local/bin/npx" <<'SH'
#!/bin/bash
[ "$1" = -y ] && shift 2
case "$1" in eslint) exit "${FAKE_LINT_RC:-0}" ;; ci) exit "${FAKE_NPM_RC:-0}" ;; vitest) ;; *) exit 0 ;; esac
case "$PWD" in *-base/*) mode="${FAKE_VT_BASE:-ok}" ;; *) mode="${FAKE_VT_CAND:-ok}" ;; esac
out=""; for a in "$@"; do case "$a" in --outputFile.json=*) out="${a#--outputFile.json=}" ;; esac; done
results=""; rc=0
add() { results="${results:+$results,}{\"name\":\"$PWD/src/$1.test.ts\",\"status\":\"failed\",\"assertionResults\":[{\"status\":\"failed\",\"fullName\":\"$1 works\"}]}"; rc=1; }
for m in ${mode//,/ }; do
  case "$m" in
    ok) ;;
    fail:*) add "${m#fail:}" ;;
    runner) rc=1 ;;
    unhandled) echo "Unhandled Error: boom"; rc=1 ;;
    nojson) out="" ; rc=1 ;;
    undercount) rc=1 ;;
    hangterm) exec bash -c 'trap "" TERM; exec -a "fake-hang-$0" sleep 60' "$CAND_ID" ;;
    slow) sleep 2 ;;
    killed) killed=1 ;;
    orphan)  # real node runner spawns a worker, then dies by signal, orphaning it
      exec node -e '
        require("child_process").spawn("bash", ["-c", "exec -a fake-orphan-" + process.argv[1] + " sleep 60"], { stdio: "inherit" }).unref()
        setTimeout(() => process.kill(process.pid, "SIGKILL"), 300)' "$CAND_ID" ;;
  esac
done
echo " Test Files  1 passed"
n=$(( $(echo "$results" | grep -o '"assertionResults"' | wc -l) ))
[ "$mode" = undercount ] && n=$((n + 1))
[ -n "$results" ] || results='{"name":"'"$PWD"'/src/ok.test.ts","status":"passed","assertionResults":[]}'
[ -n "$out" ] && echo "{\"numFailedTests\":$n,\"testResults\":[${results}]}" >"$out"
[ -n "${killed:-}" ] && exit 137
exit "$rc"
SH
chmod +x "$HOME/.local/bin/npm" "$HOME/.local/bin/npx"

run() { out="$(bash "$CHECK" "${1:-$CAND}" "$BASE" "$FORKB" "$UPB" 2>"$W/err")"; res="$(echo "$out" | grep '^CHECK=' | tail -1)"; }
want() { [ "$res" = "$1" ] || fail "$2: want '$1' got '$res' ($(tail -3 "$W/err" | tr '\n' ' '))"; }

run; want "CHECK=pass" "1 clean"
FAKE_VT_CAND=fail:x FAKE_VT_BASE=fail:x run; want "CHECK=pass" "2 shared failure"
FAKE_VT_CAND=fail:x,fail:y FAKE_VT_BASE=fail:x run; want "CHECK=fail reason=tests n=1" "3 candidate-only failure"
FAKE_VT_CAND=runner run; want "CHECK=fail reason=runner_error" "4 runner error, nothing to compare"
FAKE_VT_CAND=fail:x,unhandled FAKE_VT_BASE=fail:x run; want "CHECK=fail reason=unhandled_error" "5 candidate-only unhandled error"
FAKE_VT_CAND=fail:x,unhandled FAKE_VT_BASE=fail:x,unhandled run; want "CHECK=fail reason=unhandled_error" "5b candidate unhandled always blocks"
FAKE_VT_CAND=undercount run; want "CHECK=fail reason=runner_error" "5c runner count exceeds named failures"
FAKE_VT_CAND=fail:x FAKE_VT_BASE=nojson run; want "CHECK=error reason=base_vitest_no_results" "6 baseline incomplete"
FAKE_VT_CAND=nojson run; want "CHECK=error reason=vitest_no_results" "6b candidate incomplete"
FAKE_TC_RC=2 run; want "CHECK=fail reason=typecheck" "7 typecheck"
FAKE_LINT_RC=1 run; want "CHECK=fail reason=eslint" "7b eslint"
FAKE_NPM_RC=1 run; want "CHECK=error reason=npm_ci_failed" "7c install"

# 8. Lock (kernel flock): a live holder blocks; a leftover lock file alone does not.
hold() { perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; sleep 30' "$HERMES_CARRY_CI_DIR.lock" & SLEEPER=$!; sleep 0.5; }
hold; run; want "CHECK=error reason=busy" "8 live holder"
kill "$SLEEPER"; wait "$SLEEPER" 2>/dev/null
run; want "CHECK=pass" "8b lock file left behind is not a lock"
# 8c. Two checks at once: exactly one runs.
FAKE_VT_CAND=slow bash "$CHECK" "$CAND" "$BASE" "$FORKB" "$UPB" >"$W/c1" 2>/dev/null & C1=$!
sleep 0.5; run; want "CHECK=error reason=busy" "8c concurrent run"
wait "$C1"; grep -q '^CHECK=pass' "$W/c1" || fail "8c first run did not pass"
# 8d. A hung step that ignores TERM is KILLed on SIGHUP; nothing survives; lock free.
FAKE_VT_CAND=hangterm bash "$CHECK" "$CAND" "$BASE" "$FORKB" "$UPB" >/dev/null 2>&1 & CP=$!
for _ in $(seq 1 50); do pgrep -f "fake-hang-$CAND" >/dev/null && break; sleep 0.2; done
pgrep -f "fake-hang-$CAND" >/dev/null || fail "8d hang never started"
t0=$SECONDS; kill -HUP "$CP"; wait "$CP" 2>/dev/null; sleep 0.5
[ $((SECONDS - t0)) -lt 15 ] || fail "8d cleanup too slow ($((SECONDS - t0))s)"
pgrep -f "fake-hang-$CAND" >/dev/null && fail "8d TERM-ignoring descendant survived"
run; want "CHECK=pass" "8e lock free after cleanup"
# 8e2. Repeated signals: TERM starts cleanup, HUP arrives mid-reap. Cleanup must still
#      finish: the TERM-ignoring step is KILLed before the check exits.
FAKE_VT_CAND=hangterm bash "$CHECK" "$CAND" "$BASE" "$FORKB" "$UPB" >/dev/null 2>&1 & CP=$!
for _ in $(seq 1 50); do pgrep -f "fake-hang-$CAND" >/dev/null && break; sleep 0.2; done
pgrep -f "fake-hang-$CAND" >/dev/null || fail "8e2 hang never started"
kill -TERM "$CP"; sleep 1.5; kill -HUP "$CP"; sleep 0.3; kill -TERM "$CP" 2>/dev/null
wait "$CP" 2>/dev/null; sleep 0.5
pgrep -f "fake-hang-$CAND" >/dev/null && fail "8e2 second signal cut cleanup short: step survived"
run; want "CHECK=pass" "8e2 next run after repeated signals"

# 8f. A runner killed by a signal is an error even if its JSON shows only shared failures.
FAKE_VT_CAND=fail:x,killed FAKE_VT_BASE=fail:x run; want "CHECK=error reason=vitest_killed rc=137" "8f killed runner"

# 8g. Real node: a runner killed by a signal leaves an orphaned worker (no lock fd);
#     its step group is reaped before the check returns, and the next run is free.
FAKE_VT_CAND=orphan run; want "CHECK=error reason=vitest_killed rc=137" "8g killed runner"
sleep 0.5; pgrep -f "fake-orphan-$CAND" >/dev/null && fail "8g orphaned worker survived the check"
run; want "CHECK=pass" "8h next run after orphan"

# 8i. A step group that cannot be stopped: an error (never a pass, even with only shared
#     failures). The verdict is delivered and the caller returns at once, but the run
#     keeps the lock for as long as the group survives -- no time limit -- and frees
#     it only once the group is confirmed gone.
STUCK="$W/stuck"; : >"$STUCK"
t0=$SECONDS
HERMES_CARRY_TEST_STUCK="$STUCK" FAKE_VT_CAND=fail:x FAKE_VT_BASE=fail:x \
  bash "$CHECK" "$CAND" "$BASE" "$FORKB" "$UPB" >"$W/c2" 2>/dev/null
grep -q '^CHECK=error reason=cleanup_failed$' "$W/c2" || fail "8i want cleanup_failed, got: $(cat "$W/c2")"
[ $((SECONDS - t0)) -lt 40 ] || fail "8i caller waited for the hold ($((SECONDS - t0))s)"
run; want "CHECK=error reason=busy" "8i lock held while a group survives"
sleep 20
run; want "CHECK=error reason=busy" "8i lock still held 20s later (no time limit)"
rm -f "$STUCK"; sleep 7
run; want "CHECK=pass" "8j lock released once the group is gone"

# 9. The reused baseline worktree is cleaned before use.
echo junk >"$HERMES_CARRY_CI_DIR-base/apps/desktop/stale.generated.ts"
FAKE_VT_CAND=fail:x FAKE_VT_BASE=fail:x run; want "CHECK=pass" "9 run"
[ -e "$HERMES_CARRY_CI_DIR-base/apps/desktop/stale.generated.ts" ] && fail "9 baseline not cleaned"

# 10. Unknown candidate.
run 0000000000000000000000000000000000000001; want "CHECK=error reason=candidate_missing" "10 missing candidate"

echo "PASS test_desktop_carry_check (29 checks)"
