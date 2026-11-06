"""Tests for scripts/hmw-ledger: the durable record of every herdr tab.

A fake herdr (JSON state file) plus fake pgrep/ps/journalctl on PATH and a
throwaway state.db make every loss path deterministic: closed tab, Hermes
exited in a surviving tab, memguard kill, server restart (auto-restore after a
grace period), the unseen-work marker, and the safety rules: never resume a
conversation that is open anywhere, never race hmw's restore, never reuse a
tab that is not provably the same, never close a tab the ledger did not create.
"""
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
LEDGER = REPO / "scripts" / "hmw-ledger"
T0 = 1_800_000_000.0
A, B, C = "20261101_000000_aaaaaa", "20261101_000000_bbbbbb", "20261101_000000_cccccc"
HERMES_FG = [["/usr/bin/python3", "/usr/local/lib/hermes-agent/hermes", "chat"]]
SHELL_FG = [["-bash"]]

FAKE_HERDR = r'''#!/usr/bin/env python3
import json, os, sys, time
path = os.environ["FAKE_STATE"]
st = json.load(open(path))
a = sys.argv[1:]
assert a[:2] == ["--session", "ws"], a
a = a[2:]
st.setdefault("calls", []).append(a)
def save():
    json.dump(st, open(path, "w"))
def out(result):
    save(); print(json.dumps({"result": result})); sys.exit(0)
def fail(msg):
    save(); print(msg, file=sys.stderr); sys.exit(1)
def pane(pid):
    return next(p for p in st["panes"] if p["pane_id"] == pid)
def new_pane(tid, ws, cwd):
    n = st["next"]; st["next"] = n + 1
    pid = "%s:p%d" % (ws, n)
    st["panes"].append({"pane_id": pid, "tab_id": tid, "workspace_id": ws, "label": None, "agent": None,
                        "agent_session": None, "terminal_title_stripped": None, "cwd": cwd, "fg": [["-bash"]]})
    return pid
cmd = a[:2]
if cmd == ["pane", "list"]:
    out({"panes": [{k: v for k, v in p.items() if k != "fg"} for p in st["panes"]]})
if cmd == ["tab", "list"]:
    out({"tabs": st["tabs"]})
if cmd == ["workspace", "list"]:
    out({"workspaces": st["workspaces"]})
if cmd == ["pane", "process-info"]:
    p = pane(a[a.index("--pane") + 1])
    out({"process_info": {"pane_id": p["pane_id"], "foreground_processes":
                          [{"pid": 100 + i, "argv": v} for i, v in enumerate(p.get("fg") or [])]}})
if cmd == ["tab", "create"]:
    ws = a[a.index("--workspace") + 1]
    n = st["next"]
    tid = "%s:t%d" % (ws, n)
    st["tabs"].append({"tab_id": tid, "workspace_id": ws, "label": str(n), "agent_status": None, "focused": False})
    pid = new_pane(tid, ws, a[a.index("--cwd") + 1])
    out({"tab": {"tab_id": tid}, "root_pane": {"pane_id": pid}})
if cmd == ["pane", "split"]:
    if st.get("fail_split"):
        fail("split refused")
    p = pane(a[2])
    out({"pane": {"pane_id": new_pane(p["tab_id"], p["workspace_id"], p["cwd"])}})
if cmd == ["tab", "rename"]:
    if st.get("fail_tab_rename"):
        fail("rename refused")
    next(t for t in st["tabs"] if t["tab_id"] == a[2])["label"] = a[3]
    out({})
if cmd == ["pane", "rename"]:
    pane(a[2])["label"] = a[3]
    out({})
if cmd == ["tab", "close"]:
    st["tabs"] = [t for t in st["tabs"] if t["tab_id"] != a[2]]
    st["panes"] = [p for p in st["panes"] if p["tab_id"] != a[2]]
    out({})
if cmd == ["agent", "start"]:
    if st.get("agent_start_sleep"):
        save(); time.sleep(st["agent_start_sleep"]); sys.exit(0)
    if st.get("fail_agent_start"):
        fail("pane_not_ready")
    p = pane(a[a.index("--pane") + 1])
    sid = a[a.index("--resume") + 1]
    p.update(agent="hermes", agent_session={"value": sid}, terminal_title_stripped="\u2713 " + st["titles"][sid],
             fg=[["/usr/bin/python3", "/usr/local/lib/hermes-agent/hermes", "chat"]])
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
    if not st.get("server_lstart"):
        sys.exit(1)
    print(st["server_lstart"])
'''

