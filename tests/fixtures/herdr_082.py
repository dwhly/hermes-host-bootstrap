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
    tmp = path.with_suffix(".tmp" + str(os.getpid()))
    tmp.write_text(json.dumps(state))
    os.replace(tmp, path)  # the backgrounded `server` races status reads


def emit(kind, value):
    print(json.dumps({"result": {kind: value}}))


def pane(pid):
    return next(p for p in state["panes"] if p["pane_id"] == pid)


cmd = args[:2]
if cmd == ["status", "server"]:
    if state.get("stopped"):
        print(json.dumps({"status": "stopped", "running": False}))
        sys.exit(1)
    print(json.dumps({"status": "running", "running": True, "socket": state["socket"]}))
elif args == ["server"]:
    state["stopped"] = False  # restores the saved layout as fresh shells
    save()
elif args == ["server", "stop"]:
    state["stopped"] = True
    save()
elif cmd == ["agent", "list"]:
    emit("agents", state.get("agents", []))
elif cmd == ["pane", "list"]:
    emit("panes", state["panes"])
elif cmd == ["agent", "start"] and args[2:] == ["--help"]:
    print("Usage: herdr agent start <NAME> --kind <KIND> --pane <ID>")
elif cmd == ["agent", "start"]:
    # 0.8.2: agent start <NAME> --kind K --pane P [--timeout MS] [-- ARGS...].
    # Succeeds only for a pane whose foreground is its shell at the prompt
    # (fixture flag at_prompt); then the pane runs the agent.
    import re
    rest = args[2:]
    sep = rest.index("--") if "--" in rest else len(rest)
    opts, agent_args = rest[:sep], rest[sep + 1:]
    name = opts[0]
    flags = dict(zip(opts[1::2], opts[2::2]))
    assert set(flags) <= {"--kind", "--pane", "--timeout"} and len(opts) % 2 == 1, args
    if not re.fullmatch(r"[a-z][a-z0-9_-]{0,31}", name):
        sys.exit(1)
    target = flags["--pane"]
    info = state.get("process_by_pane", {}).get(target, state.get("process", {}))
    jobs = info.get("foreground_processes") or []
    if pane(target).get("agent") is not None or not (info.get("at_prompt") and len(jobs) == 1 and jobs[0].get("pid") == info.get("shell_pid")):
        print(json.dumps({"error": {"code": "agent_pane_busy"}}))
        sys.exit(1)
    pane(target).update(state.get("launched", {}))
    launched_state = dict(state.get("launched_state", {}))
    if "process" in launched_state:
        state.setdefault("process_by_pane", {})[target] = launched_state.pop("process")
    state.update(launched_state)
    save()
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
    launched_state = dict(state.get("launched_state", {}))
    if "process" in launched_state:
        # The launch changes only the foreground of the pane it ran in.
        state.setdefault("process_by_pane", {})[args[2]] = launched_state.pop("process")
    state.update(launched_state)
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
    info = state.get("process_by_pane", {}).get(args[3], state.get("process", {}))
    emit("process_info", dict(info, pane_id=args[3]))
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
