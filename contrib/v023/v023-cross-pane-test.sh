#!/bin/bash
# Which pane does the herdr plugin see when a v0.23-created chat is resumed in a DIFFERENT tab?
set -u
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
H=(herdr --session ws); D="$HOME/hermes-backups/herdr-plugin-debug.log"
jr() { python3 -c "import json,sys; d=json.load(sys.stdin); d=d.get('result',d); $1"; }
readp() { "${H[@]}" pane read "$1" --lines "${2:-6}" 2>/dev/null; }
waitready() { for _ in $(seq 1 60); do readp "$1" 6 | grep -qE "ready +│" && return 0; sleep 1; done; return 1; }
ask() { waitready "$1"; "${H[@]}" pane run "$1" "$2" >/dev/null; sleep 1; "${H[@]}" pane send-keys "$1" Enter >/dev/null; sleep 30; }
sidof() { "${H[@]}" pane get "$1" | jr "q=d.get('pane',d); print((q.get('agent_session') or {}).get('value'))"; }
newtab() { w=$("${H[@]}" workspace list | jr "print(d['workspaces'][0]['workspace_id'])")
  p=$("${H[@]}" tab create --workspace "$w" --cwd "$HOME" --env NO_TMUX=1 --no-focus | jr "print(d['root_pane']['pane_id'])")
  "${H[@]}" pane rename "$p" "$1" >/dev/null; sleep 2; echo "$p"; }
: > "$D"
A=$(newtab ZTEST1); echo "A=$A"
"${H[@]}" agent start ztest1 --kind hermes --pane "$A" --timeout 90000 -- chat --source pane:ZTEST1 >/dev/null 2>&1; echo "start A rc=$?"
ask "$A" "Remember codeword PLUM-9. Reply OK."
SID=$(sidof "$A"); echo "A herdr sid=$SID"
"${H[@]}" pane run "$A" "/exit" >/dev/null; sleep 6
B=$(newtab ZTEST2); echo "B=$B"
"${H[@]}" agent start ztest2 --kind hermes --pane "$B" --timeout 90000 -- chat --source pane:ZTEST2 --resume "$SID" >/dev/null 2>&1; echo "start B rc=$?"
ask "$B" "Codeword? One word."
readp "$B" 8 | grep -q PLUM-9 && echo "B remembers codeword" || echo "B codeword MISSING"
echo "B herdr sid=$(sidof "$B")   A herdr sid now=$(sidof "$A")"
echo "--- plugin saw:"; cat "$D"
echo "ZTEST tabs: A=$A B=$B"
