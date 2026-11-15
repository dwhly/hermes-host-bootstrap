#!/usr/bin/env python3
"""tests/test_fleet_trace_retention.py — scripts/fleet-trace-retention against a real Hermes SessionDB (temp home).

Run with the Hermes interpreter (it needs hermes_state):
  /usr/local/lib/hermes-agent/venv/bin/python -m unittest tests.test_fleet_trace_retention
HERMES_SRC overrides the Hermes source dir. No network; the copy store is a fake `psql` that prints a JSON file.
"""
import datetime as dt, hashlib, json, os, shutil, sqlite3, subprocess, sys, tempfile, time, unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
SCRIPT = HERE / "scripts" / "fleet-trace-retention"
SRC = Path(os.environ.get("HERMES_SRC", "/usr/local/lib/hermes-agent"))
os.environ.setdefault("HERMES_DISABLE_LAZY_INSTALLS", "1")
sys.path.insert(0, str(SRC))
from hermes_state import SessionDB  # noqa: E402  (fails loudly when run without Hermes; never skips)

DAY = 86400
S1, S2, S3, CHILD, OTHER = ("20260801_100000_aaaa01", "20260801_100000_aaaa02", "20260801_100000_aaaa03",
                            "20260801_100000_cccc01", "20260801_100000_ffff01")


def iso(ts):
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).isoformat()


