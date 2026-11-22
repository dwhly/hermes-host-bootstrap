#!/bin/bash
# Hard-kill the LIVE ws herdr server (simulated crash / shutdown race), restart it, and record what comes back.
set -u
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
H=(herdr --session ws); E="$HOME/hermes-backups/crash-$(date +%H%M%S)"; mkdir -p "$E"
jr() { python3 -c "import json,sys; d=json.load(sys.stdin); d=d.get('result',d); $1"; }
panes() { "${H[@]}" pane list | jr "[print(p['pane_id'],p.get('label'),p.get('agent'),p.get('agent_status'),(p.get('agent_session') or {}).get('value')) for p in d['panes']]"; }
hermesps() { ps -axo pid,tty,command | grep -E "\.local/bin/hermes (chat|--resume|-r)" | grep -v grep | cut -c1-160; }
echo "== before"; panes | tee "$E/before.txt"; hermesps
cp -p "$HOME/.config/herdr/sessions/ws/session.json" "$E/session.json.before"
SP=$(pgrep -f -- "herdr.*--session ws.*server|herdr server.*ws" | head -1)
[ -n "$SP" ] || SP=$(lsof -t "$HOME/.config/herdr/sessions/ws/herdr.sock" 2>/dev/null | head -1)
echo "server pid=$SP ($(ps -o command= -p "$SP" | cut -c1-80))"
kill -9 "$SP"; sleep 3
echo "== after kill: hermes processes left"; hermesps
(nohup herdr --session ws server > "$E/server.out" 2>&1 < /dev/null &); sleep 15
echo "== after restart (15s)"; panes | tee "$E/after15.txt"; hermesps
sleep 30
echo "== after restart (45s)"; panes | tee "$E/after45.txt"; hermesps
for p in $("${H[@]}" pane list | jr "[print(p['pane_id']) for p in d['panes']]"); do
  echo "-- $p"; "${H[@]}" pane read "$p" --lines 30 | grep -vE "^\s*$" | tail -3 | cut -c1-110; done
grep -iE "resum|agent_session|restore" "$HOME/.config/herdr/sessions/ws/herdr-server.log" | tail -8 | cut -c1-220
echo "evidence: $E"
