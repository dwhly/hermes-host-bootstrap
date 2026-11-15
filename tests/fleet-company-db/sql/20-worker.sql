-- Runs as fleet_worker, after 10-gate.sql.
\set ON_ERROR_STOP 1
DO $$ BEGIN PERFORM 1 FROM fleet.tasks; RAISE EXCEPTION 'TESTFAIL worker read tasks';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
DO $$ BEGIN PERFORM fleet.update_task('amforge', '00000000-0000-4000-8000-00000000a001', 4, '{"title":"w"}',
                                      '00000000-0000-4000-8000-0000000000e1', 'worker', 'req-worker-upd-01');
  RAISE EXCEPTION 'TESTFAIL worker wrote a task';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;

-- claim / renew / stale epoch / complete
DO $$ DECLARE j jsonb; r jsonb; BEGIN
  j := fleet.job_claim('w1', ARRAY['test'], 60);
  ASSERT j IS NOT NULL AND (j->>'lease_epoch')::int = 1 AND j->>'state' = 'running';
  r := fleet.job_renew((j->>'id')::uuid, 1, 'w1', 60);
  ASSERT (r->>'ok')::boolean, 'renew with the held epoch';
  r := fleet.job_renew((j->>'id')::uuid, 0, 'w1', 60);
  ASSERT NOT (r->>'ok')::boolean, 'stale epoch never renews';
  BEGIN
    PERFORM fleet.job_complete((j->>'id')::uuid, 0, 'w1', 'succeeded', '{}', NULL, 0);
    RAISE EXCEPTION 'TESTFAIL stale epoch completed';
  EXCEPTION WHEN SQLSTATE 'FG409' THEN NULL; END;
  r := fleet.job_complete((j->>'id')::uuid, 1, 'w1', 'failed', NULL, 'boom', 0);
  ASSERT r->>'state' = 'queued', 'a failure with attempts left requeues';
  j := fleet.job_claim('w1', ARRAY['test'], 60);
  ASSERT (j->>'attempts')::int = 2 AND (j->>'lease_epoch')::int = 2;
  r := fleet.job_complete((j->>'id')::uuid, 2, 'w1', 'succeeded', '{"ok":true}', NULL, 0);
  ASSERT r->>'state' = 'succeeded';
END $$;
SELECT 'PASS:worker-basic' AS result;
