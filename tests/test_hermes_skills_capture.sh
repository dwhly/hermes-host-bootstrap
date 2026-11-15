#!/usr/bin/env bash
# tests/test_hermes_skills_capture.sh — hermes-skills-capture against a local bare repo (no network).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
CAP="$HERE/scripts/hermes-skills-capture"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; failn=0
ok() { echo "ok - $1"; pass=$((pass+1)); }
no() { echo "FAIL - $1"; failn=$((failn+1)); }
st() { python3 -c "import json,sys; print(json.load(open('$T/state/status.json'))['$1'])"; }

git init -q --bare -b main "$T/remote.git"
mkdir -p "$T/skills/alpha/references" "$T/skills/beta/__pycache__"
printf -- '---\nname: alpha\n---\nUse op://Vault/item/field for the key.\n' >"$T/skills/alpha/SKILL.md"
echo "ref" >"$T/skills/alpha/references/r.md"
echo "junk" >"$T/skills/beta/__pycache__/x.pyc"
echo "TOKEN=abc" >"$T/skills/beta/.env"
echo "beta" >"$T/skills/beta/SKILL.md"
ln -s /etc/hostname "$T/skills/beta/link"
run() { "$CAP" --skills "$T/skills" --repo "$T/remote.git" --state "$T/state" --host testhost "$@"; }

# 1. dry run commits nothing
run --dry-run >/dev/null
[[ "$(st result)" == "dry-run" ]] && ! git --git-dir="$T/remote.git" rev-parse -q --verify main >/dev/null && ok "dry run pushes nothing" || no "dry run"

# 2. first capture pushes, excludes caches and env files, keeps op:// references
run >/dev/null
files="$(git --git-dir="$T/remote.git" ls-tree -r --name-only main)"
[[ "$(st result)" == "pushed" ]] && ok "first capture pushed" || no "first capture result $(st result)"
grep -qx "skills/alpha/SKILL.md" <<<"$files" && grep -qx "skills/alpha/references/r.md" <<<"$files" && ok "skills captured" || no "skills missing: $files"
! grep -q -e '\.env' -e '__pycache__' <<<"$files" && ok "env + cache files excluded" || no "excluded files leaked: $files"
[[ "$(git --git-dir="$T/remote.git" log -1 --format=%an main)" == "Hermes skills capture (testhost)" ]] && ok "author names the host" || no "author"

# 3. unchanged run is a no-op
before="$(git --git-dir="$T/remote.git" rev-parse main)"
run >/dev/null
[[ "$(st result)" == "unchanged" && "$(git --git-dir="$T/remote.git" rev-parse main)" == "$before" ]] && ok "unchanged run makes no commit" || no "unchanged"

# 4. edit + delete are captured
echo "more" >>"$T/skills/alpha/SKILL.md"; rm -rf "$T/skills/beta"
run >/dev/null
files="$(git --git-dir="$T/remote.git" ls-tree -r --name-only main)"
[[ "$(st result)" == "pushed" && "$(st changed_paths)" == "3" ]] && ! grep -q beta <<<"$files" && ok "edit + delete captured (3 paths)" || no "edit/delete: $(st result) $(st changed_paths) $files"

# 5. a credential blocks the run: exit 3, nothing pushed, value never in the status or hits file
before="$(git --git-dir="$T/remote.git" rev-parse main)"
FAKE="ghp_$(printf 'A%.0s' {1..36})"
echo "token: $FAKE" >"$T/skills/alpha/leak.md"
set +e; run >/dev/null 2>&1; rc=$?; set -e
[[ "$rc" == "3" && "$(st result)" == "blocked-secret" ]] && ok "credential blocks (exit 3)" || no "credential rc=$rc $(st result)"
[[ "$(git --git-dir="$T/remote.git" rev-parse main)" == "$before" ]] && ok "nothing pushed when blocked" || no "pushed despite secret"
! grep -rq "$FAKE" "$T/state/status.json" "$T/state/scan-hits.txt" && grep -q "leak.md:1: github-token" "$T/state/scan-hits.txt" && ok "hit reported as file:line: pattern, no value" || no "hit report"
[[ -z "$(git -C "$T/state/work" status --porcelain)" ]] && ok "working clone left clean after block" || no "working clone dirty"

# 6. removing the credential unblocks
rm "$T/skills/alpha/leak.md"
run >/dev/null
[[ "$(st result)" == "unchanged" ]] && ok "unblocked after the credential is removed" || no "after removal: $(st result)"

# 7. a clone pointing at another repo is refused
git init -q --bare -b main "$T/other.git"
set +e; "$CAP" --skills "$T/skills" --repo "$T/other.git" --state "$T/state" >/dev/null 2>&1; rc=$?; set -e
[[ "$rc" != "0" && "$(st result)" == "error" ]] && ok "refuses a working clone for another repo" || no "other repo rc=$rc"

# 8. a rejected push is an error, never a force push
run >/dev/null
tmpc="$T/other-writer"; git clone -q "$T/remote.git" "$tmpc"
(cd "$tmpc" && echo x >README.md && git add README.md && git -c user.name=t -c user.email=t@t commit -qm readme && git push -q origin main)
echo "racing edit" >>"$T/skills/alpha/SKILL.md"
run >/dev/null 2>&1 && rebased=1 || rebased=0
git --git-dir="$T/remote.git" cat-file -e main:README.md && ok "another writer's commit survives (fetch+reset keeps it)" || no "remote commit lost"

echo "# $pass passed, $failn failed"
[[ "$failn" == "0" ]]
