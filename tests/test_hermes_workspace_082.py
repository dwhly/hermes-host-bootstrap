#!/usr/bin/env python3
"""Adversarial launcher tests using 0.8.2 CLI shapes and real Unix RPC."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "scripts/hermes-workspace"
COMPOSER = "Hermes Agent v0.16\nType your message or /help for commands.\n❯ Ask me anything…\n"
LIVE = {"shell_pid": 10, "foreground_process_group_id": 20,
        "foreground_processes": [{"pid": 20, "name": "hermes", "argv": ["hermes"]}]}
STORE_PY = "/root/.hermes/tools/python-3.14.7-linux-x64/bin/python3"


def launcher_script(module):
    # Mirrors hermes_cli/_launchers.py::_launcher_script (the h-af v0.21.5 shape).
    return ("import os, re, sys\nos.environ.pop('PYTHONHOME', None)\nos.environ.pop('PYTHONPATH', None)\n"
            "sys.path.insert(0, '/usr/local/lib/hermes-agent')\n"
            "if sys.argv[1:2] == ['--print-runtime-command']: sys.dont_write_bytecode = True\n"
            "from hermes_constants import get_default_hermes_root\n"
            "os.environ['HERMES_HOME'] = os.environ.get('HERMES_HOME') or str(get_default_hermes_root())\n"
            "if sys.argv[1:2] == ['--print-runtime-command']:\n    from pathlib import Path\n"
            "    from hermes_cli._launchers import print_runtime_command\n"
            "    print_runtime_command(Path('/usr/local/lib/hermes-agent'), sys.argv[2:])\n    sys.exit(0)\n"
            "import hermes_bootstrap\nif sys.argv[1:2] == ['--run-module']:\n    import runpy\n"
            "    if len(sys.argv) < 3: sys.exit('hermes: --run-module needs a module')\n"
            "    module = sys.argv.pop(2)\n    del sys.argv[1]\n"
            "    runpy.run_module(module, run_name='__main__', alter_sys=True)\n    sys.exit(0)\n"
            f"from {module} import main\n"
            "sys.argv[0] = re.sub(r'(-script\\.pyw|\\.exe)?$', '', sys.argv[0])\nsys.exit(main())\n")


# Mirrors hermes_cli/_launchers.py runtime-command form (module entry).
RUNTIME_COMMAND = ("import os, sys, runpy; os.environ.pop('PYTHONHOME', None); "
                   "os.environ.pop('PYTHONPATH', None); os.environ.pop('VIRTUAL_ENV', None); "
                   "sys.path.insert(0, '/usr/local/lib/hermes-agent'); "
                   "os.environ['HERMES_HOME'] = os.environ.get('HERMES_HOME') or '/root/.hermes'; "
                   "import hermes_bootstrap; "
                   "runpy.run_module('hermes_cli.main', run_name='__main__', alter_sys=True)")
# at_prompt: the fixture's `agent start` accepts only a shell at its prompt.
SHELL = {"shell_pid": 10, "foreground_process_group_id": 10, "at_prompt": True,
         "foreground_processes": [{"pid": 10, "name": "bash", "argv": ["bash"]}]}


def start(name, pane, *agent_args):
    return ["agent", "start", name, "--kind", "hermes", "--pane", pane, "--timeout", "3000", "--"] + list(agent_args)


class Herdr082Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="hmw082-")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        shutil.copyfile(ROOT / "tests/fixtures/herdr_082.py", self.bin / "herdr")
        (self.bin / "herdr").chmod(0o755)
        for name in ("hermes-pane", "sleep"):
            (self.bin / name).write_text("#!/bin/sh\nexit 0\n")
            (self.bin / name).chmod(0o755)
        self.path = self.home / "state.json"
        self.log = self.home / "calls.jsonl"
        self.sockpath = str(self.home / "herdr.sock")
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(self.sockpath)
        self.listener.listen()
        self.listener.settimeout(0.1)
        self.stopping = threading.Event()
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()
        self.addCleanup(self.stop)
        self.write(panes=[self.pane("H1")])

    def stop(self):
        self.stopping.set()
        self.thread.join(2)
        self.listener.close()

    def serve(self):
        while not self.stopping.is_set():
            try:
                conn, _ = self.listener.accept()
            except socket.timeout:
                continue
            with conn, conn.makefile("rwb") as stream:
                req = json.loads(stream.readline())
                with self.log.open("a") as log:
                    log.write(json.dumps(req) + "\n")
                state = self.state()
                target = req["params"]["pane_id"]
                if req["method"] != "pane.focus" or state.get("rpc_error"):
                    response = {"id": req["id"], "error": {"code": "refused"}}
                else:
                    if not state.get("focus_noop"):
                        for p in state["panes"]:
                            p["focused"] = p["pane_id"] == target
                        self.path.write_text(json.dumps(state))
                    found = next(p for p in state["panes"] if p["pane_id"] == target)
                    response = {"id": req["id"], "result": state.get(
                        "rpc_result", {"type": "pane_info", "pane": found})}
                stream.write((json.dumps(response) + "\n").encode())
                stream.flush()

    def pane(self, label, pid="w1:p1", **kw):
        return dict(pane_id=pid, label=label, workspace_id="w1", tab_id="w1:t1", focused=False, **kw)

    def write(self, **kw):
        state = dict(socket=self.sockpath, panes=[], agents=[], visible=COMPOSER, process=LIVE)
        state.update(kw)
        self.path.write_text(json.dumps(state))

    def state(self):
        return json.loads(self.path.read_text())

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def run_core(self, count=1):
        env = dict(os.environ, HOME=str(self.home), PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                   HMW_BACKEND="herdr", HMW_REMOTE="1", HMW_VERIFY="1", HERDR_SESSION="review",
                   HMW_HERDR_READY_TIMEOUT="3", HMW_RESTORE_LOCK_WAIT="2",
                   HERMES_HOME=str(self.home / ".hermes"), HERDR_082_STATE=str(self.path), HERDR_082_LOG=str(self.log))
        return subprocess.run(["bash", str(CORE), str(count)], env=env, capture_output=True, text=True, timeout=25)

    def assert_failed(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("inventory-end", result.stdout)

    def assert_no_launch(self):
        for call in self.calls():
            if isinstance(call, list):
                self.assertNotIn(call[:2], [["pane", "split"], ["workspace", "create"], ["pane", "run"]])

    def restored(self, **kw):
        # A saved layout after reboot: labelled H1/H2 plus an unlabelled pane, all idle shells.
        self.write(panes=[self.pane("H1"), self.pane("H2", "w1:p2"), self.pane("", "w1:p3")],
                   visible="", process=SHELL, **kw)

    def pane_runs(self):
        return [c for c in self.calls() if isinstance(c, list) and c[:2] == ["pane", "run"]]

    def agent_starts(self):
        # Restore launches only through Herdr's agent start: never pane run/typing.
        self.assertEqual(self.pane_runs(), [])
        return [c for c in self.calls() if isinstance(c, list) and c[:2] == ["agent", "start"]
                and c[2:] != ["--help"]]

    def test_reboot_restore_relaunches_hermes_once_per_labelled_pane(self):
        self.restored(stopped=True, launched_state={"visible": COMPOSER, "process": LIVE})
        result = self.run_core(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.agent_starts(), [start("h1", "w1:p1", "chat", "--source", "pane:H1"),
                                               start("h2", "w1:p2", "chat", "--source", "pane:H2")])
        for call in self.calls():
            if isinstance(call, list):
                self.assertNotIn(call[:2], [["pane", "split"], ["workspace", "create"], ["pane", "close"]])
        self.assertEqual(len(self.state()["panes"]), 3)
        self.assertFalse((self.home / ".hermes/logs/hmw-review.restore.lock").exists())

    def test_reboot_running_session_idle_label_still_refuses(self):
        self.restored()
        result = self.run_core(2)
        self.assert_failed(result)
        self.assertIn("no duplicate was created", result.stderr)
        self.assert_no_launch()
        self.assertNotIn(["server", "stop"], self.calls())

    def test_reboot_restore_lock_held_refuses_with_hint(self):
        self.restored(stopped=True, launched_state={"visible": COMPOSER, "process": LIVE})
        lock = self.home / ".hermes/logs/hmw-review.restore.lock"
        lock.mkdir(parents=True)
        result = self.run_core(2)
        self.assert_failed(result)
        self.assertIn(str(lock), result.stderr)
        # Refused before touching Herdr at all (no calls log is fine).
        self.assertEqual(self.pane_runs() if self.log.exists() else [], [])
        self.assertTrue(lock.is_dir())

    def test_running_session_waits_while_another_hmw_restores(self):
        # Overlapping client: a held restore lock blocks attach even when the
        # server is already running (another hmw may still be relaunching).
        self.write(panes=[self.pane("H1", agent="hermes")])
        lock = self.home / ".hermes/logs/hmw-review.restore.lock"
        lock.mkdir(parents=True)
        result = self.run_core(1)
        self.assert_failed(result)
        self.assertIn(str(lock), result.stderr)
        # Refused before touching Herdr at all (no calls log is fine).
        self.assertEqual(self.pane_runs() if self.log.exists() else [], [])

    # ── pane memory: snapshot pane -> live Hermes session, resume on reboot ──
    def fg(self, pid):
        return {"shell_pid": 10, "foreground_process_group_id": pid,
                "foreground_processes": [{"pid": pid, "name": "hermes", "argv": ["hermes"]}]}

    @staticmethod
    def start_of(pid):
        # What the fake /proc below yields (psutil's Linux create_time formula).
        return pid * 100 / os.sysconf("SC_CLK_TCK") + 1000.0

    def run_snapshot(self, leases, tree):
        runtime = self.home / ".hermes/runtime"
        runtime.mkdir(parents=True, exist_ok=True)
        leases = [dict(l, process_start_time=l.get("process_start_time", self.start_of(l["pid"])))
                  for l in leases]
        (runtime / "active_sessions.json").write_text(json.dumps({"entries": leases}))
        (self.bin / "ps").write_text("#!/bin/sh\ncat <<'EOF'\n" + "".join(
            "%d %d\n" % kv for kv in tree.items()) + "EOF\n")
        (self.bin / "ps").chmod(0o755)
        proc = self.home / "proc"
        proc.mkdir(exist_ok=True)
        (proc / "stat").write_text("cpu 0 0 0\nbtime 1000\n")
        for pid, ppid in tree.items():
            (proc / str(pid)).mkdir(exist_ok=True)
            fields = ["S", str(ppid)] + ["0"] * 17 + [str(pid * 100), "0"]   # field 22 = starttime
            (proc / str(pid) / "stat").write_text("%d (x y) %s\n" % (pid, " ".join(fields)))
        env = dict(os.environ, HOME=str(self.home), PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                   HMW_BACKEND="herdr", HMW_SNAPSHOT="1", HERDR_SESSION="review",
                   HERMES_HOME=str(self.home / ".hermes"), HMW_PROC_ROOT=str(proc),
                   HERDR_082_STATE=str(self.path), HERDR_082_LOG=str(self.log))
        return subprocess.run(["bash", str(CORE)], env=env, capture_output=True, text=True, timeout=25)

    def snapshot_path(self):
        return self.home / ".hermes/hmw/review.panes.json"

    def test_pane_memory_snapshot_maps_lease_descendants_to_panes(self):
        self.write(panes=[self.pane("H1", agent="hermes"), dict(self.pane("", "w1:p3"), tab_id="w1:t2"),
                          self.pane("", "w1:p4"), self.pane("", "w1:p5")],
                   process_by_pane={"w1:p1": self.fg(100), "w1:p3": self.fg(300),
                                    "w1:p4": SHELL, "w1:p5": self.fg(500)})
        # TUI: hermes(100) -> node(101) -> tui_gateway(102) holds the lease.
        tree = {100: 10, 101: 100, 102: 101, 300: 10, 301: 300, 500: 10, 501: 500, 502: 500, 999: 1}
        leases = [dict(session_id="S_A", surface="tui", pid=102),
                  dict(session_id="S_GW", surface="gateway", pid=102),   # not a chat surface
                  dict(session_id="S_B", surface="cli", pid=300),
                  dict(session_id="S_OTHER", surface="tui", pid=999),    # not under any pane
                  dict(session_id="S_X", surface="cli", pid=501),        # two sessions in
                  dict(session_id="S_Y", surface="cli", pid=502)]        # one pane: ambiguous
        result = self.run_snapshot(leases, tree)
        self.assertEqual(result.returncode, 0, result.stderr)
        snap = json.loads(self.snapshot_path().read_text())
        self.assertIn("saved_at", snap)
        self.assertEqual([(p["pane_id"], p["tab_id"], p["pane_label"], p["session_id"]) for p in snap["panes"]],
                         [("w1:p1", "w1:t1", "H1", "S_A"), ("w1:p3", "w1:t2", None, "S_B")])
        self.assertEqual(list(self.snapshot_path().parent.glob("*.tmp.*")), [])

    def test_pane_memory_snapshot_waits_out_a_pending_restore(self):
        self.write(panes=[self.pane("H1")], process_by_pane={"w1:p1": SHELL})
        self.snapshot_path().parent.mkdir(parents=True)
        held = {"saved_at": 1, "restore_pending_until": 4102444800,
                "panes": [{"pane_id": "w1:p1", "tab_id": "w1:t1", "session_id": "S_A"}]}
        self.snapshot_path().write_text(json.dumps(held))
        self.assertEqual(self.run_snapshot([], {}).returncode, 0)
        self.assertEqual(json.loads(self.snapshot_path().read_text()), held)

    def test_pane_memory_reboot_resumes_every_pane_once(self):
        tabbed = lambda label, pid, tab, **kw: dict(self.pane(label, pid, **kw), tab_id=tab)
        self.write(panes=[self.pane("H1"), self.pane("H2", "w1:p2"), tabbed("", "w1:p3", "w1:t2"),
                          tabbed("", "w1:p4", "w1:t3"), tabbed("", "w1:p5", "w1:t4", agent="hermes"),
                          tabbed("", "w1:p6", "w1:t5"), tabbed("", "w1:p7", "w1:t6")],
                   visible="", process=SHELL, stopped=True,
                   launched_state={"visible": COMPOSER, "process": LIVE})
        self.snapshot_path().parent.mkdir(parents=True)
        self.snapshot_path().write_text(json.dumps({"saved_at": time.time(), "panes": [
            {"pane_id": "w1:p1", "tab_id": "w1:t1", "pane_label": "H1", "session_id": "S_H1"},
            {"pane_id": "w9:p3", "tab_id": "w9:t2", "session_id": "S_EMAIL"},   # renumbered workspace
            {"pane_id": "w1:p5", "tab_id": "w1:t4", "session_id": "S_LIVE"},    # already has Hermes
        ]}))
        result = self.run_core(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.agent_starts(), [
            start("h1", "w1:p1", "chat", "--source", "pane:H1", "--resume", "S_H1"),
            start("hmw-w1-p3", "w1:p3", "chat", "--resume", "S_EMAIL"),   # unlabelled tab
            start("h2", "w1:p2", "chat", "--source", "pane:H2")])         # labelled fallback (fresh)
        self.assertGreater(json.loads(self.snapshot_path().read_text())["restore_pending_until"], 0)

    def test_pane_memory_running_server_never_retypes_snapshot(self):
        self.write(panes=[self.pane("H1", agent="hermes"), dict(self.pane("", "w1:p3"), tab_id="w1:t2")])
        self.snapshot_path().parent.mkdir(parents=True)
        self.snapshot_path().write_text(json.dumps({"saved_at": time.time(), "panes": [
            {"pane_id": "w1:p3", "tab_id": "w1:t2", "session_id": "S_EMAIL"}]}))
        self.assertEqual(self.run_core(1).returncode, 0)
        self.assertEqual(self.agent_starts(), [])

    # ── review r1 findings ──
    def reboot_with(self, panes, snapshot, **kw):
        self.write(panes=panes, visible="", process=SHELL, stopped=True,
                   launched_state={"visible": COMPOSER, "process": LIVE}, **kw)
        self.snapshot_path().parent.mkdir(parents=True, exist_ok=True)
        self.snapshot_path().write_text(json.dumps(snapshot))
        result = self.run_core(1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.result = result
        return self.agent_starts()

    def test_pane_memory_f1_restore_skips_pane_not_at_prompt(self):
        tabbed = lambda label, pid, tab, **kw: dict(self.pane(label, pid, **kw), tab_id=tab)
        vim = {"shell_pid": 10, "foreground_process_group_id": 30,
               "foreground_processes": [{"pid": 30, "name": "vim", "argv": ["vim", "notes"]}]}
        two = {"shell_pid": 10, "foreground_process_group_id": 10, "foreground_processes": [
            {"pid": 10, "name": "bash", "argv": ["-bash"]}, {"pid": 11, "name": "bash", "argv": ["bash"]}]}
        runs = self.reboot_with(
            [self.pane("H1"), tabbed("", "w1:p3", "w1:t2"), tabbed("", "w1:p4", "w1:t3", agent="claude"),
             tabbed("", "w1:p5", "w1:t4"), tabbed("", "w1:p6", "w1:t5")],
            {"saved_at": time.time(), "panes": [
                {"pane_id": "w1:p3", "tab_id": "w1:t2", "session_id": "S_VIM"},
                {"pane_id": "w1:p4", "tab_id": "w1:t3", "session_id": "S_CLAUDE"},
                {"pane_id": "w1:p5", "tab_id": "w1:t4", "session_id": "S_TWO"},
                {"pane_id": "w1:p6", "tab_id": "w1:t5", "session_id": "S_OK"}]},
            process_by_pane={"w1:p1": dict(SHELL, foreground_processes=[{"pid": 10, "name": "zsh",
                                                                         "argv": ["-zsh"]}]),
                             "w1:p3": vim, "w1:p4": SHELL, "w1:p5": two, "w1:p6": SHELL})
        # Herdr refuses p3 (vim), p4 (claude) and p5 (two jobs); each is skipped, never typed into.
        self.assertEqual(runs, [start("hmw-w1-p3", "w1:p3", "chat", "--resume", "S_VIM"),
                                start("hmw-w1-p4", "w1:p4", "chat", "--resume", "S_CLAUDE"),
                                start("hmw-w1-p5", "w1:p5", "chat", "--resume", "S_TWO"),
                                start("hmw-w1-p6", "w1:p6", "chat", "--resume", "S_OK"),
                                start("h1", "w1:p1", "chat", "--source", "pane:H1")])
        self.assertEqual(self.result.stderr.count("Herdr could not start Hermes there"), 3, self.result.stderr)
        self.assertEqual(self.state()["process_by_pane"]["w1:p3"]["foreground_processes"][0]["argv"],
                         ["vim", "notes"])

    def test_pane_memory_f2_fallback_duplicate_of_mapped_resumes_once(self):
        (self.bin / "hermes-pane").write_text(
            '#!/bin/sh\n[ "$1" = --print-resume-id ] || exit 0\n'
            'echo "$2" >> "$HOME/lookups"\n'
            'case "$2" in H1) echo S_DUP ;; H2) echo S_H2 ;; esac\n')
        runs = self.reboot_with(
            [self.pane("H1"), self.pane("H2", "w1:p2"), dict(self.pane("", "w1:p3"), tab_id="w1:t2")],
            {"saved_at": time.time(), "panes": [{"pane_id": "w1:p3", "tab_id": "w1:t2", "session_id": "S_DUP"}]},
            process_by_pane={})
        # Mapped first; H1's fallback duplicates it -> fresh; H2's id is pinned and passed.
        self.assertEqual(runs, [start("hmw-w1-p3", "w1:p3", "chat", "--resume", "S_DUP"),
                                start("h1", "w1:p1", "chat", "--source", "pane:H1"),
                                start("h2", "w1:p2", "chat", "--source", "pane:H2", "--resume", "S_H2")])
        lookups = (self.home / "lookups").read_text().split()
        self.assertEqual(sorted(lookups), ["H1", "H2"])   # one lookup per fallback, none at launch

    def test_pane_memory_r2_live_pane_session_is_reserved(self):
        # r2 F2 repro: live p3 holds S_DUP (snapshot AND live lease); H1's fallback names S_DUP.
        (self.bin / "hermes-pane").write_text(
            '#!/bin/sh\n[ "$1" = --print-resume-id ] || exit 0\n'
            'case "$2" in H1) echo S_DUP ;; H2) echo S_LEASE ;; esac\n')
        runtime = self.home / ".hermes/runtime"
        runtime.mkdir(parents=True)
        (runtime / "active_sessions.json").write_text(json.dumps({"entries": [
            dict(session_id="S_LEASE", surface="cli", pid=os.getpid(),
                 process_start_time=self.own_start_time())]}))
        (self.bin / "ps").write_text("#!/bin/sh\necho '%d 700'\necho '700 1'\n" % os.getpid())
        (self.bin / "ps").chmod(0o755)
        live = {"shell_pid": 699, "foreground_process_group_id": 700,
                "foreground_processes": [{"pid": 700, "name": "hermes", "argv": ["hermes"]}]}
        runs = self.reboot_with(
            [self.pane("H1"), self.pane("H2", "w1:p2"),
             dict(self.pane("", "w1:p3", agent="hermes"), tab_id="w1:t2"),
             dict(self.pane("", "w1:p4", agent="hermes"), tab_id="w1:t3")],
            {"saved_at": time.time(), "panes": [{"pane_id": "w1:p3", "tab_id": "w1:t2", "session_id": "S_DUP"}]},
            process_by_pane={"w1:p4": live})
        # p3/p4 are live and untouched; S_DUP (live snapshot id) and S_LEASE (live lease) are reserved.
        self.assertEqual(runs, [start("h1", "w1:p1", "chat", "--source", "pane:H1"),
                                start("h2", "w1:p2", "chat", "--source", "pane:H2")])

    def test_pane_memory_r3_uncertain_live_map_starts_labelled_fresh(self):
        # r3 P1 repro: live p4 runs a foreground Hermes holding S_LIVE, H1's fallback names
        # S_LIVE. If the live map cannot be built reliably, H1 must start fresh (never --resume).
        (self.bin / "hermes-pane").write_text(
            '#!/bin/sh\n[ "$1" = --print-resume-id ] || exit 0\n[ "$2" = H1 ] && echo S_LIVE\nexit 0\n')
        (self.bin / "ps").write_text("#!/bin/sh\necho '%d 700'\necho '700 1'\n" % os.getpid())
        (self.bin / "ps").chmod(0o755)
        live = {"shell_pid": 699, "foreground_process_group_id": 700,
                "foreground_processes": [{"pid": 700, "name": "hermes", "argv": ["hermes"]}]}
        runtime = self.home / ".hermes/runtime"
        runtime.mkdir(parents=True, exist_ok=True)
        good = dict(session_id="S_LIVE", surface="cli", pid=os.getpid(),
                    process_start_time=self.own_start_time())
        for name, leases in [("unreadable", "{not json"),
                             ("missing", None),
                             ("stale_start", json.dumps({"entries": [dict(good, process_start_time=1.0)]})),
                             ("ambiguous", json.dumps({"entries": [good, dict(good, session_id="S_OTHER")]}))]:
            with self.subTest(name):
                lease_file = runtime / "active_sessions.json"
                if leases is None:
                    lease_file.unlink(missing_ok=True)
                else:
                    lease_file.write_text(leases)
                if self.log.exists():
                    self.log.unlink()
                runs = self.reboot_with(
                    [self.pane("H1"), dict(self.pane("", "w1:p4", agent="hermes"), tab_id="w1:t3")],
                    {"saved_at": time.time(), "panes": []}, process_by_pane={"w1:p4": live})
                self.assertEqual(runs, [start("h1", "w1:p1", "chat", "--source", "pane:H1")])

    @staticmethod
    def own_start_time():
        stat = Path("/proc/%d/stat" % os.getpid()).read_bytes()
        ticks = float(stat[stat.rfind(b")") + 2:].split()[19])
        btime = next(float(l.split()[1]) for l in Path("/proc/stat").read_text().splitlines()
                     if l.startswith("btime"))
        return ticks / os.sysconf("SC_CLK_TCK") + btime

    def test_hermes_pane_print_resume_id_fails_closed_on_lookup_error(self):
        venv = self.home / "proj/venv/bin"
        venv.mkdir(parents=True)
        (venv / "hermes").write_text("#!/bin/sh\nexit 0\n")
        (venv / "hermes").chmod(0o755)
        (venv / "python3").symlink_to(shutil.which("python3"))
        state = self.home / "proj/hermes_state.py"
        env = dict(os.environ, HOME=str(self.home), PATH=str(venv) + os.pathsep + os.environ["PATH"])
        for name, body, rc, out in [
                ("db error", "raise RuntimeError('locked')", 1, ""),
                ("no session", "return []", 0, ""),
                ("found", "return [{'id': 'S_FOUND'}]", 0, "S_FOUND")]:
            with self.subTest(name):
                state.write_text("class SessionDB:\n    def search_sessions(self, source, limit):\n"
                                 "        assert source == 'pane:H1'\n        " + body + "\n")
                result = subprocess.run(["bash", str(ROOT / "scripts/hermes-pane"), "--print-resume-id", "H1"],
                                        env=env, capture_output=True, text=True, timeout=25)
                self.assertEqual((result.returncode, result.stdout.strip()), (rc, out), result.stderr)
        state.write_text("raise ImportError('broken store')\n")
        result = subprocess.run(["bash", str(ROOT / "scripts/hermes-pane"), "--print-resume-id", "H1"],
                                env=env, capture_output=True, text=True, timeout=25)
        self.assertNotEqual(result.returncode, 0)

    def test_pane_memory_r2_lookup_error_starts_fresh(self):
        (self.bin / "hermes-pane").write_text(
            '#!/bin/sh\n[ "$1" = --print-resume-id ] || exit 0\necho S_PARTIAL\nexit 1\n')
        runs = self.reboot_with([self.pane("H1")], {"saved_at": time.time(), "panes": []}, process_by_pane={})
        self.assertEqual(runs, [start("h1", "w1:p1", "chat", "--source", "pane:H1")])

    def test_pane_memory_f3_stale_start_and_background_hermes_not_recorded(self):
        bg_shell = {"shell_pid": 40, "foreground_process_group_id": 40,
                    "foreground_processes": [{"pid": 40, "name": "bash", "argv": ["bash"]}]}
        vim = {"shell_pid": 10, "foreground_process_group_id": 300,
               "foreground_processes": [{"pid": 300, "name": "vim", "argv": ["vim"]}]}
        self.write(panes=[self.pane("H1"), self.pane("H2", "w1:p2"), self.pane("H3", "w1:p3")],
                   process_by_pane={"w1:p1": self.fg(100), "w1:p2": bg_shell, "w1:p3": vim})
        tree = {100: 10, 400: 40, 300: 10}
        leases = [dict(session_id="STALE", surface="cli", pid=100, process_start_time=1),  # recycled pid
                  dict(session_id="S_BG", surface="cli", pid=400),   # background Hermes under the shell
                  dict(session_id="S_VIM", surface="cli", pid=300)]  # foreground is not Hermes
        result = self.run_snapshot(leases, tree)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.snapshot_path().read_text())["panes"], [])

    def test_pane_memory_f4_bad_snapshots_resume_nothing(self):
        rec = lambda pid, sid: {"pane_id": pid, "tab_id": "w1:t2", "session_id": sid}
        for name, snap in [
                ("duplicate", {"saved_at": time.time(), "panes": [rec("w1:p3", "FIRST"), rec("w1:p3", "SECOND")]}),
                ("partial", {"saved_at": time.time(), "panes": [rec("w1:p3", "FIRST"), rec("w1:p4", 123)]}),
                ("old", {"saved_at": time.time() - 15 * 86400, "panes": [rec("w1:p3", "FIRST")]})]:
            with self.subTest(name):
                if self.log.exists():
                    self.log.unlink()
                runs = self.reboot_with([self.pane("H1"), dict(self.pane("", "w1:p3"), tab_id="w1:t2"),
                                         dict(self.pane("", "w1:p4"), tab_id="w1:t2")], snap, process_by_pane={})
                self.assertEqual(runs, [start("h1", "w1:p1", "chat", "--source", "pane:H1")])

    def attach(self):
        env = dict(os.environ, HOME=str(self.home), PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                   HMW_BACKEND="herdr", HMW_REMOTE="1", HMW_VERIFY="0", HERDR_SESSION="review",
                   HMW_HERDR_READY_TIMEOUT="3", HMW_RESTORE_LOCK_WAIT="2", HMW_SNAPSHOT_INTERVAL="37",
                   HERDR_082_STATE=str(self.path), HERDR_082_LOG=str(self.log))
        return subprocess.run(["bash", str(CORE), "1"], env=env, capture_output=True, text=True, timeout=25)

    def test_pane_memory_f5_stale_pidfile_starts_one_loop(self):
        # Real 37s sleep for the loop only (the fake sleep returns at once).
        (self.bin / "sleep").write_text('#!/bin/sh\n[ "$1" = 37 ] && exec /bin/sleep 37\nexit 0\n')
        self.write(panes=[self.pane("H1", agent="hermes")])
        pidfile = self.home / ".hermes/hmw/review.snapshot-loop.pid"
        pidfile.parent.mkdir(parents=True)
        # Unrelated live pid (this test) with its true start time: no loop marker.
        stat = Path("/proc/%d/stat" % os.getpid()).read_bytes()
        ticks = float(stat[stat.rfind(b")") + 2:].split()[19])
        btime = next(float(l.split()[1]) for l in Path("/proc/stat").read_text().splitlines()
                     if l.startswith("btime"))
        pidfile.write_text("%d %r stale\n" % (os.getpid(), ticks / os.sysconf("SC_CLK_TCK") + btime))
        self.attach()
        first = pidfile.read_text().split()
        self.addCleanup(lambda: subprocess.run(["kill", first[0]], capture_output=True))
        self.assertNotEqual(int(first[0]), os.getpid())
        time.sleep(0.5)   # let the loop exec, so its marker is on its command line
        self.attach()
        self.assertEqual(pidfile.read_text().split(), first)
        loops = subprocess.run(["pgrep", "-f", "--", "hermes-workspace --hmw-snapshot-loop"],
                               capture_output=True, text=True).stdout.split()
        self.assertEqual(loops, [first[0]])

    def test_pane_memory_f6_snapshot_skipped_while_lock_held(self):
        self.write(panes=[self.pane("H1")], process_by_pane={"w1:p1": self.fg(100)})
        lock = self.home / ".hermes/logs/hmw-review.restore.lock"
        lock.mkdir(parents=True)
        result = self.run_snapshot([dict(session_id="S_A", surface="cli", pid=100)], {100: 10})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.snapshot_path().exists())
        self.assertTrue(lock.is_dir())
        lock.rmdir()
        self.assertEqual(self.run_snapshot([dict(session_id="S_A", surface="cli", pid=100)], {100: 10}).returncode, 0)
        self.assertEqual([p["session_id"] for p in json.loads(self.snapshot_path().read_text())["panes"]], ["S_A"])

    def test_reboot_verify_run_stops_server_it_started(self):
        self.restored(stopped=True, launched_state={"visible": COMPOSER, "process": LIVE})
        self.assertEqual(self.run_core(2).returncode, 0)
        self.assertIn(["server", "stop"], self.calls())
        self.assertTrue(self.state()["stopped"])

    def test_live_label_only_reused_and_exact_h1_focused(self):
        self.write(panes=[self.pane("H1"), self.pane("H2", "w1:p2")])
        result = self.run_core(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_launch()
        self.assertEqual([p["pane_id"] for p in self.state()["panes"] if p["focused"]], ["w1:p1"])

    def test_unlabeled_agents_are_ignored(self):
        for empty in (None, ""):
            with self.subTest(empty=empty):
                self.write(panes=[self.pane("H1", agent="hermes"), self.pane(empty, "w1:p2", agent="codex")],
                           agents=[{"name": empty, "agent": "codex", "pane_id": "w1:p2"}])
                result = self.run_core()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_no_launch()

    def test_live_python_entrypoint_is_ready(self):
        process = dict(LIVE, foreground_processes=[
            {"pid": 20, "name": "python3.12", "argv": ["/venv/bin/python3.12", "/venv/bin/hermes", "chat"]}])
        self.write(panes=[self.pane("H1")], process=process)
        result = self.run_core()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_launch()

    def test_new_label_only_agents_are_reused_on_repeat(self):
        self.write()
        result = self.run_core(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        first = self.state()["panes"]
        result = self.run_core(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state()["panes"], first)
        self.assertEqual([p["label"] for p in first], ["H1", "H2"])

    def test_named_agent_cannot_hide_conflicting_unlabeled_pane(self):
        self.write(panes=[self.pane(None, agent="codex")],
                   agents=[{"name": "H1", "agent": "hermes", "pane_id": "w1:p1"}])
        self.assert_failed(self.run_core())
        self.assert_no_launch()

    def test_one_pane_cannot_fill_two_slots(self):
        self.write(panes=[self.pane("H1", agent="hermes")],
                   agents=[{"name": "H2", "agent": "hermes", "pane_id": "w1:p1"}])
        self.assert_failed(self.run_core(2))
        self.assert_no_launch()

    def test_retained_semantic_identity_after_exit_is_not_ready(self):
        self.write(panes=[self.pane("H1", agent="hermes")], process=SHELL)
        self.assert_failed(self.run_core())
        self.assert_no_launch()

    def test_bare_labeled_shell_is_not_ready_or_duplicated(self):
        self.write(panes=[self.pane("H1")], process=SHELL, visible="$ ")
        self.assert_failed(self.run_core())
        self.assert_no_launch()

    def test_failed_launch_stays_failed_on_repeat(self):
        self.write(process=SHELL, visible="hermes: command not found\n$ ")
        self.assert_failed(self.run_core())
        first_panes = self.state()["panes"]
        self.assertEqual(len(first_panes), 1)
        self.assert_failed(self.run_core())
        self.assertEqual(self.state()["panes"], first_panes)

    def test_failed_pane_run_stays_failed_on_repeat(self):
        self.write(process=SHELL, visible="$ ", run_status=42)
        self.assert_failed(self.run_core())
        self.assert_failed(self.run_core())
        self.assertEqual(len(self.state()["panes"]), 1)

    def test_recent_history_after_exit_cannot_satisfy_readiness(self):
        self.write(panes=[self.pane("H1")], process=SHELL, visible=COMPOSER + "$ ", recent=COMPOSER)
        self.assert_failed(self.run_core())
        self.assert_no_launch()

    def test_process_title_alone_is_not_readiness(self):
        self.write(panes=[self.pane("H1")], process=LIVE, visible="loading...", recent=COMPOSER)
        self.assert_failed(self.run_core())
        self.assert_no_launch()

    def test_other_foreground_process_with_stale_composer_is_not_ready(self):
        process = dict(LIVE, foreground_processes=[{"pid": 20, "name": "vim", "argv": ["vim"]}])
        self.write(panes=[self.pane("H1")], process=process)
        self.assert_failed(self.run_core())
        self.assert_no_launch()

    def test_conflicting_pane_identity_wins_over_history(self):
        self.write(panes=[self.pane("H1", agent="codex")], recent=COMPOSER)
        self.assert_failed(self.run_core())
        self.assert_no_launch()

    def test_conflicting_agent_inventory_wins_over_pane_identity(self):
        self.write(panes=[self.pane("H1", agent="hermes")],
                   agents=[{"name": "H1", "agent": "codex", "pane_id": "w1:p1"}])
        self.assert_failed(self.run_core())
        self.assert_no_launch()

    def test_current_conflict_wins_over_inventory(self):
        self.write(panes=[self.pane("H1", agent="hermes")], get_override={"agent": "codex"})
        self.assert_failed(self.run_core())
        self.assert_no_launch()

    def test_focus_noop_fails_closed(self):
        self.write(panes=[self.pane("H1", agent="hermes"), self.pane("H2", "w1:p2", agent="hermes")], focus_noop=True)
        self.assert_failed(self.run_core())

    def test_rpc_error_fails_closed(self):
        self.write(panes=[self.pane("H1")], rpc_error=True)
        self.assert_failed(self.run_core())
        self.assert_no_launch()

    def test_invalid_identity_and_duplicate_label_fail_closed(self):
        for extra in ([self.pane("H1", "w1:p2")], [self.pane("H2", "w1:p2", agent=42)]):
            with self.subTest(extra=extra):
                self.write(panes=[self.pane("H1", agent="hermes")] + extra)
                self.assert_failed(self.run_core())
                self.assert_no_launch()

    def test_missing_or_failed_current_evidence_fails_closed(self):
        for override in ({"process": {}}, {"process_status": 1}, {"read_status": 1}, {"get_override": {"pane_id": "wrong"}}):
            with self.subTest(override=override):
                self.write(panes=[self.pane("H1")], **override)
                self.assert_failed(self.run_core())
                self.assert_no_launch()

    def with_argv(self, argv, **kw):
        return dict(LIVE, foreground_processes=[{"pid": 20, "argv": argv}], **kw)

    def test_update_with_stale_composer_is_not_chat(self):
        self.write(panes=[self.pane("H1")], process=self.with_argv(
            ["/venv/bin/python3", "/venv/bin/hermes", "update"]))
        self.assert_failed(self.run_core())
        self.assert_no_launch()

    def test_setup_with_retained_semantic_identity_is_not_chat(self):
        self.write(panes=[self.pane("H1", agent="hermes")], process=self.with_argv(["hermes", "setup"]))
        self.assert_failed(self.run_core())
        self.assert_no_launch()

    def test_non_chat_invocations_fail_closed(self):
        for argv in (["hermes", "--profile", "work", "update"],
                     ["python3", "-m", "hermes_cli.main", "setup"],
                     ["hermes", "logs", "-f"], ["hermes", "--help"],
                     ["hermes", "chat", "--help"], ["hermes", "chat", "--oneshot"],
                     ["hermes", "-z", "chat"], ["hermes", "chat", "-q", "hello"],
                     ["hermes", "--unknown", "chat"],
                     ["python3", "-c", "hermes", "chat"],
                     ["python3", "other.py", "hermes", "chat"]):
            with self.subTest(argv=argv):
                self.write(panes=[self.pane("H1", agent="hermes")], process=self.with_argv(argv))
                self.assert_failed(self.run_core())
                self.assert_no_launch()

    def test_bare_and_explicit_chat_launcher_forms_remain_ready(self):
        for argv in (["hermes"], ["python3", "/venv/bin/hermes"],
                     ["hermes", "--profile", "work", "--tui"],
                     ["hermes", "--resume", "setup"], ["hermes", "--continue"],
                     ["hermes", "--continue", "setup"],
                     ["hermes", "--model=update", "chat", "--source", "pane:H1"],
                     ["hermes", "chat", "--resume", "abc", "--no-restore-cwd"],
                     ["python3", "-m", "hermes_cli.main", "chat"]):
            with self.subTest(argv=argv):
                self.write(panes=[self.pane("H1")], process=self.with_argv(argv))
                result = self.run_core()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_no_launch()

    def test_python_flags_before_script_or_module_are_ready(self):
        for argv in (["python3", "-u", "/venv/bin/hermes", "chat"],
                     ["python3.12", "-I", "-W", "ignore", "-X", "utf8", "/venv/bin/hermes"],
                     ["python3", "-B", "-m", "hermes_cli.main", "chat"],
                     ["python3", "-uB", "-Wignore", "-Xutf8", "--", "/venv/bin/hermes"]):
            with self.subTest(argv=argv):
                self.write(panes=[self.pane("H1")], process=self.with_argv(argv))
                result = self.run_core()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_no_launch()

    def test_managed_store_launcher_is_ready(self):
        # Hermes 0.21+ `.hermes/bin/hermes` execs the store Python with -I -c.
        for argv in ([STORE_PY, "-I", "-c", launcher_script("hermes_cli.main"), "--resume", "20260925_215057_fe86d4"],
                     [STORE_PY, "-I", "-c", launcher_script("hermes_cli.main")],
                     [STORE_PY, "-Ic", launcher_script("hermes_cli.main"), "chat", "--source", "pane:H1"],
                     [STORE_PY, "-I", "-c", RUNTIME_COMMAND, "--tui"]):
            with self.subTest(argv=argv[1:2] + argv[3:]):
                self.write(panes=[self.pane("H1")], process=self.with_argv(argv))
                result = self.run_core()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_no_launch()

    def test_managed_launcher_lookalikes_fail_closed(self):
        for argv in ([STORE_PY, "-I", "-c", launcher_script("acp_adapter.entry")],
                     [STORE_PY, "-I", "-c", launcher_script("hermes_cli.main"), "--run-module", "http.server"],
                     [STORE_PY, "-I", "-c", launcher_script("hermes_cli.main"), "--print-runtime-command"],
                     [STORE_PY, "-I", "-c", launcher_script("hermes_cli.main"), "update"],
                     [STORE_PY, "-I", "-ic", launcher_script("hermes_cli.main")],
                     [STORE_PY, "-I", "-c", "from hermes_cli.main import main\nsys.exit(main())"],
                     [STORE_PY, "-I", "-c"]):
            with self.subTest(argv=argv[1:2] + argv[3:]):
                self.write(panes=[self.pane("H1", agent="hermes")], process=self.with_argv(argv))
                self.assert_failed(self.run_core())
                self.assert_no_launch()

    def test_exec_replaced_shell_pid_is_valid_chat(self):
        self.write(panes=[self.pane("H1")], process=self.with_argv(
            ["python3", "/venv/bin/hermes", "chat"], shell_pid=20))
        result = self.run_core()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_launch()

    def test_duplicate_unmanaged_pane_labels_do_not_reserve_slots(self):
        self.write(panes=[self.pane("H1"), self.pane("logs", "w1:p2", agent="codex"),
                          self.pane("logs", "w1:p3", agent="codex")])
        result = self.run_core()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_launch()

    def test_duplicate_unmanaged_agent_names_do_not_reserve_slots(self):
        self.write(panes=[self.pane("H1")], agents=[
            {"name": "logs", "pane_id": "w1:p2", "agent": "codex"},
            {"name": "logs", "pane_id": "w1:p3", "agent": "codex"}])
        result = self.run_core()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_launch()

    def test_name_only_legacy_aliases_cannot_fill_two_slots(self):
        self.write(panes=[self.pane(None, agent="hermes")],
                   agents=[{"name": "H1"}, {"name": "H2"}], agent_get={
                       name: {"name": name, "pane_id": "w1:p1", "agent": "hermes"}
                       for name in ("H1", "H2")})
        self.assert_failed(self.run_core(2))
        self.assert_no_launch()
        self.assertFalse(any(isinstance(c, list) and c[:2] == ["agent", "focus"] for c in self.calls()))

    def test_name_only_and_direct_aliases_cannot_fill_two_slots(self):
        self.write(panes=[self.pane(None, agent="hermes")],
                   agents=[{"name": "H1", "pane_id": "w1:p1"}, {"name": "H2"}],
                   agent_get={"H2": {"name": "H2", "pane_id": "w1:p1", "agent": "hermes"}})
        self.assert_failed(self.run_core(2))
        self.assert_no_launch()

    def test_distinct_name_only_legacy_targets_remain_supported(self):
        self.write(panes=[self.pane(None, agent="hermes"), self.pane(None, "w1:p2", agent="hermes")],
                   agents=[{"name": "H1"}, {"name": "H2"}], agent_get={
                       name: {"name": name, "pane_id": "w1:p" + name[1:], "agent": "hermes"}
                       for name in ("H1", "H2")})
        result = self.run_core(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_launch()

    def test_unnamed_labeled_and_legacy_named_agents_remain_supported(self):
        self.write(panes=[self.pane("H1", "w1:pB", agent="hermes"),
                          self.pane(None, "w1:p2", agent="hermes")],
                   agents=[{"agent": "hermes", "pane_id": "w1:pB"}, {"name": "H2"}],
                   agent_get={"H2": {"name": "H2", "pane_id": "w1:p2", "agent": "hermes"}})
        result = self.run_core(2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("inventory-end", result.stdout)
        self.assert_no_launch()
        calls = self.calls()
        self.assertEqual(calls.count(["agent", "get", "H2"]), 1)
        self.assertNotIn(["agent", "get", "H1"], calls)
        self.assertIn(["pane", "get", "w1:pB"], calls)
        self.assertIn(["pane", "get", "w1:p2"], calls)
        self.assertEqual([p["pane_id"] for p in self.state()["panes"] if p["focused"]], ["w1:pB"])

    def test_legacy_target_reconciles_all_inventory_agent_kinds(self):
        for name in ("logs", None, ""):
            with self.subTest(name=name):
                self.write(panes=[self.pane(None, agent="hermes")],
                           agents=[{"name": "H1"},
                                   {"name": name, "pane_id": "w1:p1", "agent": "codex"}],
                           agent_get={"H1": {"name": "H1", "pane_id": "w1:p1", "agent": "hermes"}})
                self.assert_failed(self.run_core())
                self.assert_no_launch()
                self.assertNotIn(["agent", "focus", "w1:p1"], self.calls())

    def test_legacy_target_reconciles_inventory_pane_kind(self):
        # A later pane-get cannot erase a conflicting inventory detection.
        self.write(panes=[self.pane(None, agent="codex")], agents=[{"name": "H1"}],
                   agent_get={"H1": {"name": "H1", "pane_id": "w1:p1", "agent": "hermes"}},
                   get_override={"agent": "hermes"})
        self.assert_failed(self.run_core())
        self.assert_no_launch()
        self.assertNotIn(["agent", "focus", "w1:p1"], self.calls())

    def test_second_legacy_target_reconciles_inventory_before_focus(self):
        self.write(panes=[self.pane("H1"), self.pane(None, "w1:p2", agent="hermes")],
                   agents=[{"name": "H2"}, {"agent": "codex", "pane_id": "w1:p2"}],
                   agent_get={"H2": {"name": "H2", "pane_id": "w1:p2", "agent": "hermes"}})
        self.assert_failed(self.run_core(2))
        self.assert_no_launch()
        self.assertNotIn(["agent", "focus", "w1:p1"], self.calls())

    def test_legacy_target_tolerates_compatible_and_unmanaged_duplicates(self):
        self.write(panes=[self.pane(None), self.pane("logs", "w1:p2", agent="codex"),
                          self.pane("logs", "w1:p3", agent="codex")],
                   agents=[{"name": "H1"}, {"name": "observer", "pane_id": "w1:p1", "agent": None},
                           {"pane_id": "w1:p1", "agent": "hermes"},
                           {"name": "logs", "pane_id": "w1:p2", "agent": "codex"},
                           {"name": "logs", "pane_id": "w1:p3", "agent": "codex"}],
                   agent_get={"H1": {"name": "H1", "pane_id": "w1:p1", "agent": "hermes"}})
        result = self.run_core()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_launch()
        self.assertEqual(self.calls().count(["agent", "get", "H1"]), 1)
        self.assertEqual([p["pane_id"] for p in self.state()["panes"] if p["focused"]], ["w1:p1"])

    def test_python_inspect_after_exit_rejects_stale_composer(self):
        self.write(panes=[self.pane("H1")], visible=COMPOSER + ">>> ",
                   process=self.with_argv(["python3", "-i", "/venv/bin/hermes", "chat"]))
        self.assert_failed(self.run_core())
        self.assert_no_launch()

    def test_python_inspect_after_exit_rejects_retained_identity(self):
        self.write(panes=[self.pane("H1", agent="hermes")], visible=">>> ",
                   process=self.with_argv(["python3", "-i", "/venv/bin/hermes", "chat"], shell_pid=20))
        self.assert_failed(self.run_core())
        self.assert_no_launch()

    def test_python_grouped_inspect_flags_are_not_live_hermes(self):
        for flags in (["-ui"], ["-iuB"], ["-Bi", "-m", "hermes_cli.main"],
                      ["-imhermes_cli.main"], ["-uim", "hermes_cli.main"]):
            with self.subTest(flags=flags):
                script = [] if any("m" in flag for flag in flags) else ["/venv/bin/hermes"]
                self.write(panes=[self.pane("H1", agent="hermes")], visible=COMPOSER + ">>> ",
                           process=self.with_argv(["python3"] + flags + script + ["chat"]))
                self.assert_failed(self.run_core())
                self.assert_no_launch()

    def test_grouped_chat_switches_match_separated_forms(self):
        for grouped, separated in ((["-wv"], ["-w", "-v"]),
                                   (["-vw"], ["-v", "-w"]),
                                   (["-vv"], ["-v", "-v"]),
                                   (["-vwcfoo"], ["-v", "-w", "-c", "foo"])):
            for args in (grouped, separated):
                with self.subTest(grouped=grouped, args=args):
                    self.write(panes=[self.pane("H1")],
                               process=self.with_argv(["hermes", "chat"] + args))
                    result = self.run_core()
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("inventory-end", result.stdout)
                    self.assert_no_launch()
                    self.assertEqual([p["pane_id"] for p in self.state()["panes"] if p["focused"]], ["w1:p1"])

    def test_grouped_chat_switches_preserve_operand_ownership(self):
        # Once a value option is reached, its suffix is data, even -v/-w/-q/-z.
        for option in ("c", "m", "r", "t", "s"):
            for args in (["-vw" + option + "wzq"], ["-v", "-w", "-" + option, "wzq"],
                         ["-wv" + option, "setup"], ["-w", "-v", "-" + option, "setup"]):
                with self.subTest(option=option, args=args):
                    self.write(panes=[self.pane("H1")],
                               process=self.with_argv(["hermes", "chat"] + args))
                    result = self.run_core()
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assert_no_launch()

    def test_grouped_chat_switches_reject_unsafe_and_malformed_forms(self):
        for args in (["-vwh"], ["-vwV"], ["-vwzhello"], ["-vwqhello"],
                     ["-wv", "--help"], ["-vw", "--version"], ["-vw", "--oneshot"],
                     ["-v="], ["-vw=1"], ["-vw-tui"], ["-vwunknown"], ["-vwpwork"],
                     ["-vwm"], ["-vwm", "--tui"], ["-vwm="], ["-vwc="],
                     ["-vwcfoo", "extra"], ["-wv", "update"], ["-vw", "setup"]):
            with self.subTest(args=args):
                self.write(panes=[self.pane("H1", agent="hermes")],
                           process=self.with_argv(["hermes", "chat"] + args))
                self.assert_failed(self.run_core())
                self.assert_no_launch()

    def test_grouped_chat_switches_remain_chat_only(self):
        for args in (["-wv"], ["-vw"], ["-vv"], ["-vwcfoo"],
                     ["-wv", "chat"], ["-vw", "chat"], ["-vv", "chat"], ["-vwcfoo", "chat"],
                     ["update", "-wv"], ["setup", "-vw"], ["logs", "-vv"]):
            with self.subTest(args=args):
                self.write(panes=[self.pane("H1", agent="hermes")],
                           process=self.with_argv(["hermes"] + args))
                self.assert_failed(self.run_core())
                self.assert_no_launch()

    def test_grouped_top_level_short_options_are_ready(self):
        # Exact argparse-valid equivalents: -w is a switch, -c owns its suffix.
        for args in (["-wctest"], ["-w", "-ctest"], ["-wctest", "chat"],
                     ["-wc"], ["-wc", "test"], ["-wc=test"], ["-wwctest"],
                     ["-ww"], ["-wmfoo"], ["-wm", "foo", "chat"],
                     ["-wrtest"], ["-wtweb"], ["-wsresearch"],
                     ["-wmwzhello"], ["-wczhello"], ["chat", "-wctest"]):
            with self.subTest(args=args):
                self.write(panes=[self.pane("H1")], process=self.with_argv(["hermes"] + args))
                result = self.run_core()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("inventory-end", result.stdout)
                self.assert_no_launch()
                self.assertEqual([p["pane_id"] for p in self.state()["panes"] if p["focused"]], ["w1:p1"])

    def test_grouped_top_level_short_options_reject_malformed_forms(self):
        for args in (["-w=1"], ["-w--tui"], ["-w-tui"], ["-wunknown"],
                     ["-wpwork"], ["-wvc"], ["-wm"], ["-wm", "--tui"],
                     ["-wm="], ["-wc="], ["-wctest", "chat", "extra"]):
            with self.subTest(args=args):
                self.write(panes=[self.pane("H1", agent="hermes")],
                           process=self.with_argv(["hermes"] + args))
                self.assert_failed(self.run_core())
                self.assert_no_launch()

    def test_grouped_top_level_short_options_reject_unsafe_and_non_chat(self):
        for args in (["-wctest", "update"], ["-wctest", "setup"],
                     ["-wmfoo", "logs", "-f"], ["-wzhello"], ["-wwzhello"],
                     ["-wqhello"], ["-wh"], ["-wV"], ["-wctest", "--help"],
                     ["-wctest", "chat", "-qhello"]):
            with self.subTest(args=args):
                self.write(panes=[self.pane("H1", agent="hermes")],
                           process=self.with_argv(["hermes"] + args))
                self.assert_failed(self.run_core())
                self.assert_no_launch()

    def test_grouped_top_level_short_options_preserve_python_inspect_guard(self):
        for prefix in (["python3", "-i", "/venv/bin/hermes"],
                       ["python3", "-uimhermes_cli.main"]):
            for kind in (None, "hermes"):
                with self.subTest(prefix=prefix, kind=kind):
                    self.write(panes=[self.pane("H1", agent=kind)], visible=COMPOSER + ">>> ",
                               process=self.with_argv(prefix + ["-wctest"], shell_pid=20))
                    self.assert_failed(self.run_core())
                    self.assert_no_launch()

    def test_grouped_top_level_short_options_preserve_identity_guards(self):
        for override in ({"agent": "codex"}, {"label": "H2"}, {"label": None}):
            with self.subTest(override=override):
                self.write(panes=[self.pane("H1", agent="hermes")], get_override=override,
                           process=self.with_argv(["hermes", "-wctest"]))
                self.assert_failed(self.run_core())
                self.assert_no_launch()

    def test_attached_hermes_model_option_is_ready(self):
        self.write(panes=[self.pane("H1")], process=self.with_argv(["hermes", "chat", "-mfoo"]))
        result = self.run_core()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_launch()

    def test_attached_python_module_is_ready(self):
        self.write(panes=[self.pane("H1")], process=self.with_argv(["python3", "-mhermes_cli.main", "chat"]))
        result = self.run_core()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_launch()

    def test_grouped_python_module_is_ready(self):
        self.write(panes=[self.pane("H1")], process=self.with_argv(["python3", "-um", "hermes_cli.main", "chat"]))
        result = self.run_core()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_launch()

    def test_attached_short_values_and_python_module_controls(self):
        for argv in (["hermes", "chat", "-m=foo"], ["hermes", "-pwork", "chat", "-rsetup"],
                     ["hermes", "chat", "-tweb", "-sresearch", "-csetup"],
                     ["hermes", "-mupdate", "chat"],
                     ["python3", "-uBmhermes_cli.main", "chat", "-mfoo"],
                     ["python3", "-Wignore", "-Xutf8", "-mhermes_cli.main", "chat"],
                     ["python3", "-uWignore", "-Bmhermes_cli.main", "chat"],
                     ["python3", "-uX", "utf8", "-mhermes_cli.main", "chat"],
                     ["python3", "--check-hash-based-pycs", "always", "-mhermes_cli.main", "chat"]):
            with self.subTest(argv=argv):
                self.write(panes=[self.pane("H1")], process=self.with_argv(argv, shell_pid=20))
                result = self.run_core()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_no_launch()

    def test_attached_options_do_not_permit_non_chat(self):
        for argv in (["hermes", "-mfoo", "update"], ["hermes", "-pwork", "setup"],
                     ["hermes", "chat", "-qhello"], ["hermes", "-zhello"],
                     ["python3", "-mhermes_cli.main", "update"],
                     ["python3", "-um", "hermes_cli.main", "setup"],
                     ["python3", "-umhermes_cli.main", "chat", "--help"]):
            with self.subTest(argv=argv):
                self.write(panes=[self.pane("H1", agent="hermes")], process=self.with_argv(argv))
                self.assert_failed(self.run_core())
                self.assert_no_launch()

    def test_malformed_attached_or_grouped_options_fail_closed(self):
        for argv in (["hermes", "chat", "-m"], ["hermes", "chat", "-m="],
                     ["hermes", "chat", "-mfoo", "extra"], ["hermes", "chat", "-unknown"],
                     ["python3", "-m"], ["python3", "-um"],
                     ["python3", "-m=hermes_cli.main", "chat"],
                     ["python3", "-umhermes_cli.main.extra", "chat"],
                     ["python3", "-Zmhermes_cli.main", "chat"],
                     ["python3", "-uc", "hermes_cli.main", "chat"],
                     ["python3", "-uW"], ["python3", "-uX"],
                     ["python3", "--", "-mhermes_cli.main", "chat"],
                     ["python3", "--check-hash-based-pycs", "bogus", "-mhermes_cli.main", "chat"]):
            with self.subTest(argv=argv):
                self.write(panes=[self.pane("H1", agent="hermes")], process=self.with_argv(argv))
                self.assert_failed(self.run_core())
                self.assert_no_launch()

    def test_current_label_must_preserve_inventory_slot(self):
        for label in ("H2", "logs", None, ""):
            with self.subTest(label=label):
                self.write(panes=[self.pane("H1", agent="hermes")], get_override={"label": label})
                self.assert_failed(self.run_core())
                self.assert_no_launch()

    def test_legacy_name_cannot_override_current_different_label(self):
        self.write(panes=[self.pane(None, agent="hermes")], agents=[{"name": "H1"}],
                   agent_get={"H1": {"name": "H1", "pane_id": "w1:p1", "agent": "hermes"}},
                   get_override={"label": "H2"})
        self.assert_failed(self.run_core())
        self.assert_no_launch()

    def test_unnamed_agent_needs_pane_and_kind_identity(self):
        for agent in ({}, {"name": ""}, {"pane_id": "w1:p2"}, {"agent": "codex"}):
            with self.subTest(agent=agent):
                self.write(panes=[self.pane("H1")], agents=[agent])
                self.assert_failed(self.run_core())
                self.assert_no_launch()

    def test_focus_rpc_requires_typed_matching_focused_pane(self):
        for result in (None, 7, "ok", [], {}, {"type": "pane_info", "pane": None},
                       {"type": "pane_info", "pane": {"pane_id": "other", "focused": True}},
                       {"type": "pane_info", "pane": {"pane_id": "w1:p1", "focused": False}},
                       {"type": "other", "pane": {"pane_id": "w1:p1", "focused": True}}):
            with self.subTest(result=result):
                self.write(panes=[self.pane("H1")], rpc_result=result)
                self.assert_failed(self.run_core())
                self.assert_no_launch()


if __name__ == "__main__":
    unittest.main()
