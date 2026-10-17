#!/usr/bin/env bash
# Behavioral test for scripts/hermes-desktop-carry-sync against real throwaway git repos.
# GitHub URLs are redirected to local bare repos with url.<local>.insteadOf, so the script
# runs unmodified. `hermes` is a shim that stores config get/set in a file.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYNC="$ROOT/scripts/hermes-desktop-carry-sync"
bash -n "$SYNC"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
W="$(mktemp -d)"; trap 'if [ -n "${SLEEPER:-}" ]; then kill "$SLEEPER" 2>/dev/null || true; fi; rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME/.local/bin"
export HERMES_HOME="$HOME/.hermes"; mkdir -p "$HERMES_HOME"
export GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name t; git config --global user.email t@t
git config --global init.defaultBranch main
git config --global advice.detachedHead false
git config --global url."$W/up.git".insteadOf https://github.com/NousResearch/hermes-agent.git
git config --global url."$W/fork.git".insteadOf https://github.com/dwhly/hermes-agent.git
cat >"$HOME/.local/bin/hermes" <<'SH'
#!/bin/bash
f="$HERMES_HOME/fake-config"; touch "$f"
case "$1 $2" in
  "config get") grep "^$3=" "$f" | cut -d= -f2- ;;
  "config set") grep -v "^$3=" "$f" > "$f.n" || true; echo "$3=$4" >> "$f.n"; mv "$f.n" "$f"
                if [ -n "${SNEAK_BRANCH:-}" ]; then git -C "$HERMES_HOME/hermes-agent" checkout -q -b "$SNEAK_BRANCH"; fi ;;
esac
SH
chmod +x "$HOME/.local/bin/hermes"
REAL_GIT="$(command -v git)"
cat >"$HOME/.local/bin/git" <<SH
#!/bin/bash
# Test wrapper: on the job's merge (it alone passes --no-overwrite-ignore), run hooks.
case " \$* " in
  *" --no-overwrite-ignore "*)
    [ -n "\${BEFORE_MERGE:-}" ] && eval "\$BEFORE_MERGE"
    "$REAL_GIT" "\$@"; rc=\$?
    [ -n "\${AFTER_MERGE:-}" ] && eval "\$AFTER_MERGE"
    exit \$rc ;;
esac
exec "$REAL_GIT" "\$@"
SH
chmod +x "$HOME/.local/bin/git"
strategy() { grep '^updates.parked_branch_strategy=' "$HERMES_HOME/fake-config" 2>/dev/null | cut -d= -f2-; }
MARKER="$HERMES_HOME/.hermes-update-in-progress"

# Upstream main; fork fleet/desktop-switcher = main + carry commit under apps/desktop.
git init -q --bare "$W/up.git"; git init -q --bare "$W/fork.git"
git clone -q "$W/up.git" "$W/dev" 2>/dev/null; cd "$W/dev"
mkdir -p apps/desktop
printf 'a\nb\nc\n' > apps/desktop/shared.txt; echo base > other.txt; echo '[project]' > pyproject.toml
git add .; git commit -qm base; git push -q origin main
git checkout -qb fleet/desktop-switcher
echo switcher > apps/desktop/switcher.txt; git add .; git commit -qm "feat: switcher"
git push -q "$W/fork.git" fleet/desktop-switcher
git checkout -q main
up_commit() { git checkout -q main; "$@"; git commit -qam "up: change" >/dev/null; git push -q origin main; }
fleet_do() { git checkout -q fleet/desktop-switcher; "$@"; git push -q "$W/fork.git" fleet/desktop-switcher; git checkout -q main; }

REPO="$HERMES_HOME/hermes-agent"
git clone -q https://github.com/NousResearch/hermes-agent.git "$REPO"

run() { set +e; out="$(bash "$SYNC" 2>&1)"; rc=$?; set -e; }
expect() { # expect <rc> <reason>
  [[ "$rc" == "$1" ]] || fail "rc=$rc want $1: $out"
  grep -q "^reason=$2\$" "$HERMES_HOME/desktop-carry/last" || fail "reason want $2: $out"
  if [[ -e "$MARKER" && "$2" != update_running ]]; then fail "update marker left behind after $2"; fi
  return 0
}
head_of() { git -C "$REPO" rev-parse HEAD; }
branch_of() { git -C "$REPO" symbolic-ref --short HEAD; }
client_update() { git -C "$REPO" fetch -q origin main && git -C "$REPO" merge -q --no-edit origin/main >/dev/null; } # what hermes update does

