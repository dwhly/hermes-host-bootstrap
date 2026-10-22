#!/usr/bin/env bash
# Scenario tests for scripts/hermes-desktop-carry-maintain against throwaway repos.
# ssh, the test-Mac check and `hermes send` are shims; nothing leaves the machine.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAINTAIN="$HERE/scripts/hermes-desktop-carry-maintain"
W="$(mktemp -d)"
trap '[ -n "${KEEP:-}" ] || rm -rf "$W"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git config --global init.defaultBranch >/dev/null 2>&1 || export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=init.defaultBranch GIT_CONFIG_VALUE_0=main

UPB="$W/up.git"; FORKB="$W/fork.git"
git init -q --bare -b main "$UPB"; git init -q --bare -b main "$FORKB"
U="$W/u"; git init -q -b main "$U"
mkdir -p "$U/apps/desktop"; echo a >"$U/apps/desktop/a.txt"; git -C "$U" add -A; git -C "$U" commit -qm base
git -C "$U" push -q "$UPB" main
F="$W/f"; git clone -q "$UPB" "$F"; git -C "$F" checkout -q -b fleet/desktop-switcher
echo switcher >"$F/apps/desktop/switcher.txt"; git -C "$F" add -A; git -C "$F" commit -qm "feat: switcher"
git -C "$F" push -q "$FORKB" fleet/desktop-switcher

up_commit() {  # up_commit <file> <content>
  git -C "$U" pull -q --no-rebase "$UPB" main
  echo "$2" >"$U/apps/desktop/$1"; git -C "$U" add -A; git -C "$U" commit -qm "up: $1"; git -C "$U" push -q "$UPB" main
}
fleet_head() { git --git-dir="$FORKB" rev-parse refs/heads/fleet/desktop-switcher; }
up_head() { git --git-dir="$UPB" rev-parse refs/heads/main; }

# shims
mkdir -p "$W/bin" "$W/conf" "$W/hosts/air2/.hermes/desktop-carry"
cat >"$W/bin/ssh" <<'SH'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -n) exec </dev/null; shift ;; -*) shift ;; *) break ;; esac; done
t="$1"; shift
case "$t" in
  fake-test) [ -n "${FAKE_SSH_DOWN:-}" ] && exit 255; exec bash -c "$*" ;;
  fake-air2) HOME="$SHIM_W/hosts/air2" exec bash -c "$*" ;;
  *) exit 255 ;;
esac
SH
cat >"$W/check.sh" <<'SH'
echo "check args: $*" >&2
echo "CHECK=${FAKE_CHECK:-pass}"
SH
cat >"$W/send.sh" <<'SH'
#!/bin/bash
{ cat; echo "---"; } >>"$SHIM_W/sent"
SH
chmod +x "$W/bin/ssh" "$W/send.sh"
printf 'h-air2\n' >"$W/conf/hosts"
printf 'test fake-test\nh-air2 fake-air2\nh-gone fake-gone\n' >"$W/conf/targets"
export SHIM_W="$W" PATH="$W/bin:$PATH"
export HERMES_CARRY_STATE="$W/state" HERMES_CARRY_CONF="$W/conf" HERMES_CARRY_FORK="$FORKB" \
       HERMES_CARRY_UPSTREAM="$UPB" HERMES_CARRY_CHECK="$W/check.sh" HERMES_CARRY_SEND="$W/send.sh"
touch "$W/sent"
sends() { grep -c '^---$' "$W/sent"; }
run() { out="$(bash "$MAINTAIN" 2>&1)"; rc=$?; [ "$rc" = 0 ] || fail "rc=$rc: $out"; }
expect() { echo "$out" | grep -q -- "$1" || fail "want '$1' in: $out"; }
client() { printf 'result=%s\nreason=%s\nhead=abc\nat=2026-10-17T00:00:00Z\n' "$1" "$2" >"$W/hosts/air2/.hermes/desktop-carry/last"; }
client ok up_to_date

# 1. Fleet already contains upstream: nothing to do.
run; expect "fleet: current"; [ "$(sends)" = 0 ] || fail "1: sent"

# 2. Upstream moves, clean merge, checks pass: fleet fast-forwards to a 2-parent merge.
f0="$(fleet_head)"; up_commit b.txt b
run; expect "fleet: advanced:"
f1="$(fleet_head)"
[ "$(git --git-dir="$FORKB" rev-parse "$f1^1")" = "$f0" ] || fail "2: first parent not old fleet"
[ "$(git --git-dir="$FORKB" rev-parse "$f1^2")" = "$(up_head)" ] || fail "2: second parent not upstream"
[ "$(git --git-dir="$FORKB" rev-parse refs/heads/fleet/desktop-switcher-candidate)" = "$f1" ] || fail "2: candidate"
[ "$(sends)" = 0 ] || fail "2: sent"

# 3. Rerun: current, deterministic, quiet.
run; expect "fleet: current"; [ "$(fleet_head)" = "$f1" ] || fail "3: moved"

