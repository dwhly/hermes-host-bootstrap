#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home/.hermes"
LOG="$TMP/herdr.log"

cat >"$TMP/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_TEST_LOG"
case "$*" in
  '--session ws agent list')
    printf '%s\n' '{"result":{"agents":[{"name":"H1"},{"name":"H3"}]}}'
    ;;
  '--session ws pane get pane-1')
    printf '%s\n' '{"result":{"pane":{"tab_id":"tab-7","cwd":"/tmp/project space"}}}'
    ;;
esac
EOF
cat >"$TMP/bin/hermes-pane" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/herdr" "$TMP/bin/hermes-pane"

python3 - "$TMP/home/.hermes/state.db" <<'PY'
import sqlite3, sys
c=sqlite3.connect(sys.argv[1])
c.execute('create table sessions(source text)')
c.executemany('insert into sessions values (?)', [('pane:H2',), ('cli',)])
c.commit()
PY

out="$(HOME="$TMP/home" PATH="$TMP/bin:$PATH" HERDR_TEST_LOG="$LOG" HERDR_PANE_ID=pane-1 HERDR_SESSION=ws "$ROOT/scripts/herdr-new-agent")"
[[ "$out" == 'Started H4 as a fresh Hermes session (right).' ]]
grep -Fx -- '--session ws agent start H4 --tab tab-7 --cwd /tmp/project space --split right --focus -- hermes-pane H4' "$LOG"

if HOME="$TMP/home" PATH="$TMP/bin:$PATH" HERDR_TEST_LOG="$LOG" "$ROOT/scripts/herdr-new-agent" left >/dev/null 2>&1; then
  printf 'invalid direction unexpectedly passed\n' >&2
  exit 1
fi

rm -f "$TMP/home/.hermes/state.db"
: >"$LOG"
out="$(HOME="$TMP/home" PATH="$TMP/bin:$PATH" HERDR_TEST_LOG="$LOG" HERDR_SESSION=ws "$ROOT/scripts/herdr-new-agent")"
[[ "$out" == 'Started H4 as a fresh Hermes session (right).' ]]
grep -Fx -- '--session ws agent start H4 --split right --focus -- hermes-pane H4' "$LOG"

printf 'PASS: herdr-new-agent selects a fresh H-slot and preserves pane placement context\n'
