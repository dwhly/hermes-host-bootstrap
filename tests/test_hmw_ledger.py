"""Tests for scripts/hmw-ledger: the durable record of every herdr tab.

A fake herdr (JSON state file) plus fake pgrep/ps/journalctl on PATH and a
throwaway state.db make every loss path deterministic: closed tab, Hermes
exited in a surviving tab, memguard kill, server restart (auto-restore after a
grace period), the unseen-work marker, and the safety rules (never resume a
session that is already running, never close a tab the ledger did not create).
"""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
LEDGER = REPO / "scripts" / "hmw-ledger"
T0 = 1_800_000_000.0

FAKE_HERDR = r'''#!/usr/bin/env python3
import json, os, sys
path = os.environ["FAKE_STATE"]
st = json.load(open(path))
a = sys.argv[1:]
assert a[:2] == ["--session", "ws"], a
a = a[2:]
st.setdefault("calls", []).append(a)
def out(result):
    json.dump(st, open(path, "w"))
    print(json.dumps({"result": result}))
    sys.exit(0)
def fail(msg):
    json.dump(st, open(path, "w"))
    print(msg, file=sys.stderr)
    sys.exit(1)
cmd = a[:2]
if cmd == ["pane", "list"]:
    out({"panes": st["panes"]})
if cmd == ["tab", "list"]:
    out({"tabs": st["tabs"]})
if cmd == ["workspace", "list"]:
    out({"workspaces": st["workspaces"]})
if cmd == ["tab", "create"]:
    ws = a[a.index("--workspace") + 1]
    n = st["next"]; st["next"] = n + 1
    tid, pid = "%s:t%d" % (ws, n), "%s:p%d" % (ws, n)
    st["tabs"].append({"tab_id": tid, "workspace_id": ws, "label": str(n), "agent_status": None, "focused": False})
    st["panes"].append({"pane_id": pid, "tab_id": tid, "workspace_id": ws, "label": None, "agent": None,
                        "agent_session": None, "terminal_title_stripped": None, "cwd": a[a.index("--cwd") + 1]})
    out({"tab": {"tab_id": tid}, "root_pane": {"pane_id": pid}})
if cmd == ["tab", "rename"]:
    next(t for t in st["tabs"] if t["tab_id"] == a[2])["label"] = a[3]
    out({})
if cmd == ["pane", "rename"]:
    next(p for p in st["panes"] if p["pane_id"] == a[2])["label"] = a[3]
    out({})
if cmd == ["tab", "close"]:
    st["tabs"] = [t for t in st["tabs"] if t["tab_id"] != a[2]]
    st["panes"] = [p for p in st["panes"] if p["tab_id"] != a[2]]
    out({})
if cmd == ["agent", "start"]:
    if st.get("fail_agent_start"):
        fail("pane_not_ready")
    pane = a[a.index("--pane") + 1]
    sid = a[a.index("--resume") + 1]
    p = next(p for p in st["panes"] if p["pane_id"] == pane)
    p.update(agent="hermes", agent_session={"value": sid}, terminal_title_stripped="\u2713 " + st["titles"][sid])
    out({})
fail("fake herdr: unknown command %r" % (a,))
'''

FAKE_PGREP = '''#!/bin/sh
python3 -c 'import json,os; p=json.load(open(os.environ["FAKE_STATE"])).get("server_pid"); print(p) if p else exit(1)'
'''

FAKE_PS = r'''#!/usr/bin/env python3
import json, os, sys
st = json.load(open(os.environ["FAKE_STATE"]))
if "-axo" in sys.argv:
    print("\n".join(st.get("procs", [])))
elif "lstart=" in sys.argv:
    print(st["server_lstart"])
'''

FAKE_JOURNALCTL = r'''#!/usr/bin/env python3
import json, os
print("\n".join(json.load(open(os.environ["FAKE_STATE"])).get("journal", [])))
'''


def lstart(epoch):
    import time
    return time.strftime("%a %b %d %H:%M:%S %Y", time.localtime(epoch))


class LedgerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="hmw-ledger-test."))
        self.addCleanup(subprocess.run, ["rm", "-rf", str(self.tmp)])
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        for name, body in (("herdr", FAKE_HERDR), ("pgrep", FAKE_PGREP), ("ps", FAKE_PS),
                           ("journalctl", FAKE_JOURNALCTL)):
            f = self.bin / name
            f.write_text(body)
            f.chmod(0o755)
        self.hh = self.tmp / "home" / ".hermes"
        self.hh.mkdir(parents=True)
        self.state = self.tmp / "herdr.json"
        self.db = sqlite3.connect(str(self.hh / "state.db"))
        self.db.execute("create table sessions (id text, source text, title text, end_reason text, "
                        "parent_session_id text, started_at real, last_activity_at real)")
        self.titles = {}
        self.session("20261101_000000_aaaaaa", "Alpha work")
        self.session("20261101_000000_bbbbbb", "Beta research")
        self.st = {"next": 10, "server_pid": "99999901", "server_lstart": lstart(T0), "procs": [],
                   "workspaces": [{"workspace_id": "w1", "label": "ws"}], "tabs": [], "panes": []}
        self.tab("w1:t1", "ALPHA", "20261101_000000_aaaaaa")
        self.tab("w1:t2", "BETA", "20261101_000000_bbbbbb")
        self.tab("w1:t3", "NOTES", None)
        self.save()

    # ── fixture helpers ──
    def session(self, sid, title, end=None, parent=None, started=T0 - 3600):
        self.db.execute("insert into sessions values (?,?,?,?,?,?,?)",
                        (sid, "tui", title, end, parent, started, started))
        self.db.commit()
        self.titles[sid] = title

    def tab(self, tid, label, sid, status="idle", focused=False, hint=None):
        n = tid.split(":t")[1]
        self.st["tabs"].append({"tab_id": tid, "workspace_id": "w1", "label": label,
                                "agent_status": status if sid else None, "focused": focused})
        self.st["panes"].append({
            "pane_id": "w1:p" + n, "tab_id": tid, "workspace_id": "w1", "label": None,
            "agent": "hermes" if sid else None, "cwd": "/srv/" + label.lower(),
            "agent_session": {"value": hint or sid} if sid else None,
            "terminal_title_stripped": ("\u2713 " + self.titles[sid]) if sid else None})

    def save(self):
        self.st["titles"] = self.titles
        self.state.write_text(json.dumps(self.st))

    def load(self):
        self.st = json.loads(self.state.read_text())
        return self.st

    def run_ledger(self, *args, now=T0 + 60):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"], HOME=str(self.tmp / "home"),
                   HERMES_HOME=str(self.hh), HERDR_SESSION="ws", FAKE_STATE=str(self.state),
                   HMW_LEDGER_NOW=repr(float(now)))
        env.pop("HMW_STATE_DIR", None)
        r = subprocess.run([sys.executable, str(LEDGER), *args], env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout

    def ledger(self):
        return json.loads((self.hh / "hmw" / "ws.ledger.json").read_text())

    def entry(self, label):
        hits = [e for e in self.ledger()["entries"] if e["tab_label"] == label]
        self.assertEqual(len(hits), 1, [e["tab_label"] for e in self.ledger()["entries"]])
        return hits[0]

    def calls(self, *prefix):
        return [c for c in self.load().get("calls", []) if c[:len(prefix)] == list(prefix)]

    def close_tab(self, tid):
        self.load()
        self.st["tabs"] = [t for t in self.st["tabs"] if t["tab_id"] != tid]
        self.st["panes"] = [p for p in self.st["panes"] if p["tab_id"] != tid]
        self.save()

    # ── recording ──
    def test_records_every_tab_with_verified_conversation(self):
        self.run_ledger("update")
        self.assertEqual(sorted(e["tab_label"] for e in self.ledger()["entries"]), ["ALPHA", "BETA", "NOTES"])
        a = self.entry("ALPHA")["panes"][0]
        self.assertEqual((a["session_id"], a["sid_source"]), ("20261101_000000_aaaaaa", "herdr-verified"))
        self.assertEqual(self.entry("NOTES")["panes"][0]["session_id"], None)
        self.assertEqual({e["state"] for e in self.ledger()["entries"]}, {"live"})

    def test_stale_herdr_hint_is_replaced_by_title_match(self):
        self.load()
        p = next(p for p in self.st["panes"] if p["tab_id"] == "w1:t1")
        p["agent_session"] = {"value": "20261101_000000_bbbbbb"}   # herdr points at another conversation
        self.save()
        self.run_ledger("update")
        a = self.entry("ALPHA")["panes"][0]
        self.assertEqual((a["session_id"], a["sid_source"]), ("20261101_000000_aaaaaa", "title-match"))

    def test_chains_follow_compression_only(self):
        self.db.execute("update sessions set end_reason='compression' where id='20261101_000000_aaaaaa'")
        self.session("20261102_000000_cccccc", "Alpha work", parent="20261101_000000_aaaaaa", started=T0 - 60)
        self.session("20261102_000000_dddddd", "side job", end="agent_close", parent="20261101_000000_bbbbbb",
                     started=T0 - 30)
        self.run_ledger("update")
        self.close_tab("w1:t1")
        self.close_tab("w1:t2")
        self.run_ledger("restore", "ALPHA", "BETA")
        resumed = sorted(c[c.index("--resume") + 1] for c in self.calls("agent", "start"))
        # ALPHA continues in its compression child; BETA's side session is not the tab's conversation.
        self.assertEqual(resumed, ["20261101_000000_bbbbbb", "20261102_000000_cccccc"])

    # ── loss reasons and restore ──
    def test_closed_tab_is_kept_restored_named_and_resumed(self):
        self.run_ledger("update")
        self.close_tab("w1:t2")
        self.run_ledger("update", "--auto")
        e = self.entry("BETA")
        self.assertEqual((e["state"], e["lost_reason"]), ("lost", "closed"))
        self.assertEqual(self.calls("tab", "create"), [], "a tab you closed must not come back on its own")
        out = self.run_ledger("restore", "BETA")
        self.assertIn("restored BETA", out)
        create = self.calls("tab", "create")[0]
        self.assertEqual(create[create.index("--cwd") + 1], "/srv/beta")
        self.assertIn(["tab", "rename", "w1:t10", "BETA"], self.calls("tab", "rename"))
        start = self.calls("agent", "start")[0]
        self.assertEqual(start[start.index("--resume") + 1], "20261101_000000_bbbbbb")
        self.assertEqual(self.entry("BETA")["state"], "live")      # one entry, matched back by lineage
        self.assertEqual(len(self.ledger()["entries"]), 3)

    def test_hermes_exited_resumes_into_the_same_tab(self):
        self.run_ledger("update")
        self.load()
        p = next(p for p in self.st["panes"] if p["tab_id"] == "w1:t1")
        p.update(agent=None, agent_session=None, terminal_title_stripped=None)   # bare shell left behind
        self.save()
        self.run_ledger("update")
        self.run_ledger("update")
        self.assertEqual(self.entry("ALPHA")["lost_reason"], "hermes-exited")
        self.assertEqual(len(self.ledger()["entries"]), 3, "the surviving shell tab is still ALPHA's")
        self.run_ledger("restore", "ALPHA")
        self.assertEqual(self.calls("tab", "create"), [])
        start = self.calls("agent", "start")[0]
        self.assertEqual(start[start.index("--pane") + 1], "w1:p1")
        self.assertEqual(self.entry("ALPHA")["state"], "live")
        self.assertEqual(len(self.ledger()["entries"]), 3, "no duplicate shell entry for the reused tab")

    def test_memguard_kill_is_attributed(self):
        self.run_ledger("update")
        self.load()
        self.st["journal"] = ["memguard: ended pane w1:p1 idle 13h; resume: hermes --resume 20261101_000000_aaaaaa"]
        p = next(p for p in self.st["panes"] if p["tab_id"] == "w1:t1")
        p.update(agent=None, agent_session=None, terminal_title_stripped=None)
        self.save()
        self.run_ledger("update")
        self.assertEqual(self.entry("ALPHA")["lost_reason"], "memguard")

    def test_server_restart_restores_after_grace_only(self):
        self.run_ledger("update")
        self.load()
        self.st.update(server_pid="99999902", server_lstart=lstart(T0 + 1000),   # session.json was wiped
                       tabs=[], panes=[], workspaces=[{"workspace_id": "w1", "label": "ws"}])
        self.save()
        self.run_ledger("update", "--auto", now=T0 + 1010)
        self.assertEqual(self.entry("ALPHA")["lost_reason"], "server-restart")
        self.assertEqual(self.calls("tab", "create"), [], "inside the grace period hmw is still restoring")
        lock = self.hh / "logs" / "hmw-ws.restore.lock"
        lock.mkdir(parents=True)
        self.run_ledger("update", "--auto", now=T0 + 1400)
        self.assertEqual(self.calls("tab", "create"), [], "never race hmw's own restore")
        lock.rmdir()
        self.run_ledger("update", "--auto", now=T0 + 1400)
        restored = sorted(c[-1] for c in self.calls("tab", "rename"))
        self.assertEqual(restored, ["ALPHA", "BETA", "NOTES"])
        self.assertEqual(sorted(c[c.index("--resume") + 1] for c in self.calls("agent", "start")),
                         ["20261101_000000_aaaaaa", "20261101_000000_bbbbbb"])

    def test_already_running_session_is_never_resumed_twice(self):
        self.run_ledger("update")
        self.close_tab("w1:t2")
        self.load()
        self.st["procs"] = ["python3 -m hermes chat --resume 20261101_000000_bbbbbb"]
        self.save()
        out = self.run_ledger("restore", "BETA")
        self.assertIn("already running", out)
        self.assertEqual(self.calls("tab", "create"), [])

    def test_failed_resume_closes_only_tabs_it_created(self):
        self.run_ledger("update")
        self.close_tab("w1:t2")
        self.load()
        p = next(p for p in self.st["panes"] if p["tab_id"] == "w1:t1")
        p.update(agent=None, agent_session=None, terminal_title_stripped=None)
        self.st["fail_agent_start"] = True
        self.save()
        out = self.run_ledger("restore")
        self.assertEqual(out.count("FAILED"), 2, out)
        self.assertEqual([c[2] for c in self.calls("tab", "close")], ["w1:t10"], "the user's ALPHA tab stays")
        self.assertIn("w1:t1", [t["tab_id"] for t in self.load()["tabs"]])
        self.assertEqual({self.entry(n)["state"] for n in ("ALPHA", "BETA")}, {"lost"})

    def test_forget_stops_tracking(self):
        self.run_ledger("update")
        self.close_tab("w1:t3")
        self.run_ledger("forget", "NOTES")
        self.assertEqual(self.entry("NOTES")["state"], "forgotten")
        self.assertIn("nothing lost matches", self.run_ledger("restore", "NOTES"))

    # ── unseen-work marker ──
    def test_unseen_done_survives_a_restart_as_a_marker_until_focused(self):
        self.load()
        next(t for t in self.st["tabs"] if t["tab_id"] == "w1:t1")["agent_status"] = "done"
        self.save()
        self.run_ledger("update")
        self.load()
        self.st.update(server_pid="99999902", server_lstart=lstart(T0 + 1000))   # same tabs, status forgotten
        for t in self.st["tabs"]:
            t["agent_status"] = "idle" if t["tab_id"] != "w1:t3" else None
        self.save()
        self.run_ledger("update", now=T0 + 1010)
        labels = {t["tab_id"]: t["label"] for t in self.load()["tabs"]}
        self.assertEqual(labels["w1:t1"], "\u25cf ALPHA")
        self.assertEqual(labels["w1:t2"], "BETA")
        self.run_ledger("update", now=T0 + 1020)
        self.assertEqual(self.entry("ALPHA")["tab_label"], "ALPHA", "the marker never becomes the name")
        self.load()
        next(t for t in self.st["tabs"] if t["tab_id"] == "w1:t1")["focused"] = True
        self.save()
        self.run_ledger("update", now=T0 + 1030)
        self.assertEqual({t["tab_id"]: t["label"] for t in self.load()["tabs"]}["w1:t1"], "ALPHA")

    # ── robustness ──
    def test_missing_state_db_still_records_tabs(self):
        (self.hh / "state.db").unlink()
        self.run_ledger("update")
        self.assertEqual(len(self.ledger()["entries"]), 3)

    def test_runs_on_python_39_syntax(self):
        import ast
        ast.parse(LEDGER.read_text(), str(LEDGER), feature_version=(3, 9))


if __name__ == "__main__":
    unittest.main()
