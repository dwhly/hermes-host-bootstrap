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
export HERMES_CARRY_CI_DIR="$HOME/build/switcher-ci"
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
  esac
done
echo " Test Files  1 passed"
[ -n "$out" ] && echo "{\"testResults\":[${results}]}" >"$out"
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
FAKE_VT_CAND=fail:x,unhandled FAKE_VT_BASE=fail:x,unhandled run; want "CHECK=pass" "5b unhandled on both"
FAKE_VT_CAND=fail:x FAKE_VT_BASE=nojson run; want "CHECK=error reason=base_vitest_no_results" "6 baseline incomplete"
FAKE_VT_CAND=nojson run; want "CHECK=error reason=vitest_no_results" "6b candidate incomplete"
FAKE_TC_RC=2 run; want "CHECK=fail reason=typecheck" "7 typecheck"
FAKE_LINT_RC=1 run; want "CHECK=fail reason=eslint" "7b eslint"
FAKE_NPM_RC=1 run; want "CHECK=error reason=npm_ci_failed" "7c install"

# 8. Lock: a live holder blocks; a dead holder's lock is reclaimed.
sleep 30 & SLEEPER=$!
mkdir "$HERMES_CARRY_CI_DIR.lock"; echo "$SLEEPER" >"$HERMES_CARRY_CI_DIR.lock/pid"
run; want "CHECK=error reason=busy" "8 live lock"
kill "$SLEEPER"; wait "$SLEEPER" 2>/dev/null
run; want "CHECK=pass" "8b stale lock reclaimed"
[ -e "$HERMES_CARRY_CI_DIR.lock" ] && fail "8c lock left behind"

# 9. The reused baseline worktree is cleaned before use.
echo junk >"$HERMES_CARRY_CI_DIR-base/apps/desktop/stale.generated.ts"
FAKE_VT_CAND=fail:x FAKE_VT_BASE=fail:x run; want "CHECK=pass" "9 run"
[ -e "$HERMES_CARRY_CI_DIR-base/apps/desktop/stale.generated.ts" ] && fail "9 baseline not cleaned"

# 10. Unknown candidate.
run 0000000000000000000000000000000000000001; want "CHECK=error reason=candidate_missing" "10 missing candidate"

echo "PASS test_desktop_carry_check (17 checks)"
