#!/usr/bin/env bash
# Behavioral test for scripts/hermes-desktop-carry-sync against real throwaway git repos.
# GitHub URLs are redirected to local bare repos with url.<local>.insteadOf, so the script
# runs unmodified. `hermes` is a shim that stores config get/set in a file.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYNC="$ROOT/scripts/hermes-desktop-carry-sync"
bash -n "$SYNC"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME/.local/bin"
export HERMES_HOME="$HOME/.hermes"; mkdir -p "$HERMES_HOME"
export GIT_CONFIG_GLOBAL="$W/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name t; git config --global user.email t@t
git config --global init.defaultBranch main
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

# Upstream repo with main; fork with fleet/desktop-switcher = main + carry commit.
git init -q --bare "$W/up.git"; git init -q --bare "$W/fork.git"
git clone -q "$W/up.git" "$W/dev" 2>/dev/null; cd "$W/dev"
printf 'a\nb\nc\n' > shared.txt; echo base > other.txt; git add .; git commit -qm base; git push -q origin main
git checkout -qb fleet/desktop-switcher; echo switcher > switcher.txt; git add .; git commit -qm "feat: switcher"
git push -q "$W/fork.git" fleet/desktop-switcher
git checkout -q main

# Client checkout: official origin URL (raw), on main.
REPO="$HERMES_HOME/hermes-agent"
git clone -q https://github.com/NousResearch/hermes-agent.git "$REPO"
git -C "$REPO" config --get remote.origin.url | grep -q NousResearch || fail "origin url raw"

run() { set +e; out="$(bash "$SYNC" 2>&1)"; rc=$?; set -e; }
expect() { # expect <rc> <reason>
  [[ "$rc" == "$1" ]] || fail "rc=$rc want $1: $out"
  grep -q "^reason=$2\$" "$HERMES_HOME/desktop-carry/last" || fail "reason want $2: $out"
}
head_of() { git -C "$REPO" rev-parse HEAD; }
branch_of() { git -C "$REPO" symbolic-ref --short HEAD; }

# 1. Dirty tree on main: held, nothing changed.
echo dirty >> "$REPO/other.txt"; h0="$(head_of)"
run; expect 3 dirty_tree
[[ "$(branch_of)" == main && "$(head_of)" == "$h0" ]] || fail "dirty changed checkout"
git -C "$REPO" checkout -q -- other.txt

# 2. Adoption.
run; expect 0 adopted_rebuild_pending
[[ "$(branch_of)" == carry/desktop-switcher ]] || fail "not on carry"
[[ -f "$REPO/switcher.txt" ]] || fail "carry not merged"
[[ "$(strategy)" == update_in_place ]] || fail "strategy not set"

# 3. Idempotent.
h1="$(head_of)"; run; expect 0 up_to_date; [[ "$(head_of)" == "$h1" ]] || fail "rerun moved HEAD"

# 4. Upstream advances cleanly: no merge by us (hermes update handles it).
cd "$W/dev"; echo more >> other.txt; git commit -qam "up: clean"; git push -q origin main
run; expect 0 up_to_date; [[ "$(head_of)" == "$h1" ]] || fail "clean upstream caused a merge"

# 5. Upstream conflicts with the carry; fleet branch not resolved yet: held.
git checkout -q fleet/desktop-switcher; sed -i.bak 's/^b$/carry-b/' shared.txt; rm -f shared.txt.bak
git commit -qam "feat: switcher touches shared"; git push -q "$W/fork.git" fleet/desktop-switcher
git checkout -q main
run; expect 0 merged_new_carry_rebuild_pending   # new carry commit is taken
h2="$(head_of)"
sed -i.bak 's/^b$/upstream-b/' shared.txt; rm -f shared.txt.bak; git commit -qam "up: conflicting"; git push -q origin main
run; expect 3 waiting_for_fleet_merge; [[ "$(head_of)" == "$h2" ]] || fail "held run moved HEAD"

# 6. Central resolution lands on the fleet branch: client takes it.
git checkout -q fleet/desktop-switcher; git merge -q main 2>/dev/null || true
printf 'a\ncarry-b\nc\n' > shared.txt; git add shared.txt; git commit -qm "merge main (resolved)"
git push -q "$W/fork.git" fleet/desktop-switcher; git checkout -q main
run; expect 0 merged_conflict_resolution_rebuild_pending
git -C "$REPO" merge-tree --write-tree HEAD origin/main >/dev/null || fail "still conflicts after resolution"

# 7. Foreign branch and upstream remote: held.
git -C "$REPO" checkout -q -b other; run; expect 3 foreign_branch; git -C "$REPO" checkout -q carry/desktop-switcher
git -C "$REPO" remote add upstream "$W/up.git"; run; expect 3 upstream_remote_present; git -C "$REPO" remote remove upstream

# 8. Non-official origin (fork mode): held.
git -C "$REPO" config remote.origin.url https://github.com/dwhly/hermes-agent.git
run; expect 3 origin_not_official
git -C "$REPO" config remote.origin.url https://github.com/NousResearch/hermes-agent.git

# 9. Retirement: upstream merges the fleet branch -> strategy back to switch.
git merge -q --no-edit fleet/desktop-switcher 2>/dev/null; git push -q origin main
git fetch -q "$W/fork.git" fleet/desktop-switcher:fleet/desktop-switcher 2>/dev/null || true
run; expect 0 retired_strategy_switch; [[ "$(strategy)" == switch ]] || fail "strategy not switched back"
run; expect 0 retired

# 10. Lock held by a live run: held, no change.
mkdir "$HERMES_HOME/desktop-carry/lock"; run; expect 3 lock_busy; rmdir "$HERMES_HOME/desktop-carry/lock"

echo "PASS test_desktop_switcher_carry (10 scenarios)"