class Retention(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.t, True)
        self.home = self.t / "home"
        self.home.mkdir()
        (self.home / "config.yaml").write_text("sessions:\n  auto_prune: false\n")
        self.q = self.t / "queue"
        self.q.mkdir()
        self.db_path = self.home / "state.db"
        db = SessionDB(self.db_path)
        for sid in (S1, S2, S3, OTHER):
            db.create_session(sid, "cli")
            db.append_message(sid, "user", f"brief for {sid}")
            db.append_message(sid, "assistant", "done")
            db.end_session(sid, "cli_close")
        db.close()
        self.job("j1", S1)
        self.job("j2", S2)
        self.job("j3", S3, via="log")
        self.receipts = []
        self.bin = self.t / "bin"
        self.bin.mkdir()
        self.rfile = self.t / "receipts.json"
        psql = self.bin / "psql"
        psql.write_text(f"#!/bin/sh\ncat '{self.rfile}'\n")
        psql.chmod(0o755)
        self.dsn = self.t / "dsn"
        self.dsn.write_text("host=/var/run/postgresql dbname=fleet_test user=fleet_retention\n")

    # fixtures ---------------------------------------------------------------------------------------------------
    def job(self, jid, sid, via="runs", state="done"):
        (self.q / f"{jid}.job.json").write_text(json.dumps({"id": jid, "card_id": "c1", "body": "x"}))
        (self.q / f"{jid}.status.json").write_text(json.dumps({"state": state}))
        if via == "runs":
            (self.q / f"{jid}.runs.jsonl").write_text(json.dumps({"job": jid, "attempt": 1,
                                                                 "hermes_session_id": sid}) + "\n")
        else:
            (self.q / f"{jid}.log").write_text(f"...\nSession:   {sid}\nhermes --resume {sid}\n")

    def tool(self):
        ns = {}
        code = SCRIPT.read_text()
        exec(compile(code.replace('if __name__ == "__main__":', "if False:"), str(SCRIPT), "exec"), ns)
        return ns

    def hash_of(self, covered):
        conn = sqlite3.connect(f"file:{self.db_path}?mode=ro", uri=True)
        try:
            return self.tool()["content_hash"](conn, covered)
        finally:
            conn.close()

    def in_process(self):
        """plan() in this process, so a test can change state.db between the plan and apply()."""
        self.rfile.write_text(json.dumps(self.receipts))
        ns = self.tool()
        import argparse
        args = argparse.Namespace(hermes_home=str(self.home), hermes_src=str(SRC), queue_dir=str(self.q),
                                  copies_dsn_file=str(self.dsn), psql=str(self.bin / "psql"), keep_days=90,
                                  apply=True, src_ok=True)
        report, ctx = ns["plan"](args, time.time())
        return ns, args, report, ctx

    def child(self, pinned=False, ended=True):
        db = SessionDB(self.db_path)
        db.create_session(CHILD, "subagent", model_config={"_delegate_from": S1}, parent_session_id=S1)
        db.append_message(CHILD, "user", "child")
        if ended:
            db.end_session(CHILD, "done")
        if pinned:
            db.set_session_pinned(CHILD, True)
        db.close()

    def receipt(self, sid, jid, days_ago, covered=None, sha=None, count=None, **over):
        covered = covered or [sid]
        h, n = self.hash_of(set(covered))
        r = {"session_id": sid, "job_id": jid, "covered_session_ids": covered, "message_count": n if count is None
             else count, "content_sha256": sha or h, "copied_at": iso(time.time() - days_ago * DAY),
             "hash_version": 1}
        r.update(over)
        self.receipts.append(r)

    def run_tool(self, *extra, copies=True):
        self.rfile.write_text(json.dumps(self.receipts))
        args = [sys.executable, str(SCRIPT), "--hermes-home", str(self.home), "--hermes-src", str(SRC),
                "--queue-dir", str(self.q), "--psql", str(self.bin / "psql")]
        if copies:
            args += ["--copies-dsn-file", str(self.dsn)]
        p = subprocess.run(args + list(extra), capture_output=True, text=True, timeout=120,
                           env={**os.environ, "HERMES_HOME": str(self.home)})
        try:
            out = json.loads(p.stdout)
        except ValueError:
            self.fail(f"no JSON (rc={p.returncode}): {p.stdout[-500:]} {p.stderr[-1500:]}")
        return p.returncode, out

    def ids(self):
        c = sqlite3.connect(f"file:{self.db_path}?mode=ro", uri=True)
        try:
            return {r[0] for r in c.execute("select id from sessions")}
        finally:
            c.close()

    def digest(self):
        c = sqlite3.connect(f"file:{self.db_path}?mode=ro", uri=True)
        try:
            return hashlib.sha256(repr(c.execute("select * from messages order by id").fetchall()).encode()).hexdigest()
        finally:
            c.close()

    def reason(self, out, sid):
        return next((k["reason"] for k in out["kept"] if k["session"] == sid), None)

    # cases ------------------------------------------------------------------------------------------------------
    def test_no_copy_store_deletes_nothing(self):
        before = self.digest()
        rc, out = self.run_tool("--apply", copies=False)
        self.assertEqual(rc, 0)
        self.assertEqual(out["eligible"], [])
        self.assertEqual(out["deleted"], [])
        self.assertEqual(self.reason(out, S1), "no Postgres copy receipt")
        self.assertEqual(self.digest(), before)

    def test_old_verified_copy_is_planned_then_deleted(self):
        self.receipt(S1, "j1", 91)
        rc, out = self.run_tool()
        self.assertEqual(rc, 0)
        self.assertEqual([e["session"] for e in out["eligible"]], [S1])
        self.assertIn(S1, self.ids(), "plan mode must not delete")
        rc, out = self.run_tool("--apply")
        self.assertEqual([d["session"] for d in out["deleted"]], [S1])
        self.assertNotIn(S1, self.ids())
        self.assertTrue({S2, S3, OTHER} <= self.ids())

    def test_legacy_log_binding_counts(self):
        self.receipt(S3, "j3", 120)
        rc, out = self.run_tool("--apply")
        self.assertEqual([d["session"] for d in out["deleted"]], [S3])

    def test_copy_younger_than_90_days_kept(self):
        self.receipt(S1, "j1", 89)
        rc, out = self.run_tool("--apply")
        self.assertEqual(out["deleted"], [])
        self.assertEqual(self.reason(out, S1), "copy younger than 90 days")
        self.assertIn(S1, self.ids())

    def test_keep_days_below_90_refused(self):
        rc, out = self.run_tool("--keep-days", "30")
        self.assertEqual(rc, 2)
        self.assertIn("error", out)

    def test_content_changed_after_copy_kept(self):
        self.receipt(S1, "j1", 100)
        db = SessionDB(self.db_path)
        db.append_message(S1, "user", "added after the copy")
        db.close()
        rc, out = self.run_tool("--apply")
        self.assertEqual(out["deleted"], [])
        self.assertEqual(self.reason(out, S1), "state.db content differs from the copy")

    def test_message_count_mismatch_kept(self):
        self.receipt(S1, "j1", 100, count=1)
        rc, out = self.run_tool("--apply")
        self.assertEqual(self.reason(out, S1), "state.db content differs from the copy")

    def test_not_ended_or_pinned_kept(self):
        db = SessionDB(self.db_path)
        db.create_session("20260801_100000_aaaa09", "cli")
        db.append_message("20260801_100000_aaaa09", "user", "open")
        db.set_session_pinned(S2, True)
        db.close()
        self.job("j9", "20260801_100000_aaaa09")
        self.receipt("20260801_100000_aaaa09", "j9", 100)
        self.receipt(S2, "j2", 100)
        rc, out = self.run_tool("--apply")
        self.assertEqual(out["deleted"], [])
        self.assertEqual(self.reason(out, "20260801_100000_aaaa09"), "session not ended")
        self.assertEqual(self.reason(out, S2), "session pinned")

    def test_active_job_kept(self):
        self.job("j1", S1, state="running")
        self.receipt(S1, "j1", 100)
        rc, out = self.run_tool("--apply")
        self.assertEqual(self.reason(out, S1), "its card job is queued, running or unreadable")
        self.assertIn(S1, self.ids())

    def test_session_outside_the_card_queue_never_touched(self):
        self.receipt(OTHER, "j1", 365)
        rc, out = self.run_tool("--apply")
        self.assertEqual(out["deleted"], [])
        self.assertIn(OTHER, self.ids())

    def test_receipt_for_another_job_kept(self):
        self.receipt(S1, "j2", 100)
        rc, out = self.run_tool("--apply")
        self.assertEqual(self.reason(out, S1), "receipt names a job that doesn't name this session")

    def test_new_delegate_child_after_copy_kept(self):
        self.receipt(S1, "j1", 100)
        db = SessionDB(self.db_path)
        db.create_session(CHILD, "subagent", model_config={"_delegate_from": S1}, parent_session_id=S1)
        db.append_message(CHILD, "user", "child")
        db.end_session(CHILD, "done")
        db.close()
        rc, out = self.run_tool("--apply")
        self.assertEqual(self.reason(out, S1), "delegate sessions differ from the copy")
        self.assertTrue({S1, CHILD} <= self.ids())

    def test_pinned_delegate_child_keeps_parent(self):
        self.child(pinned=True)
        self.receipt(S1, "j1", 100, covered=[S1, CHILD])
        rc, out = self.run_tool("--apply")
        self.assertEqual(out["deleted"], [])
        self.assertEqual(self.reason(out, S1), "a covered delegate session is pinned")
        self.assertTrue({S1, CHILD} <= self.ids())

    def test_open_delegate_child_keeps_parent(self):
        self.child(ended=False)
        self.receipt(S1, "j1", 100, covered=[S1, CHILD])
        rc, out = self.run_tool("--apply")
        self.assertEqual(self.reason(out, S1), "a covered delegate session isn't ended")
        self.assertTrue({S1, CHILD} <= self.ids())

    # changes between the plan and the delete: only the in-transaction check can catch these
    def _changed_after_plan(self, change, reason):
        self.receipt(S1, "j1", 100)
        ns, args, report, ctx = self.in_process()
        self.assertEqual([e["session"] for e in report["eligible"]], [S1])   # control: eligible at plan time
        change()
        out = ns["apply"](args, report, ctx)
        self.assertEqual(out["deleted"], [])
        self.assertEqual(out["apply_skipped"], [{"session": S1, "reason": reason}])
        self.assertIn(S1, self.ids())

    def test_message_added_after_plan_kept(self):
        def change():
            db = SessionDB(self.db_path)
            db.append_message(S1, "user", "after the plan")
            db.close()
        self._changed_after_plan(change, "state.db content differs from the copy")

    def test_pinned_after_plan_kept(self):
        def change():
            db = SessionDB(self.db_path)
            db.set_session_pinned(S1, True)
            db.close()
        self._changed_after_plan(change, "session pinned")

    def test_job_requeued_after_plan_kept(self):
        self._changed_after_plan(lambda: (self.q / "j1.status.json").write_text('{"state": "running"}'),
                                 "its card job is queued, running or unreadable")

    def test_new_active_job_naming_the_session_after_plan_kept(self):
        self._changed_after_plan(lambda: self.job("j4", S1, state="running"),
                                 "its card job is queued, running or unreadable")

    def test_apply_after_plan_deletes_when_unchanged(self):
        self.receipt(S1, "j1", 100)
        ns, args, report, ctx = self.in_process()
        out = ns["apply"](args, report, ctx)
        self.assertEqual(out["deleted"], [{"session": S1, "covered": [S1]}])
        self.assertNotIn(S1, self.ids())

    def test_unreviewed_hermes_delete_refused(self):
        self.receipt(S1, "j1", 100)
        ns, args, report, ctx = self.in_process()
        ns["DELETE_SOURCE_SHA256"].clear()
        with self.assertRaises(ns["Refuse"]) as cm:
            ns["apply"](args, report, ctx)
        self.assertIn("unreviewed Hermes delete_session", str(cm.exception))
        self.assertIn(S1, self.ids())

    def test_covered_delegate_child_deleted_with_parent(self):
        self.child()
        self.receipt(S1, "j1", 100, covered=[S1, CHILD])
        rc, out = self.run_tool("--apply")
        self.assertEqual([d["session"] for d in out["deleted"]], [S1])
        self.assertFalse({S1, CHILD} & self.ids())

    def test_malformed_receipts_never_eligible(self):
        self.receipt(S1, "j1", 100, hash_version=2)
        self.receipt(S2, "j2", 100, copied_at="2026-01-01T00:00:00")        # no timezone
        self.receipt(S3, "j3", 100, content_sha256="zz")
        rc, out = self.run_tool("--apply")
        self.assertEqual(rc, 4)
        self.assertEqual(out["deleted"], [])
        self.assertEqual(out["copy_store"]["malformed"], 3)

    def test_one_malformed_receipt_stops_every_delete(self):
        self.receipt(S1, "j1", 100)
        rc, out = self.run_tool()
        self.assertEqual([e["session"] for e in out["eligible"]], [S1])      # control: valid alone is eligible
        self.receipt(S2, "j2", 100, hash_version=2)
        rc, out = self.run_tool("--apply")
        self.assertEqual(rc, 4)
        self.assertEqual(out["deleted"], [])
        self.assertIn(S1, self.ids())

    def test_duplicate_receipt_is_malformed(self):
        self.receipt(S1, "j1", 100)
        self.receipt(S1, "j1", 120)
        rc, out = self.run_tool("--apply")
        self.assertEqual(rc, 4)
        self.assertIn(S1, self.ids())

    def test_unreadable_copy_store_exit_4_nothing_deleted(self):
        self.receipt(S1, "j1", 100)
        (self.bin / "psql").write_text("#!/bin/sh\nexit 2\n")
        before = self.digest()
        rc, out = self.run_tool("--apply")
        self.assertEqual(rc, 4)
        self.assertEqual(out["deleted"], [])
        self.assertEqual(self.digest(), before)

    def test_password_dsn_refused(self):
        self.dsn.write_text("host=x dbname=y user=z password=hunter2\n")
        self.receipt(S1, "j1", 100)
        rc, out = self.run_tool("--apply")
        self.assertEqual(rc, 4)
        self.assertNotIn("hunter2", json.dumps(out))
        self.assertIn(S1, self.ids())

    def test_stale_receipt_counts_as_no_copy_for_native_prune(self):
        (self.home / "config.yaml").write_text("sessions:\n  auto_prune: true\n")
        for sid, jid in ((S1, "j1"), (S2, "j2"), (S3, "j3")):
            self.receipt(sid, jid, 100)
        rc, out = self.run_tool()
        self.assertEqual((rc, out["native_prune"]["card_traces_without_copy"]), (0, 0))   # control
        db = SessionDB(self.db_path)
        db.append_message(S1, "user", "after the copy")
        db.close()
        rc, out = self.run_tool()
        self.assertEqual(rc, 3)
        self.assertEqual(out["native_prune"]["card_traces_without_copy"], 1)

    def test_plan_imports_no_hermes_code(self):
        self.receipt(S1, "j1", 100)
        self.rfile.write_text(json.dumps(self.receipts))
        argv = [str(SCRIPT), "--hermes-home", str(self.home), "--hermes-src", str(SRC), "--queue-dir", str(self.q),
                "--psql", str(self.bin / "psql"), "--copies-dsn-file", str(self.dsn)]
        code = ("import runpy, sys, json\nsys.argv = %r\ntry:\n    runpy.run_path(sys.argv[0], run_name='__main__')\n"
                "except SystemExit:\n    pass\nprint(json.dumps(sorted(m for m in sys.modules if m.startswith('hermes'))), "
                "file=sys.stderr)\n") % argv
        p = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=60,
                           env={**os.environ, "HERMES_HOME": str(self.home)})
        self.assertEqual(json.loads(p.stdout)["eligible"][0]["session"], S1)
        self.assertEqual(json.loads(p.stderr.strip().splitlines()[-1]), [])

    def test_native_auto_prune_flagged(self):
        (self.home / "config.yaml").write_text("sessions:\n  auto_prune: true\n  retention_days: 90\n")
        rc, out = self.run_tool(copies=False)
        self.assertEqual(rc, 3)
        self.assertTrue(out["native_prune"]["at_risk"])
        self.assertEqual(out["native_prune"]["card_traces_without_copy"], 3)

    def test_native_default_counts_when_block_missing(self):
        (self.home / "config.yaml").write_text("model: x\n")
        rc, out = self.run_tool(copies=False)
        from hermes_cli.config_defaults import DEFAULT_CONFIG
        expect = bool(DEFAULT_CONFIG["sessions"]["auto_prune"])
        self.assertEqual(out["native_prune"]["enabled"], expect)
        self.assertEqual(rc, 3 if expect else 0)

    def test_plan_writes_nothing_in_the_home(self):
        # SQLite's own -wal/-shm sidecars may appear when a reader opens a WAL database; nothing else may.
        names = lambda: sorted(p.name for p in self.home.iterdir() if not p.name.endswith(("-wal", "-shm")))
        before, digest = names(), self.digest()
        self.receipt(S1, "j1", 100)
        rc, out = self.run_tool()
        self.assertEqual([e["session"] for e in out["eligible"]], [S1])
        self.assertEqual(names(), before)
        self.assertEqual(self.digest(), digest)

    def test_output_carries_no_message_content(self):
        self.receipt(S1, "j1", 100)
        rc, out = self.run_tool()
        self.assertNotIn("brief for", json.dumps(out))


if __name__ == "__main__":
    unittest.main()