# 1. Untracked file the carry would overwrite: git refuses; checkout restored to main.
echo mine > "$REPO/apps/desktop/switcher.txt"; h0="$(head_of)"
run; expect 3 merge_refused
[[ "$(branch_of)" == main && "$(head_of)" == "$h0" ]] || fail "refused merge changed checkout"
if git -C "$REPO" show-ref --quiet refs/heads/carry/desktop-switcher; then fail "rollback left carry branch"; fi
[[ "$(cat "$REPO/apps/desktop/switcher.txt")" == mine ]] || fail "user file touched"
rm "$REPO/apps/desktop/switcher.txt"

# 1b. Same, but the local file is IGNORED: git would silently overwrite it by default.
echo "apps/desktop/switcher.txt" >> "$REPO/.git/info/exclude"
echo precious > "$REPO/apps/desktop/switcher.txt"
run; expect 3 merge_refused
[[ "$(cat "$REPO/apps/desktop/switcher.txt")" == precious ]] || fail "ignored local file overwritten"
[[ "$(branch_of)" == main ]] || fail "ignored-file refusal changed branch"
rm "$REPO/apps/desktop/switcher.txt"; sed -i.bak '/switcher.txt/d' "$REPO/.git/info/exclude"; rm -f "$REPO/.git/info/exclude.bak"

# 1d. Adoption merge refused, and the branch is switched (same commit) before recovery:
#     the job must not check out main; it stops and leaves the state alone.
echo mine > "$REPO/apps/desktop/switcher.txt"
export AFTER_MERGE='git -C "$HERMES_HOME/hermes-agent" branch elsewhere && git -C "$HERMES_HOME/hermes-agent" symbolic-ref HEAD refs/heads/elsewhere'
run; unset AFTER_MERGE
expect 1 state_changed_during_merge
[[ "$(git -C "$REPO" symbolic-ref HEAD)" == refs/heads/elsewhere ]] || fail "rollback ran despite branch change"
git -C "$REPO" symbolic-ref HEAD refs/heads/main; git -C "$REPO" branch -q -D carry/desktop-switcher elsewhere
rm "$REPO/apps/desktop/switcher.txt"

# 1c. Branch switched by someone else between decision and change: held, no adoption.
"$HOME/.local/bin/hermes" config set updates.parked_branch_strategy switch   # so the job sets it (shim side effect fires)
export SNEAK_BRANCH=sneaky; run; unset SNEAK_BRANCH
expect 3 branch_changed
[[ "$(branch_of)" == sneaky ]] || fail "sneak: job moved the user's branch"
if git -C "$REPO" show-ref --quiet refs/heads/carry/desktop-switcher; then fail "sneak: carry branch created"; fi
git -C "$REPO" checkout -q main; git -C "$REPO" branch -q -D sneaky
"$HOME/.local/bin/hermes" config set updates.parked_branch_strategy switch

# 2. Live updater holds the marker: held, nothing changed. Stale marker: ignored, removed.
sleep 300 & SLEEPER=$!
printf '%s\n%s\n' "$SLEEPER" "$(date +%s)" > "$MARKER"
run; expect 3 update_running; [[ "$(branch_of)" == main ]] || fail "moved under live marker"
kill "$SLEEPER"; wait "$SLEEPER" 2>/dev/null || true
sleep 0 & DEAD=$!; wait "$DEAD" 2>/dev/null || true
printf '%s\n%s\n' "$DEAD" "$(date +%s)" > "$MARKER"

# 3. Adoption with an unrelated local edit: adopts, keeps the edit, releases the marker.
echo local-edit >> "$REPO/other.txt"
run; expect 0 adopted_rebuild_pending
[[ "$(branch_of)" == carry/desktop-switcher ]] || fail "not on carry"
[[ -f "$REPO/apps/desktop/switcher.txt" ]] || fail "carry not merged"
grep -q local-edit "$REPO/other.txt" || fail "local edit lost"
[[ "$(strategy)" == update_in_place ]] || fail "strategy not set"
git -C "$REPO" checkout -q -- other.txt

# 4. Idempotent; upstream advancing cleanly needs no merge from us.
h1="$(head_of)"; run; expect 0 up_to_date; [[ "$(head_of)" == "$h1" ]] || fail "rerun moved HEAD"
up_commit sh -c 'echo more >> other.txt'
run; expect 0 up_to_date; [[ "$(head_of)" == "$h1" ]] || fail "clean upstream caused a merge"

# 5. New carry commit, fleet base already in HEAD: taken, even with hostile merge config
#    (mergeOptions=--no-commit, merge.ff=only) that would leave a merge half-done.
echo note > "$REPO/local-note.txt"; git -C "$REPO" add local-note.txt; git -C "$REPO" commit -qm "local: note"
git -C "$REPO" config branch.carry/desktop-switcher.mergeOptions --no-commit
git -C "$REPO" config merge.ff only
fleet_do sh -c 'echo v2 >> apps/desktop/switcher.txt && git commit -qam "fix: switcher v2"'
run; expect 0 merged_new_carry_rebuild_pending
grep -q v2 "$REPO/apps/desktop/switcher.txt" || fail "new carry not merged"
[[ -e "$REPO/.git/MERGE_HEAD" ]] && fail "hostile config left the merge in progress"
[[ "$(git -C "$REPO" rev-list --parents -n1 HEAD | wc -w)" -eq 3 ]] || fail "scenario 5 was not a real merge commit"
git -C "$REPO" config --unset branch.carry/desktop-switcher.mergeOptions; git -C "$REPO" config --unset merge.ff

