-- Runs as the superuser, switching roles to play gate and worker (review r1 [1], [5], [6]):
--   * an expired lease can't complete, even by its own worker
--   * a cancel-requested job whose worker died ends 'cancelled' (not stranded 'running')
--   * the write fence: while closed, every mutation refuses with FG503 and reads continue; reopening restores writes
\set ON_ERROR_STOP 1
SET statement_timeout = '30s';
\set ed '\'00000000-0000-4000-8000-0000000000e1\''
\set task '\'00000000-0000-4000-8000-00000000a001\''

SET ROLE fleet_worker;
SELECT (fleet.job_claim('w-r1', ARRAY['exp1'], 10))->>'id' AS exp1_id \gset
SELECT (fleet.job_claim('w-r1', ARRAY['canc'], 10))->>'id' AS canc_id \gset
SELECT set_config('fcdb.exp1', :'exp1_id', false) IS NOT NULL, set_config('fcdb.canc', :'canc_id', false) IS NOT NULL;
RESET ROLE;
SET ROLE fleet_gate;
SELECT (fleet.job_cancel('amforge', :'canc_id', :ed, 'fleet-gate'))->>'state' AS cancel_while_running;
RESET ROLE;
SELECT pg_sleep(11);
SET ROLE fleet_worker;
DO $$ BEGIN
  PERFORM fleet.job_complete(current_setting('fcdb.exp1')::uuid, 1, 'w-r1', 'succeeded');
  RAISE EXCEPTION 'TESTFAIL completed after its lease expired';
EXCEPTION WHEN SQLSTATE 'FG409' THEN NULL; END $$;
SELECT fleet.job_claim('w-sweep', ARRAY['canc'], 10) IS NULL AS nothing_to_claim;   -- runs the recovery sweep
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT state FROM fleet.jobs WHERE id = current_setting('fcdb.canc')::uuid) = 'cancelled',
         'cancel-requested job with an expired lease ends cancelled';
  ASSERT EXISTS (SELECT 1 FROM fleet.job_events WHERE job_id = current_setting('fcdb.canc')::uuid AND event = 'cancelled'),
         'with an event';
END $$;

-- the write fence
SELECT fleet.set_write_fence(true, 'test: backups failing');
SET ROLE fleet_gate;
DO $$ BEGIN
  PERFORM fleet.update_task('amforge', '00000000-0000-4000-8000-00000000a001',
          (SELECT version FROM fleet.tasks WHERE id = '00000000-0000-4000-8000-00000000a001'),
          '{"title":"while closed"}', '00000000-0000-4000-8000-0000000000e1', 'fleet-gate', 'req-fence-00001');
  RAISE EXCEPTION 'TESTFAIL write while the record is closed';
EXCEPTION WHEN SQLSTATE 'FG503' THEN NULL; END $$;
DO $$ BEGIN
  PERFORM fleet.job_enqueue('amforge', 'test', NULL, '{}', 'idem-job-fence-0001', '00000000-0000-4000-8000-0000000000e1', 'fleet-gate', 3);
  RAISE EXCEPTION 'TESTFAIL enqueue while closed';
EXCEPTION WHEN SQLSTATE 'FG503' THEN NULL; END $$;
SELECT count(*) = 1 AS reads_continue FROM fleet.tasks WHERE id = :task;
RESET ROLE;
SET ROLE fleet_worker;
DO $$ BEGIN
  PERFORM fleet.job_claim('w-fence', ARRAY['test'], 30);
  RAISE EXCEPTION 'TESTFAIL claim while closed';
EXCEPTION WHEN SQLSTATE 'FG503' THEN NULL; END $$;
RESET ROLE;
SELECT fleet.set_write_fence(false, 'test: backups ok');
SET ROLE fleet_gate;
SELECT (fleet.update_task('amforge', :task, (SELECT version FROM fleet.tasks WHERE id = :task),
        '{"title":"after reopen"}', :ed, 'fleet-gate', 'req-fence-00002')) IS NOT NULL AS write_after_reopen;
RESET ROLE;
DO $$ BEGIN
  ASSERT (SELECT count(*) FROM fleet.audit WHERE action IN ('record.close', 'record.open')) = 2, 'fence changes audited';
  ASSERT (SELECT title FROM fleet.tasks WHERE id = '00000000-0000-4000-8000-00000000a001') = 'after reopen', 'reopened';
END $$;
SELECT 'PASS:recovery-and-fence' AS result;