# 4. Checks fail: fleet NOT advanced, one message, no repeat.
up_commit c.txt c
FAKE_CHECK="fail reason=typecheck" run; expect "fleet: tests_failed"
[ "$(fleet_head)" = "$f1" ] || fail "4: fleet advanced on failed checks"
[ "$(sends)" = 1 ] || fail "4: want 1 send, got $(sends)"
grep -q "reason=typecheck" "$W/sent" || fail "4: reason missing from message"
FAKE_CHECK="fail reason=typecheck" run; [ "$(sends)" = 1 ] || fail "4: repeated alert"
# Same candidate is not re-tested (verdict cached) even if the check would now pass.
run; expect "fleet: tests_failed"
# A new upstream commit gives a new candidate, which passes: advanced, alert cleared.
up_commit d.txt d
run; expect "fleet: advanced:"; grep -q "^testfail:" "$W/state/alerted" && fail "4: testfail alert not cleared"
f2="$(fleet_head)"

# 5. Test Mac unreachable: hold quietly, message only after a day, then recover.
up_commit e.txt e
FAKE_SSH_DOWN=1 run; expect "fleet: test_unavailable"; [ "$(fleet_head)" = "$f2" ] || fail "5: advanced"
n="$(sends)"; [ "$n" = 1 ] || fail "5: early alert"
echo 0 >"$W/state/since.test_unavailable"
FAKE_SSH_DOWN=1 run; [ "$(sends)" = 2 ] || fail "5: no alert after a day"
FAKE_SSH_DOWN=1 run; [ "$(sends)" = 2 ] || fail "5: repeated"
run; expect "fleet: advanced:"; [ -e "$W/state/since.test_unavailable" ] && fail "5: since not cleared"

# 6. Conflict: one message naming the file; fleet untouched; resolved by hand -> current.
git -C "$F" pull -q --no-rebase "$FORKB" fleet/desktop-switcher
echo fleet-a >"$F/apps/desktop/a.txt"; git -C "$F" commit -qam "fleet: a"; git -C "$F" push -q "$FORKB" fleet/desktop-switcher
f4="$(fleet_head)"; up_commit a.txt up-a
run; expect "fleet: conflict"; [ "$(fleet_head)" = "$f4" ] || fail "6: fleet moved"
[ "$(sends)" = 3 ] || fail "6: want alert"; tail -8 "$W/sent" | grep -q "apps/desktop/a.txt" || fail "6: file not named"
run; [ "$(sends)" = 3 ] || fail "6: repeated"
git -C "$F" pull -q --no-rebase "$UPB" main 2>/dev/null; echo resolved >"$F/apps/desktop/a.txt"
git -C "$F" commit -qam "merge upstream (resolved)"; git -C "$F" push -q "$FORKB" fleet/desktop-switcher
run; expect "fleet: current"; grep -q "^conflict:" "$W/state/alerted" && fail "6: conflict alert not cleared"

# 7. Clients: held -> quiet for a day, then one alert; ok clears; error alerts at once;
#    a listed host with no ssh target or no status is noted, never fatal.
client held needs_full_update; run; expect "h-air2: held (needs_full_update)"; [ "$(sends)" = 3 ] || fail "7: early"
echo 0 >"$W/state/since.client.h-air2"; run; [ "$(sends)" = 4 ] || fail "7: no stale alert"
run; [ "$(sends)" = 4 ] || fail "7: repeated"
client ok up_to_date; run; grep -q "^client:h-air2:" "$W/state/alerted" && fail "7: not cleared"
client error merge_conflict_unexpected; run; [ "$(sends)" = 5 ] || fail "7: error not alerted"
client ok up_to_date
printf 'h-air2\nh-gone\nh-nomap\n' >"$W/conf/hosts"
run; expect "h-gone: unreachable"; expect "h-nomap: no ssh target"
printf 'h-air2\n' >"$W/conf/hosts"

# 8. Fetch failure: no crash, no early alert.
HERMES_CARRY_FORK="$W/missing.git" run; expect "fleet: fetch_failed"; [ "$(sends)" = 5 ] || fail "8: early alert"

# 9. Another run holds the lock: exit quietly.
( flock 9; sleep 3 ) 9>"$W/state/lock" & sleep 0.5
run; expect "another run is active"; wait

# 10. Push failure (fork rejects): not advanced, reported, no crash.
up_commit g.txt g
printf '#!/bin/sh\necho "rejected by test" >&2\nexit 1\n' >"$FORKB/hooks/pre-receive"; chmod +x "$FORKB/hooks/pre-receive"
fpre="$(fleet_head)"; run; expect "fleet: push_failed"; [ "$(fleet_head)" = "$fpre" ] || fail "10: fleet moved"
rm -f "$FORKB/hooks/pre-receive"

# 11. Upstream merges the switcher: retired, one message.
run; expect "fleet: advanced:"
git -C "$U" pull -q --no-rebase "$UPB" main; git -C "$U" pull -q --no-rebase --no-edit "$FORKB" fleet/desktop-switcher
git -C "$U" push -q "$UPB" main; git -C "$U" commit -q --allow-empty -m "up: after merge"; git -C "$U" push -q "$UPB" main
n="$(sends)"; run; expect "fleet: retired"; [ "$(sends)" = $((n + 1)) ] || fail "11: no retired message"
run; [ "$(sends)" = $((n + 1)) ] || fail "11: repeated"

echo "PASS test_desktop_carry_maintain (11 scenarios)"