# 6. Fleet merged NEWER upstream plus a new carry commit; HEAD lacks that upstream: update_first.
up_commit sh -c 'echo newer >> other.txt'
fleet_do sh -c 'git merge -q --no-edit main && echo v3 >> apps/desktop/switcher.txt && git commit -qam "fix: v3"'
h2="$(head_of)"; run; expect 3 update_first; [[ "$(head_of)" == "$h2" ]] || fail "update_first moved HEAD"
client_update; run; expect 0 merged_new_carry_rebuild_pending
grep -q v3 "$REPO/apps/desktop/switcher.txt" || fail "v3 not merged after update"

# 7. Carry touches a shared line. Upstream then changes pyproject.toml (the client takes it
#    with a normal update) and then conflicts with the carry: held until the fleet resolves.
fleet_do sh -c "sed -i.bak 's/^b\$/carry-b/' apps/desktop/shared.txt && rm -f apps/desktop/shared.txt.bak && git commit -qam 'feat: carry touches shared'"
client_update; run; expect 0 merged_new_carry_rebuild_pending
up_commit sh -c 'echo "deps = [1]" >> pyproject.toml'; client_update
up_commit sh -c "sed -i.bak 's/^b\$/upstream-b/' apps/desktop/shared.txt && rm -f apps/desktop/shared.txt.bak"
h3="$(head_of)"; run; expect 3 waiting_for_fleet_merge; [[ "$(head_of)" == "$h3" ]] || fail "held run moved HEAD"

# 8. The resolution brings a NEW pyproject change the client lacks: needs_full_update.
up_commit sh -c 'echo "deps = [2]" >> pyproject.toml'
resolve() { git merge -q main >/dev/null 2>&1 || true; printf 'a\ncarry-b\nc\n' > apps/desktop/shared.txt; git add -A; git commit -qm "merge main (resolved)"; }
fleet_do resolve
run; expect 3 needs_full_update; [[ "$(head_of)" == "$h3" ]] || fail "deps hold moved HEAD"

# 9. Without the new deps commit, the resolution only carries the pyproject change HEAD
#    already has (step 7): no false positive, resolution taken, upstream merges cleanly.
git checkout -q main; git reset -q --hard HEAD~1; git push -q -f origin main
git checkout -q fleet/desktop-switcher; git reset -q --hard HEAD~1; resolve
git push -q -f "$W/fork.git" fleet/desktop-switcher; git checkout -q main
run; expect 0 merged_conflict_resolution_rebuild_pending
git -C "$REPO" merge-tree --write-tree HEAD origin/main >/dev/null || fail "still conflicts after resolution"

# 10. Guards: foreign branch, upstream remote, non-official origin, git op in progress, sync lock.
git -C "$REPO" checkout -q -b other; run; expect 3 foreign_branch; git -C "$REPO" checkout -q carry/desktop-switcher
git -C "$REPO" remote add upstream "$W/up.git"; run; expect 3 upstream_remote_present; git -C "$REPO" remote remove upstream
git -C "$REPO" config remote.origin.url https://github.com/dwhly/hermes-agent.git
run; expect 3 origin_not_official
git -C "$REPO" config remote.origin.url https://github.com/NousResearch/hermes-agent.git
touch "$REPO/.git/REVERT_HEAD"; run; expect 3 git_busy_REVERT_HEAD; rm "$REPO/.git/REVERT_HEAD"
mkdir "$HERMES_HOME/desktop-carry/lock"; run; expect 3 lock_busy; rmdir "$HERMES_HOME/desktop-carry/lock"

# 10b. A conflicting fleet merge with an unrelated local edit: aborted, edit kept, HEAD unchanged.
printf 'x\n' > "$REPO/apps/desktop/switcher.txt"; git -C "$REPO" commit -q -am "local: conflicting"
fleet_do sh -c 'printf "y\n" > apps/desktop/switcher.txt && git commit -qam "fix: switcher v4"'
echo keep-me >> "$REPO/other.txt"; h4="$(head_of)"
run; expect 3 merge_conflict
[[ "$(head_of)" == "$h4" ]] || fail "conflict moved HEAD"
grep -q keep-me "$REPO/other.txt" || fail "abort lost the unrelated edit"
[[ -e "$REPO/.git/MERGE_HEAD" ]] && fail "merge left in progress"
git -C "$REPO" checkout -q -- other.txt; git -C "$REPO" reset -q --hard HEAD~1

