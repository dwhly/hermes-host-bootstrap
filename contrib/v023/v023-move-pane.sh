#!/bin/bash
# Move one live herdr tab's Hermes from the old v0.21 process to v0.23, resuming the SAME session.
# Usage: bash move-pane.sh <pane_id> <LABEL> <session_id> [recipe|hermes-pane]
set -u
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
P=$1; LBL=$2; SID=$3; MODE=${4:-recipe}; H=(herdr --session ws)
jr() { python3 -c "import json,sys; d=json.load(sys.stdin); d=d.get('result',d); $1"; }
readp() { "${H[@]}" pane read "$P" --lines "${1:-8}" 2>/dev/null; }
fg() { "${H[@]}" pane get "$P" | jr "q=d.get('pane',d); print(q.get('agent'), q.get('agent_status'), (q.get('agent_session') or {}).get('value'))"; }
echo "before: $(fg)"
"${H[@]}" pane send-keys "$P" Escape >/dev/null 2>&1; sleep 0.5
"${H[@]}" pane run "$P" "/exit" >/dev/null; sleep 8
# hermes-pane drops to a shell after Hermes exits; make sure it is a bare prompt
readp 3 | tail -2
"${H[@]}" pane run "$P" "clear" >/dev/null; sleep 1
s=$(date +%s)
if [ "$MODE" = hermes-pane ]; then
  "${H[@]}" agent start "$(echo "$LBL" | tr A-Z a-z)" --kind hermes --pane "$P" --timeout 90000 -- -c "hermes-pane $LBL" >/dev/null 2>&1 \
    || "${H[@]}" pane run "$P" "hermes-pane $LBL" >/dev/null
else
  "${H[@]}" agent start "$(echo "$LBL" | tr A-Z a-z)" --kind hermes --pane "$P" --timeout 90000 -- chat --source "pane:$LBL" --resume "$SID" >/dev/null 2>&1
fi
echo "start rc=$? after $(( $(date +%s)-s ))s"
for _ in $(seq 1 60); do readp 6 | grep -qE "ready +│" && break; sleep 1; done
echo "after: $(fg)"
ps -axo pid,tty,command | grep -E "\.local/bin/hermes|venv/bin/hermes" | grep -v grep | cut -c1-130
readp 12 | grep -vE "^\s*$" | tail -6 | cut -c1-120
