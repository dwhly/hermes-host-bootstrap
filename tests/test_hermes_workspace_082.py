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
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "scripts/hermes-workspace"
COMPOSER = "Hermes Agent v0.16\nType your message or /help for commands.\n❯ Ask me anything…\n"
LIVE = {"shell_pid": 10, "foreground_process_group_id": 20,
        "foreground_processes": [{"pid": 20, "name": "hermes", "argv": ["hermes"]}]}
SHELL = {"shell_pid": 10, "foreground_process_group_id": 10,
         "foreground_processes": [{"pid": 10, "name": "bash", "argv": ["bash"]}]}


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
                   HERDR_082_STATE=str(self.path), HERDR_082_LOG=str(self.log))
        return subprocess.run(["bash", str(CORE), str(count)], env=env, capture_output=True, text=True, timeout=25)

    def assert_failed(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("inventory-end", result.stdout)

    def assert_no_launch(self):
        for call in self.calls():
            if isinstance(call, list):
                self.assertNotIn(call[:2], [["pane", "split"], ["workspace", "create"], ["pane", "run"]])

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