# 10c. Another updater takes the marker while our merge conflicts: we stop without aborting.
printf 'x\n' > "$REPO/apps/desktop/switcher.txt"; git -C "$REPO" commit -q -am "local: conflicting again"
fleet_do sh -c 'printf "z\n" > apps/desktop/switcher.txt && git commit -qam "fix: switcher v5"'
sleep 300 & SLEEPER=$!
export AFTER_MERGE='printf "%s\n%s\n" "$SLEEPER" "$(date +%s)" > "$HERMES_HOME/.hermes-update-in-progress"'
export SLEEPER
run; unset AFTER_MERGE
[[ "$rc" == 1 ]] || fail "marker loss: rc=$rc: $out"
grep -q "^reason=marker_lost_during_merge$" "$HERMES_HOME/desktop-carry/last" || fail "marker loss not reported: $out"
[[ -e "$REPO/.git/MERGE_HEAD" ]] || fail "job touched the merge after losing the marker"
[[ "$(head -n1 "$MARKER")" == "$SLEEPER" ]] || fail "job removed the other updater's marker"
kill "$SLEEPER"; wait "$SLEEPER" 2>/dev/null || true; SLEEPER=""; rm -f "$MARKER"
git -C "$REPO" merge --abort; git -C "$REPO" reset -q --hard HEAD~1

# 10d. HEAD moved on the same branch while our merge conflicts: no abort, merge left alone.
printf 'x\n' > "$REPO/apps/desktop/switcher.txt"; git -C "$REPO" commit -q -am "local: conflicting once more"
h5="$(head_of)"
export AFTER_MERGE='git -C "$HERMES_HOME/hermes-agent" update-ref refs/heads/carry/desktop-switcher HEAD~1'
run; unset AFTER_MERGE
[[ "$rc" == 1 ]] || fail "moved HEAD: rc=$rc: $out"
grep -q "^reason=state_changed_during_merge$" "$HERMES_HOME/desktop-carry/last" || fail "moved HEAD not reported: $out"
[[ -e "$REPO/.git/MERGE_HEAD" ]] || fail "job aborted the merge after HEAD moved"
git -C "$REPO" update-ref refs/heads/carry/desktop-switcher "$h5"; git -C "$REPO" merge --abort; git -C "$REPO" reset -q --hard HEAD~1

# 11. Switched back to main by an update (strategy reset): stale carry branch with nothing
#     unique is dropped and the host re-adopts. With a unique commit it holds.
client_update
git -C "$REPO" checkout -q main; git -C "$REPO" merge -q --ff-only origin/main
"$HOME/.local/bin/hermes" config set updates.parked_branch_strategy switch
[[ "$(strategy)" == switch ]] || fail "shim reset"
run; expect 0 adopted_rebuild_pending; [[ "$(strategy)" == update_in_place ]] || fail "re-adopt strategy"
git -C "$REPO" commit -q --allow-empty -m "local only"; local_only="$(head_of)"
git -C "$REPO" checkout -q main
run; expect 0 adopted_rebuild_pending
stale="$(git -C "$REPO" for-each-ref --contains "$local_only" --format='%(refname:short)' 'refs/heads/carry/desktop-switcher-stale-*' | head -1)"
[[ -n "$stale" ]] || fail "local-only commit lost (no kept branch contains it)"
grep -q "kept leftover branch as $stale" "$HERMES_HOME/desktop-carry/sync.log" || fail "rename not logged"

# 12. Retirement by squash merge: upstream gets the same apps/desktop content, no ancestry.
git checkout -q main; git checkout -q fleet/desktop-switcher -- apps/desktop; git commit -qm "squash: switcher"; git push -q origin main
fleet_do sh -c 'git merge -q --no-edit main'
run; expect 0 retired_strategy_switch; [[ "$(strategy)" == switch ]] || fail "strategy not switched back"
run; expect 0 retired

# 12b. Sticky: a later upstream desktop commit the fleet hasn't merged yet keeps it retired.
up_commit sh -c 'echo later >> apps/desktop/shared.txt'
run; expect 0 retired; [[ "$(strategy)" == switch ]] || fail "un-retired after upstream desktop commit"

# 12c. A host on main that set update_in_place but never adopted is reset on retirement.
git -C "$REPO" checkout -q main; "$HOME/.local/bin/hermes" config set updates.parked_branch_strategy update_in_place
run; expect 0 retired_strategy_switch; [[ "$(strategy)" == switch ]] || fail "main host strategy not reset"

echo "PASS test_desktop_switcher_carry (22 scenarios)"
