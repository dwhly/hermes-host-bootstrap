#!/bin/bash
# herdr-compatibility fixes for a LIVE Hermes v0.23 install (guinea pig h-mini). Reversible: bash live-fixes.sh revert
#   Fix 1  launcher   ~/.local/bin/hermes becomes a python FILE named `hermes` (same body as the official launcher)
#                     so herdr sees `python3 -I …/bin/hermes …` and recognises Hermes. It also tells herdr which
#                     session a tab RESUMES (`--resume/-r <id>`), because only the tab itself knows that.
#   Fix 2  plugin     herdr's Hermes plugin reports NEW chats using the chat's own environment (v0.23 runs chats
#                     inside one shared gateway); its per-turn re-report is disabled because v0.23 freezes that
#                     environment at chat creation, so after a resume elsewhere it would name the wrong tab.
set -eu
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
HH="${HERMES_HOME:-$HOME/.hermes}"; OFF="$HH/hermes-agent/.hermes/bin/hermes"; LB="$HOME/.local/bin/hermes"
PLUG="$HH/plugins/herdr-agent-state/__init__.py"
if [ "${1:-apply}" = revert ]; then
  [ -f "$LB.pre-fleetfix" ] && mv -f "$LB.pre-fleetfix" "$LB"
  [ -f "$PLUG.pre-fleetfix" ] && mv -f "$PLUG.pre-fleetfix" "$PLUG"
  echo reverted; exit 0
fi
# ---- Fix 1
PY=$(sed -n 's/^exec \([^ ]*python3\) -I -c .*/\1/p' "$OFF" | head -1); [ -x "$PY" ] || { echo "no python in $OFF"; exit 1; }
grep -q "FLEET-HERDR-LAUNCHER" "$LB" 2>/dev/null || cp -p "$LB" "$LB.pre-fleetfix"
tmp=$(mktemp); { echo 'dump() { printf "%s" "$3"; }'; sed "s#^exec $PY #dump #" "$OFF"; } > "$tmp.sh"
body=$(sh "$tmp.sh"); rm -f "$tmp" "$tmp.sh"; [ -n "$body" ] || { echo "empty launcher body"; exit 1; }
{ printf '#!%s -I\n' "$PY"
  printf '# FLEET-HERDR-LAUNCHER: generated from %s by fleet live-fixes.sh. Rerun after every hermes update.\n' "$OFF"
  cat <<'PYEOF'
def _fleet_herdr_report_resume():
    import os as _o, sys as _s, subprocess as _sp, time as _t
    if _o.environ.get("HERDR_ENV") != "1" or not _o.environ.get("HERDR_PANE_ID"):
        return
    a = _s.argv[1:]; sid = None
    for i, x in enumerate(a):
        if x in ("--resume", "-r") and i + 1 < len(a):
            sid = a[i + 1]
        elif x.startswith("--resume="):
            sid = x.split("=", 1)[1]
    if not sid or sid.startswith("-"):
        return
    try:
        _sp.run([_o.environ.get("HERDR_BIN_PATH") or "herdr", "pane", "report-agent-session", _o.environ["HERDR_PANE_ID"],
                 "--source", "herdr:hermes", "--agent", "hermes", "--seq", str(_t.time_ns()),
                 "--agent-session-id", sid, "--session-start-source", "resume"],
                timeout=2, stdout=_sp.DEVNULL, stderr=_sp.DEVNULL, check=False)
    except Exception:
        pass
_fleet_herdr_report_resume()
del _fleet_herdr_report_resume
PYEOF
  printf '%s\n' "$body"; } > "$LB.new" && chmod +x "$LB.new" && mv -f "$LB.new" "$LB"
echo "fix1: $("$LB" --version | head -1)"
# ---- Fix 2 (start from herdr's pristine v5 plugin every time)
herdr integration install hermes >/dev/null 2>&1 || true
[ -f "$PLUG.pre-fleetfix" ] || cp -p "$PLUG" "$PLUG.pre-fleetfix"
grep -q "FLEET-V023-PATCH" "$PLUG" && cp -p "$PLUG.pre-fleetfix" "$PLUG"
hermes config set terminal.client_env_passthrough '["HERDR_ENV","HERDR_PANE_ID","HERDR_TAB_ID","HERDR_WORKSPACE_ID","HERDR_SESSION","HERDR_SOCKET_PATH","HERDR_BIN_PATH"]' | tail -1
"$PY" - "$PLUG" <<'EOF'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace('''def _pane_id() -> str | None:
    if os.environ.get("HERDR_ENV") != "1":
        return None
    return os.environ.get("HERDR_PANE_ID", "").strip() or None''','''# FLEET-V023-PATCH: under v0.23 every chat runs in the shared gateway, so the pane's HERDR_* values
# arrive as the chat's client_env (terminal.client_env_passthrough), not in this process's os.environ.
# v0.23 freezes that env when the chat is CREATED, so it is only trusted for new chats (start/reset);
# resumes are reported by the fleet launcher (~/.local/bin/hermes), which runs in the resuming tab.
def _env(name: str, default: str = "") -> str:
    try:
        from agent.session_client_env import session_env
        v = session_env(name, "")
        if v:
            return v
    except Exception:
        pass
    return os.environ.get(name, default)


def _pane_id() -> str | None:
    if _env("HERDR_ENV") != "1":
        return None
    return _env("HERDR_PANE_ID").strip() or None''')
s=s.replace('os.environ.get("HERDR_BIN_PATH") or "herdr"','_env("HERDR_BIN_PATH") or "herdr"')
s=s.replace('''        kwargs = {"timeout": 1, "stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL}''','''        env = dict(os.environ)
        for n in ("HERDR_ENV", "HERDR_PANE_ID", "HERDR_SESSION", "HERDR_SOCKET_PATH"):
            if _env(n):
                env[n] = _env(n)
        kwargs = {"timeout": 1, "stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL, "env": env}''')
s=s.replace('''    if kwargs.get("platform") == "cli":
        _report_session("resume", **kwargs)''','''    return  # FLEET-V023-PATCH: frozen client env could name the tab the chat was created in, not this one''')
open(p,'w').write(s)
ok = s.count('FLEET-V023-PATCH') >= 2 and '"env": env' in s and 'tab the chat was created in' in s
print('fix2:', 'patched' if ok else 'PATCH FAILED')
EOF
"$PY" -m py_compile "$PLUG"
hermes gateway restart >/dev/null 2>&1; sleep 10
hermes gateway status 2>&1 | grep -E "^(✓|✗)"