FAKE_JOURNALCTL = r'''#!/usr/bin/env python3
import json, os
print("\n".join(json.load(open(os.environ["FAKE_STATE"])).get("journal", [])))
'''


def lstart(epoch):
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
        self.session(A, "Alpha work")
        self.session(B, "Beta research")
        self.session(C, "Gamma split pane")
        self.st = {"next": 10, "server_pid": "99999901", "server_lstart": lstart(T0), "procs": [],
                   "workspaces": [{"workspace_id": "w1", "label": "ws"}], "tabs": [], "panes": []}
        self.tab("w1:t1", "ALPHA", A)
        self.tab("w1:t2", "BETA", B)
        self.tab("w1:t3", "NOTES", None)
        self.save()

    # ── fixture helpers ──
    def session(self, sid, title, end=None, parent=None, started=T0 - 3600, active=None):
        self.db.execute("insert into sessions values (?,?,?,?,?,?,?)",
                        (sid, "tui", title, end, parent, started, active or started))
        self.db.commit()
        self.titles[sid] = title

    def tab(self, tid, label, sid, status="idle", focused=False):
        n = tid.split(":t")[1]
        self.st["tabs"].append({"tab_id": tid, "workspace_id": "w1", "label": label,
                                "agent_status": status if sid else None, "focused": focused})
        self.pane(tid, "w1:p" + n, sid, label)

    def pane(self, tid, pid, sid, label, pane_label=None):
        self.st["panes"].append({
            "pane_id": pid, "tab_id": tid, "workspace_id": "w1", "label": pane_label,
            "agent": "hermes" if sid else None, "cwd": "/srv/" + label.lower(),
            "agent_session": {"value": sid} if sid else None,
            "terminal_title_stripped": ("\u2713 " + self.titles[sid]) if sid else None,
            "fg": HERMES_FG if sid else SHELL_FG})

    def save(self):
        self.st["titles"] = self.titles
        self.state.write_text(json.dumps(self.st))

    def load(self):
        self.st = json.loads(self.state.read_text())
        return self.st

    def edit(self, **kw):
        self.load(); self.st.update(kw); self.save()

    def pane_of(self, tid):
        return next(p for p in self.st["panes"] if p["tab_id"] == tid)

    def exit_hermes(self, tid, retain_identity=False):
        """Hermes exits; the tab stays as a bare shell (memguard, crash, /quit)."""
        self.load()
        p = self.pane_of(tid)
        p["fg"] = SHELL_FG
        if not retain_identity:
            p.update(agent=None, agent_session=None, terminal_title_stripped=None)
        self.save()

    def env(self, now=T0 + 60, **extra):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"], HOME=str(self.tmp / "home"),
                   HERMES_HOME=str(self.hh), HERDR_SESSION="ws", FAKE_STATE=str(self.state),
                   HMW_LEDGER_NOW=repr(float(now)), **extra)
        for k in ("HMW_STATE_DIR", "HMW_LOG_DIR"):
            env.pop(k, None)
        return env

    def run_ledger(self, *args, now=T0 + 60, **extra):
        r = subprocess.run([sys.executable, str(LEDGER), *args], env=self.env(now, **extra),
                           capture_output=True, text=True, timeout=90)
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

    def resumed(self):
        return sorted(c[c.index("--resume") + 1] for c in self.calls("agent", "start"))

    def close_tab(self, tid):
        self.load()
        self.st["tabs"] = [t for t in self.st["tabs"] if t["tab_id"] != tid]
        self.st["panes"] = [p for p in self.st["panes"] if p["tab_id"] != tid]
        self.save()

    def restart_server(self, wipe=True, at=T0 + 1000):
        self.load()
        self.st.update(server_pid="99999902", server_lstart=lstart(at))
        if wipe:                                     # session.json was lost: herdr comes back empty
            self.st.update(tabs=[], panes=[])
        self.save()

    # ── recording ──
    def test_records_every_tab_with_verified_conversation(self):
        self.run_ledger("update")
        self.assertEqual(sorted(e["tab_label"] for e in self.ledger()["entries"]), ["ALPHA", "BETA", "NOTES"])
        a = self.entry("ALPHA")["panes"][0]
        self.assertEqual((a["session_id"], a["sid_source"]), (A, "herdr-verified"))
        self.assertEqual(self.entry("NOTES")["panes"][0]["session_id"], None)
        self.assertEqual({e["state"] for e in self.ledger()["entries"]}, {"live"})

    def test_stale_herdr_hint_is_replaced_by_title_match(self):
        self.load()
        self.pane_of("w1:t1")["agent_session"] = {"value": B}   # herdr points at another conversation
        self.save()
        self.run_ledger("update")
        a = self.entry("ALPHA")["panes"][0]
        self.assertEqual((a["session_id"], a["sid_source"]), (A, "title-match"))

    def test_chains_follow_compression_only(self):
        self.db.execute("update sessions set end_reason='compression' where id=?", (A,))
        self.session("20261102_000000_dddddd", "Alpha work", parent=A, started=T0 - 60)
        self.session("20261102_000000_eeeeee", "side job", end="agent_close", parent=B, started=T0 - 30)
        self.run_ledger("update")
        self.close_tab("w1:t1")
        self.close_tab("w1:t2")
        self.run_ledger("restore", "ALPHA", "BETA")
        # ALPHA continues in its compression child; BETA's side session is not the tab's conversation.
        self.assertEqual(self.resumed(), [B, "20261102_000000_dddddd"])

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
        self.assertEqual(self.resumed(), [B])
        self.assertEqual(self.entry("BETA")["state"], "live")      # one entry, matched back by lineage
        self.assertEqual(len(self.ledger()["entries"]), 3)

    def test_closed_by_mistake_comes_straight_back_by_hand(self):
        self.db.execute("update sessions set last_activity_at=? where id=?", (T0 + 50, B))   # active a moment ago
        self.db.commit()
        self.run_ledger("update")
        self.close_tab("w1:t2")
        self.run_ledger("restore", "BETA")
        self.assertEqual(self.resumed(), [B])

    def test_hermes_exited_resumes_into_the_same_tab(self):
        self.run_ledger("update")
        self.exit_hermes("w1:t1")
        self.run_ledger("update")
        self.run_ledger("update")
        self.assertEqual(self.entry("ALPHA")["lost_reason"], "hermes-exited")
        self.assertEqual(len(self.ledger()["entries"]), 3, "the surviving shell tab is still ALPHA's")
        self.run_ledger("restore", "ALPHA")
        self.assertEqual(self.calls("tab", "create"), [])
        start = self.calls("agent", "start")[0]
        self.assertEqual(start[start.index("--pane") + 1], "w1:p1")
        self.assertEqual(self.calls("tab", "rename"), [], "a reused tab keeps its name untouched")
        self.assertEqual(self.entry("ALPHA")["state"], "live")
        self.assertEqual(len(self.ledger()["entries"]), 3)

    def test_retained_herdr_identity_after_exit_is_still_detected(self):
        self.run_ledger("update")
        self.exit_hermes("w1:t1", retain_identity=True)     # herdr still says agent=hermes, session A
        self.run_ledger("update")
        self.assertEqual(self.entry("ALPHA")["lost_reason"], "hermes-exited")
        self.run_ledger("restore", "ALPHA")
        self.assertEqual(self.resumed(), [A], "its own stale identity must not block the resume")

    def test_memguard_kill_is_attributed(self):
        self.run_ledger("update")
        self.edit(journal=["memguard: ended pane w1:p1 idle 13h; resume: hermes --resume " + A])
        self.exit_hermes("w1:t1")
        self.run_ledger("update")
        self.assertEqual(self.entry("ALPHA")["lost_reason"], "memguard")

    def test_reuse_refused_unless_provably_the_same_bare_tab(self):
        self.run_ledger("update")
        self.exit_hermes("w1:t1")
        self.run_ledger("update")
        self.load()
        self.pane_of("w1:t1")["fg"] = [["-bash"], ["vim", "notes.txt"]]    # the user is working in it now
        self.save()
        self.run_ledger("restore", "ALPHA")
        self.assertEqual(len(self.calls("tab", "create")), 1, "a busy tab is never typed into")
        start = self.calls("agent", "start")[0]
        self.assertEqual(start[start.index("--pane") + 1], "w1:p10")
        self.assertNotIn("w1:t1", [c[2] for c in self.calls("tab", "rename")])

    def test_reuse_refused_after_a_server_restart_recycles_ids(self):
        self.run_ledger("update")
        self.exit_hermes("w1:t1")
        self.run_ledger("update")
        self.restart_server(wipe=False)                    # same ids again, but another server generation
        self.run_ledger("update", now=T0 + 1010)
        self.run_ledger("restore", "ALPHA", now=T0 + 1020)
        self.assertEqual(len(self.calls("tab", "create")), 1)

    def test_server_restart_restores_after_grace_only(self):
        self.run_ledger("update")
        self.restart_server()
        self.run_ledger("update", "--auto", now=T0 + 1010)
        self.assertEqual(self.entry("ALPHA")["lost_reason"], "server-restart")
        self.assertEqual(self.calls("tab", "create"), [], "inside the grace period hmw is still restoring")
        lock = self.hh / "logs" / "hmw-ws.restore.lock"
        lock.mkdir(parents=True)
        self.run_ledger("update", "--auto", now=T0 + 1400)
        self.assertEqual(self.calls("tab", "create"), [], "never race hmw's own restore")
        self.assertTrue(lock.is_dir(), "hmw's lock is never removed by the ledger")
        lock.rmdir()
        self.run_ledger("update", "--auto", now=T0 + 1400)
        self.assertEqual(sorted(c[-1] for c in self.calls("tab", "rename")), ["ALPHA", "BETA", "NOTES"])
        self.assertEqual(self.resumed(), [A, B])
        self.assertFalse(lock.exists(), "the ledger releases the lock it took")

    def test_manual_restore_waits_for_hmw_lock(self):
        self.run_ledger("update")
        self.close_tab("w1:t2")
        lock = self.hh / "logs" / "hmw-ws.restore.lock"
        lock.mkdir(parents=True)
        proc = subprocess.Popen([sys.executable, str(LEDGER), "restore", "BETA"], env=self.env(),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        time.sleep(3)
        self.assertEqual(self.calls("agent", "start"), [], "nothing launches while hmw holds the lock")
        lock.rmdir()
        out, err = proc.communicate(timeout=60)
        self.assertIn("restored BETA", out, err)

    def test_stale_ledger_owned_lock_is_cleared(self):
        self.run_ledger("update")
        self.close_tab("w1:t2")
        lock = self.hh / "logs" / "hmw-ws.restore.lock"
        lock.mkdir(parents=True)
        (lock / "hmw-ledger.pid").write_text("999999999")    # a killed ledger run
        self.run_ledger("restore", "BETA")
        self.assertEqual(self.resumed(), [B])

    def test_pgrep_miss_is_not_a_restart(self):
        self.run_ledger("update")
        self.edit(server_pid=None, tabs=[], panes=[])          # server not found and nothing listed
        self.run_ledger("update", "--auto", now=T0 + 400)
        self.assertEqual({e["state"] for e in self.ledger()["entries"]}, {"live"})
        self.edit(server_pid="99999901")                       # the same server is back, still empty
        self.run_ledger("update", "--auto", now=T0 + 800)
        self.assertEqual(self.entry("ALPHA")["lost_reason"], "closed")
        self.run_ledger("update", "--auto", now=T0 + 2000)
        self.assertEqual(self.calls("tab", "create"), [])

    def test_grace_uses_first_sighting_when_start_time_is_unknown(self):
        self.edit(server_lstart=None)                          # neither /proc nor ps can date the server
        self.run_ledger("update")
        self.restart_server()
        self.edit(server_lstart=None)
        self.run_ledger("update", "--auto", now=T0 + 1010)
        self.assertEqual(self.calls("tab", "create"), [])
        self.run_ledger("update", "--auto", now=T0 + 1400)
        self.assertEqual(self.resumed(), [A, B])

    def test_automatic_restore_never_uses_an_unverified_id(self):
        self.load()
        p = self.pane_of("w1:t1")
        p["agent_session"] = {"value": C}
        p["terminal_title_stripped"] = "\u2713 something unrelated"
        self.save()
        self.run_ledger("update")
        self.assertEqual(self.entry("ALPHA")["panes"][0]["sid_source"], "herdr-unverified")
        self.restart_server()
        self.run_ledger("update", "--auto", now=T0 + 1010)
        out = self.run_ledger("update", "--auto", now=T0 + 1400)
        self.assertIn("unverified", out)
        self.assertEqual(self.resumed(), [B], "BETA (verified) only; ALPHA's id is a guess")
        self.assertEqual(self.entry("ALPHA")["state"], "lost")

    # ── never twice ──
    def test_already_running_session_is_never_resumed_twice(self):
        self.run_ledger("update")
        self.close_tab("w1:t2")
        self.edit(procs=["python3 -m hermes chat --resume " + B])
        out = self.run_ledger("restore", "BETA")
        self.assertIn("already running", out)
        self.assertEqual(self.calls("tab", "create"), [])

    def test_lease_holder_counts_as_running(self):
        # Opened inside a Hermes TUI (no --resume on its command line): only its lease says so.
        (self.hh / "runtime").mkdir()
        (self.hh / "runtime" / "active_sessions.json").write_text(json.dumps(
            {"entries": [{"session_id": B, "pid": os.getpid(), "surface": "tui", "process_start_time": 1.0}]}))
        self.run_ledger("update")
        self.close_tab("w1:t2")
        self.assertIn("already running", self.run_ledger("restore", "BETA"))
        self.assertEqual(self.calls("agent", "start"), [])

    def test_unreadable_lease_registry_restores_nothing(self):
        (self.hh / "runtime").mkdir()
        (self.hh / "runtime" / "active_sessions.json").write_text("{not json")
        self.run_ledger("update")
        self.close_tab("w1:t2")
        self.assertIn("not restoring", self.run_ledger("restore", "BETA"))
        self.assertEqual(self.calls("tab", "create"), [])

    def test_recent_activity_blocks_automatic_restore(self):
        self.run_ledger("update")
        self.restart_server()
        self.run_ledger("update", "--auto", now=T0 + 1010)
        self.db.execute("update sessions set last_activity_at=? where id=?", (T0 + 1300, A))   # open elsewhere?
        self.db.commit()
        self.run_ledger("update", "--auto", now=T0 + 1400)
        self.assertEqual(self.resumed(), [B])

    def test_one_conversation_in_two_entries_launches_once(self):
        self.run_ledger("update")
        led = self.ledger()
        dup = json.loads(json.dumps(next(e for e in led["entries"] if e["tab_label"] == "BETA")))
        dup.update(id="dup", tab_label="BETA2")
        led["entries"].append(dup)
        (self.hh / "hmw" / "ws.ledger.json").write_text(json.dumps(led))
        self.close_tab("w1:t2")
        self.run_ledger("restore")
        self.assertEqual(self.resumed(), [B])

    # ── failures ──
    def test_failed_resume_closes_only_tabs_it_created(self):
        self.run_ledger("update")
        self.close_tab("w1:t2")
        self.exit_hermes("w1:t1")
        self.edit(fail_agent_start=True)
        self.run_ledger("update")
        out = self.run_ledger("restore")
        self.assertEqual(out.count("FAILED"), 2, out)
        self.assertEqual([c[2] for c in self.calls("tab", "close")], ["w1:t10"], "the user's ALPHA tab stays")
        self.assertIn("w1:t1", [t["tab_id"] for t in self.load()["tabs"]])
        self.assertEqual({self.entry(n)["state"] for n in ("ALPHA", "BETA")}, {"lost"})

    def test_agent_start_timeout_is_ambiguous_and_keeps_progress(self):
        self.run_ledger("update")
        self.close_tab("w1:t1")
        self.close_tab("w1:t2")
        self.edit(agent_start_sleep=9)              # past the 1s start timeout's 6.5s subprocess limit
        out = self.run_ledger("restore", "ALPHA", "BETA", HMW_LEDGER_AGENT_START_MS="1000")
        self.assertEqual(out.count("UNSURE"), 2, out)
        self.assertEqual(self.calls("tab", "close"), [], "an unconfirmed start is never torn down")
        self.assertEqual(len(self.calls("tab", "create")), 2)
        self.edit(agent_start_sleep=0)
        self.run_ledger("restore", "ALPHA", "BETA")
        self.assertEqual(len(self.calls("tab", "create")), 2, "no second copy of an unconfirmed restore")

    def test_split_tab_restores_every_pane(self):
        self.load()
        self.pane("w1:t2", "w1:p9", C, "BETA", pane_label="H2")
        self.save()
        self.run_ledger("update")
        self.close_tab("w1:t2")
        self.run_ledger("restore", "BETA")
        self.assertEqual(self.resumed(), [B, C])
        self.assertEqual(len(self.calls("pane", "split")), 1)
        self.run_ledger("update")
        self.assertEqual(len(self.entry("BETA")["panes"]), 2)

    def test_split_pane_that_cannot_be_restored_is_kept(self):
        self.load()
        self.pane("w1:t2", "w1:p9", C, "BETA", pane_label="H2")
        self.save()
        self.run_ledger("update")
        self.close_tab("w1:t2")
        self.edit(fail_split=True)
        self.run_ledger("restore", "BETA")
        self.assertEqual(self.resumed(), [B])
        kept = self.entry("BETA-H2")
        self.assertEqual((kept["state"], kept["panes"][0]["session_id"]), ("lost", C))
        self.run_ledger("update")
        self.assertEqual(self.entry("BETA-H2")["state"], "lost", "still on record after the next update")

    def test_closing_one_split_pane_keeps_its_conversation(self):
        self.load()
        self.pane("w1:t2", "w1:p9", C, "BETA", pane_label="H2")
        self.save()
        self.run_ledger("update")
        self.load()
        self.st["panes"] = [p for p in self.st["panes"] if p["pane_id"] != "w1:p9"]
        self.save()
        self.run_ledger("update")
        self.assertEqual(self.entry("BETA-H2")["panes"][0]["session_id"], C)
        self.assertEqual(self.entry("BETA")["state"], "live")

    def test_forget_stops_tracking(self):
        self.run_ledger("update")
        self.close_tab("w1:t3")
        self.run_ledger("forget", "NOTES")
        self.assertEqual(self.entry("NOTES")["state"], "forgotten")
        self.assertIn("nothing lost matches", self.run_ledger("restore", "NOTES"))

    def test_old_entries_are_pruned(self):
        self.run_ledger("update")
        self.close_tab("w1:t3")
        self.close_tab("w1:t2")
        self.run_ledger("update")
        self.run_ledger("update", now=T0 + 8 * 86400)
        labels = sorted(e["tab_label"] for e in self.ledger()["entries"])
        self.assertEqual(labels, ["ALPHA", "BETA"], "a lost shell tab goes after a week; a conversation stays")

    # ── unseen-work marker ──
    def test_unseen_done_survives_a_restart_as_a_marker_until_focused(self):
        self.load()
        next(t for t in self.st["tabs"] if t["tab_id"] == "w1:t1")["agent_status"] = "done"
        self.save()
        self.run_ledger("update")
        self.restart_server(wipe=False)                   # same tabs, herdr forgot "done"
        self.load()
        for t in self.st["tabs"]:
            t["agent_status"] = "idle" if t["tab_id"] != "w1:t3" else None
        self.save()
        self.run_ledger("update", now=T0 + 1010)
        labels = {t["tab_id"]: t["label"] for t in self.load()["tabs"]}
        self.assertEqual((labels["w1:t1"], labels["w1:t2"]), ("\u25cf ALPHA", "BETA"))
        self.run_ledger("update", now=T0 + 1020)
        self.assertEqual(self.entry("ALPHA")["tab_label"], "ALPHA", "the marker never becomes the name")
        self.load()
        next(t for t in self.st["tabs"] if t["tab_id"] == "w1:t1")["focused"] = True
        self.st["fail_tab_rename"] = True
        self.save()
        self.run_ledger("update", now=T0 + 1030)
        self.assertTrue(self.entry("ALPHA")["unseen_carry"], "a failed clear is retried")
        self.edit(fail_tab_rename=False)
        self.run_ledger("update", now=T0 + 1040)
        self.assertEqual({t["tab_id"]: t["label"] for t in self.load()["tabs"]}["w1:t1"], "ALPHA")
        self.assertFalse(self.entry("ALPHA")["unseen_carry"])

    def test_unseen_marker_follows_a_tab_that_had_to_be_restored(self):
        self.load()
        next(t for t in self.st["tabs"] if t["tab_id"] == "w1:t1")["agent_status"] = "done"
        self.save()
        self.run_ledger("update")
        self.restart_server()
        self.run_ledger("update", "--auto", now=T0 + 1010)
        self.run_ledger("update", "--auto", now=T0 + 1400)
        self.run_ledger("update", now=T0 + 1410)
        alpha = next(t for t in self.load()["tabs"] if t["label"].endswith("ALPHA"))
        self.assertEqual(alpha["label"], "\u25cf ALPHA")

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
