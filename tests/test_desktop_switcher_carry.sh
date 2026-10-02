#!/usr/bin/env bash
# Behavioral test for scripts/hermes-desktop-carry-sync against real throwaway git repos.
# GitHub URLs are redirected to local bare repos with url.<local>.insteadOf, so the script
# runs unmodified. `hermes` is a shim that stores config get/set in a file.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYNC="$ROOT/scripts/hermes-desktop-carry-sync"
bash -n "$SYNC"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
W="$(mktemp -d)"; trap 'kill "${SLEEPER:-0}" 2>/dev/null || true; rm -rf "$W"' EXIT
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
  "config set") grep -v "^$3=" "$f" > "$f.n" || true; echo "$3=$4" >> "$f.n"; mv "$f.n" "$f" ;;
esac
SH
chmod +x "$HOME/.local/bin/hermes"
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

# 5. New carry commit, fleet base already in HEAD: taken.
fleet_do sh -c 'echo v2 >> apps/desktop/switcher.txt && git commit -qam "fix: switcher v2"'
run; expect 0 merged_new_carry_rebuild_pending
grep -q v2 "$REPO/apps/desktop/switcher.txt" || fail "new carry not merged"

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

# 11. Switched back to main by an update (strategy reset): stale carry branch with nothing
#     unique is dropped and the host re-adopts. With a unique commit it holds.
client_update
git -C "$REPO" checkout -q main; git -C "$REPO" merge -q --ff-only origin/main
"$HOME/.local/bin/hermes" config set updates.parked_branch_strategy switch
[[ "$(strategy)" == switch ]] || fail "shim reset"
run; expect 0 adopted_rebuild_pending; [[ "$(strategy)" == update_in_place ]] || fail "re-adopt strategy"
git -C "$REPO" commit -q --allow-empty -m "local only"
git -C "$REPO" checkout -q main
run; expect 3 carry_branch_has_unique_commits
git -C "$REPO" checkout -q carry/desktop-switcher

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

echo "PASS test_desktop_switcher_carry (16 scenarios)"
