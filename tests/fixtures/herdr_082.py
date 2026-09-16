#!/usr/bin/env python3
"""Stateful Herdr 0.8.2 CLI double; focus RPC is served by the test."""
import json
import os
import sys
from pathlib import Path

path = Path(os.environ["HERDR_082_STATE"])
state = json.loads(path.read_text())
args = sys.argv[1:]
assert args[:2] == ["--session", "review"]
args = args[2:]
with open(os.environ["HERDR_082_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")


def save():
    path.write_text(json.dumps(state))


def emit(kind, value):
    print(json.dumps({"result": {kind: value}}))


def pane(pid):
    return next(p for p in state["panes"] if p["pane_id"] == pid)


cmd = args[:2]
if cmd == ["status", "server"]:
    print(json.dumps({"status": "running", "running": True, "socket": state["socket"]}))
elif cmd == ["agent", "list"]:
    emit("agents", state.get("agents", []))
elif cmd == ["pane", "list"]:
    emit("panes", state["panes"])
elif cmd == ["agent", "start"] and args[2:] == ["--help"]:
    print("Usage: herdr agent start <NAME> --kind <KIND> --pane <ID>")
elif cmd in (["workspace", "create"], ["pane", "split"]):
    assert args[-2:] == ["--env", "NO_TMUX=1"]
    pid = "w1:p" + str(len(state["panes"]) + 1)
    created = {"pane_id": pid, "workspace_id": "w1", "tab_id": "w1:t1", "focused": False}
    state["panes"].append(created)
    save()
    emit("root_pane" if cmd[0] == "workspace" else "pane", created)
elif cmd == ["pane", "rename"]:
    pane(args[2])["label"] = args[3]
    save()
elif cmd == ["pane", "run"]:
    pane(args[2]).update(state.get("launched", {}))
    save()
    sys.exit(state.get("run_status", 0))
elif cmd == ["pane", "get"]:
    value = pane(args[2]).copy()
    value.update(state.get("get_override", {}))
    emit("pane", value)
elif cmd == ["pane", "read"]:
    assert args[3:5] == ["--source", "visible"], "readiness must not read history"
    sys.stdout.write(state.get("visible", ""))
    sys.exit(state.get("read_status", 0))
elif cmd == ["pane", "process-info"]:
    assert args[2:3] == ["--pane"]
    emit("process_info", dict(state.get("process", {}), pane_id=args[3]))
    sys.exit(state.get("process_status", 0))
elif cmd == ["agent", "get"]:
    emit("agent", state.get("agent_get", {}).get(args[2]) or
         next(a for a in state["agents"] if a.get("name") == args[2]))
elif cmd == ["agent", "focus"]:
    target = pane(args[2])
    if target.get("agent") is None:
        sys.exit(1)  # 0.8.2 rejects pane IDs without semantic identity.
    if not state.get("focus_noop"):
        for p in state["panes"]:
            p["focused"] = p is target
        save()
elif cmd == ["workspace", "focus"]:
    pass  # Preserves the previously focused pane; NOT exact H1 focus.
elif cmd == ["pane", "focus"]:
    sys.exit(2)  # 0.8.2 CLI is directional, not pane.focus <ID>.
else:
    raise AssertionError(args)
