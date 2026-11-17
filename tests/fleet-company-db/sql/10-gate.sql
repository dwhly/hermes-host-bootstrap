-- Runs as fleet_gate after the seed. Every block asserts; any failure stops psql and the driver fails.
-- Ids: editor ...e1, viewer ...b1, revoked editor ...c1, task ...a001 (fixtures/seed-proto.sql).
\set ON_ERROR_STOP 1
\set ed '''00000000-0000-4000-8000-0000000000e1'''

-- the gate reads what it authorizes
DO $$ BEGIN
  ASSERT (SELECT id FROM fleet.company) = 'amforge';
  ASSERT (SELECT principal_id FROM fleet.principal_accounts WHERE provider = 'tailscale' AND subject = 'editor@example.invalid')
         = '00000000-0000-4000-8000-0000000000e1';
  ASSERT NOT EXISTS (SELECT 1 FROM fleet.memberships WHERE principal_id = '00000000-0000-4000-8000-0000000000c1' AND revoked_at IS NULL);
  ASSERT (SELECT version FROM fleet.tasks WHERE id = '00000000-0000-4000-8000-00000000a001') = 1;
END $$;

-- refusals: other company, viewer, revoked member, unknown actor
DO $$ BEGIN
  PERFORM fleet.update_task('btp', '00000000-0000-4000-8000-00000000a001', 1, '{"title":"x"}', '00000000-0000-4000-8000-0000000000e1', 'fleet-gate', 'req-co-000001');
  RAISE EXCEPTION 'TESTFAIL other company accepted';
EXCEPTION WHEN SQLSTATE 'FG001' THEN NULL; END $$;
DO $$ BEGIN
  PERFORM fleet.update_task('amforge', '00000000-0000-4000-8000-00000000a001', 1, '{"title":"x"}', '00000000-0000-4000-8000-0000000000b1', 'fleet-gate', 'req-vw-000001');
  RAISE EXCEPTION 'TESTFAIL viewer wrote';
EXCEPTION WHEN SQLSTATE 'FG403' THEN NULL; END $$;
DO $$ BEGIN
  PERFORM fleet.update_task('amforge', '00000000-0000-4000-8000-00000000a001', 1, '{"title":"x"}', '00000000-0000-4000-8000-0000000000c1', 'fleet-gate', 'req-rv-000001');
  RAISE EXCEPTION 'TESTFAIL revoked member wrote';
EXCEPTION WHEN SQLSTATE 'FG403' THEN NULL; END $$;
DO $$ BEGIN
  PERFORM fleet.update_task('amforge', '00000000-0000-4000-8000-00000000a001', 1, '{"title":"x"}', gen_random_uuid(), 'fleet-gate', 'req-uk-000001');
  RAISE EXCEPTION 'TESTFAIL unknown actor wrote';
EXCEPTION WHEN SQLSTATE 'FG403' THEN NULL; END $$;

-- per-field CAS, stale refusal, replay, validation
DO $$ DECLARE v bigint; BEGIN
  v := fleet.update_task('amforge', '00000000-0000-4000-8000-00000000a001', 1, '{"title":"Renamed"}', '00000000-0000-4000-8000-0000000000e1', 'fleet-gate', 'req-upd-000001');
  ASSERT v = 2, 'first update -> 2';
  BEGIN
    PERFORM fleet.update_task('amforge', '00000000-0000-4000-8000-00000000a001', 1, '{"title":"Stale"}', '00000000-0000-4000-8000-0000000000e1', 'fleet-gate', 'req-upd-000002');
    RAISE EXCEPTION 'TESTFAIL stale title accepted';
  EXCEPTION WHEN SQLSTATE 'FG409' THEN NULL; END;
  -- status unchanged since base 1: allowed although title moved on
  v := fleet.update_task('amforge', '00000000-0000-4000-8000-00000000a001', 1, '{"status":"doing"}', '00000000-0000-4000-8000-0000000000e1', 'fleet-gate', 'req-upd-000003');
  ASSERT v = 3, 'per-field CAS';
  BEGIN
    PERFORM fleet.update_task('amforge', '00000000-0000-4000-8000-00000000a001', 3, '{"status":"doing"}', '00000000-0000-4000-8000-0000000000e1', 'fleet-gate', 'req-upd-000003');
    RAISE EXCEPTION 'TESTFAIL replay applied';
  EXCEPTION WHEN SQLSTATE 'FG409' THEN NULL; END;
  v := fleet.update_task('amforge', '00000000-0000-4000-8000-00000000a001', 3, '{"due":"2026-12-01"}', '00000000-0000-4000-8000-0000000000e1', 'fleet-gate', 'req-upd-000004');
  ASSERT v = 4;
  ASSERT (SELECT title = 'Renamed' AND status = 'doing' AND due = '2026-12-01' AND version = 4
          FROM fleet.tasks WHERE id = '00000000-0000-4000-8000-00000000a001');
  ASSERT (SELECT count(*) FROM fleet.task_history WHERE task_id = '00000000-0000-4000-8000-00000000a001') = 7, 'seed 4 + 3 changes';
  ASSERT (SELECT actor_principal FROM fleet.task_history WHERE request_id = 'req-upd-000003') = '00000000-0000-4000-8000-0000000000e1';
END $$;
DO $$ BEGIN
  PERFORM fleet.update_task('amforge', '00000000-0000-4000-8000-00000000a001', 4, '{"version":"9"}', '00000000-0000-4000-8000-0000000000e1', 'fleet-gate', 'req-bad-000001');
  RAISE EXCEPTION 'TESTFAIL unknown field';
EXCEPTION WHEN SQLSTATE 'FG400' THEN NULL; END $$;
DO $$ BEGIN
  PERFORM fleet.update_task('amforge', '00000000-0000-4000-8000-00000000a001', 4, '{"due":"soon"}', '00000000-0000-4000-8000-0000000000e1', 'fleet-gate', 'req-bad-000002');
  RAISE EXCEPTION 'TESTFAIL bad date';
EXCEPTION WHEN SQLSTATE 'FG400' THEN NULL; END $$;
DO $$ BEGIN
  PERFORM fleet.update_task('amforge', gen_random_uuid(), 1, '{"title":"x"}', '00000000-0000-4000-8000-0000000000e1', 'fleet-gate', 'req-nf-000001');
  RAISE EXCEPTION 'TESTFAIL missing task';
EXCEPTION WHEN SQLSTATE 'FG404' THEN NULL; END $$;

-- the gate can never write tables directly, read audit, rewrite history or act as a worker/operator
DO $$ BEGIN UPDATE fleet.tasks SET title = 'direct'; RAISE EXCEPTION 'TESTFAIL direct update';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
DO $$ BEGIN INSERT INTO fleet.memberships (principal_id, role) VALUES ('00000000-0000-4000-8000-0000000000b1', 'editor');
  RAISE EXCEPTION 'TESTFAIL gate granted a membership';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
DO $$ BEGIN DELETE FROM fleet.task_history; RAISE EXCEPTION 'TESTFAIL history delete';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
DO $$ BEGIN PERFORM 1 FROM fleet.audit; RAISE EXCEPTION 'TESTFAIL gate read audit';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
DO $$ BEGIN PERFORM fleet.job_claim('gate', ARRAY['test'], 60); RAISE EXCEPTION 'TESTFAIL gate claimed a job';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
DO $$ BEGIN PERFORM fleet.seed_task(gen_random_uuid(), 't', 's', '', '00000000-0000-4000-8000-0000000000e1', 'req-seed-0001');
  RAISE EXCEPTION 'TESTFAIL gate seeded a task';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;
DO $$ BEGIN SET ROLE fleet_owner; RAISE EXCEPTION 'TESTFAIL gate became owner';
EXCEPTION WHEN insufficient_privilege THEN NULL; END $$;

-- refusals are recorded through audit_record (an unknown actor is kept only as a claim)
SELECT fleet.audit_record('amforge', '00000000-0000-4000-8000-0000000000ff', 'fleet-gate', 'req-denied-00001', 'task.read',
                          '00000000-0000-4000-8000-00000000a001', 'denied', '{"why":"forged header"}') IS NOT NULL;

-- jobs: idempotent enqueue (a viewer can't enqueue)
DO $$ DECLARE a jsonb; b jsonb; BEGIN
  a := fleet.job_enqueue('amforge', 'test', '00000000-0000-4000-8000-00000000a001', '{"n":1}', 'idem-job-aaaa-0001', '00000000-0000-4000-8000-0000000000e1', 'fleet-gate', 3);
  b := fleet.job_enqueue('amforge', 'test', '00000000-0000-4000-8000-00000000a001', '{"n":1}', 'idem-job-aaaa-0001', '00000000-0000-4000-8000-0000000000e1', 'fleet-gate', 3);
  ASSERT a->>'id' = b->>'id', 'same key, same job';
  BEGIN
    PERFORM fleet.job_enqueue('amforge', 'test', NULL, '{"n":2}', 'idem-job-aaaa-0001', '00000000-0000-4000-8000-0000000000e1', 'fleet-gate', 3);
    RAISE EXCEPTION 'TESTFAIL key reused with other payload';
  EXCEPTION WHEN SQLSTATE 'FG409' THEN NULL; END;
  BEGIN
    PERFORM fleet.job_enqueue('amforge', 'test', NULL, '{}', 'idem-job-vvvv-0001', '00000000-0000-4000-8000-0000000000b1', 'fleet-gate', 3);
    RAISE EXCEPTION 'TESTFAIL viewer enqueued';
  EXCEPTION WHEN SQLSTATE 'FG403' THEN NULL; END;
END $$;
SELECT fleet.job_enqueue('amforge', 'test2', NULL, '{"n":2}', 'idem-job-bbbb-0002', :ed, 'fleet-gate', 3) IS NOT NULL;
SELECT fleet.job_enqueue('amforge', 'lease', NULL, '{"n":3}', 'idem-job-cccc-0003', :ed, 'fleet-gate', 2) IS NOT NULL;
SELECT fleet.job_enqueue('amforge', 'once',  NULL, '{"n":4}', 'idem-job-dddd-0004', :ed, 'fleet-gate', 1) IS NOT NULL;
SELECT fleet.job_enqueue('amforge', 'skip',  NULL, '{"n":5}', 'idem-job-eeee-0005', :ed, 'fleet-gate', 3) IS NOT NULL;
SELECT fleet.job_enqueue('amforge', 'skip',  NULL, '{"n":6}', 'idem-job-ffff-0006', :ed, 'fleet-gate', 3) IS NOT NULL;
SELECT fleet.job_enqueue('amforge', 'canc',  NULL, '{"n":7}', 'idem-job-gggg-0007', :ed, 'fleet-gate', 3) IS NOT NULL;
SELECT fleet.job_enqueue('amforge', 'exp1',  NULL, '{"n":8}', 'idem-job-hhhh-0008', :ed, 'fleet-gate', 3) IS NOT NULL;

-- review r1 [7]: a replay must be the same request (max_attempts too), and input is bounded
DO $$ BEGIN
  PERFORM fleet.job_enqueue('amforge', 'test2', NULL, '{"n":2}', 'idem-job-bbbb-0002', '00000000-0000-4000-8000-0000000000e1', 'fleet-gate', 9);
  RAISE EXCEPTION 'TESTFAIL key replayed with other max_attempts';
EXCEPTION WHEN SQLSTATE 'FG409' THEN NULL; END $$;
DO $$ BEGIN
  PERFORM fleet.job_enqueue('amforge', 'test', NULL, '{}', 'short', '00000000-0000-4000-8000-0000000000e1', 'fleet-gate', 3);
  RAISE EXCEPTION 'TESTFAIL short idempotency key';
EXCEPTION WHEN SQLSTATE 'FG400' THEN NULL; END $$;
DO $$ BEGIN
  PERFORM fleet.job_enqueue('amforge', 'test', NULL, '{}', 'idem-job-big-0001', '00000000-0000-4000-8000-0000000000e1', 'fleet-gate', 500);
  RAISE EXCEPTION 'TESTFAIL max_attempts 500';
EXCEPTION WHEN SQLSTATE 'FG400' THEN NULL; END $$;
-- review r1 [8]: due is exactly YYYY-MM-DD and a real finite date; lengths refused with FG400, not 23514
DO $$ DECLARE d text; BEGIN
  FOREACH d IN ARRAY ARRAY['infinity', 'today', '2026-02-30', '2026-1-5', '20261105'] LOOP
    BEGIN
      PERFORM fleet.update_task('amforge', '00000000-0000-4000-8000-00000000a001', 4, jsonb_build_object('due', d),
                                '00000000-0000-4000-8000-0000000000e1', 'fleet-gate', 'req-due-' || md5(d));
      RAISE EXCEPTION 'TESTFAIL due % accepted', d;
    EXCEPTION WHEN SQLSTATE 'FG400' THEN NULL; END;
  END LOOP;
END $$;
DO $$ BEGIN
  PERFORM fleet.update_task('amforge', '00000000-0000-4000-8000-00000000a001', 4, jsonb_build_object('title', repeat('x', 501)),
                            '00000000-0000-4000-8000-0000000000e1', 'fleet-gate', 'req-long-000001');
  RAISE EXCEPTION 'TESTFAIL 501-char title';
EXCEPTION WHEN SQLSTATE 'FG400' THEN NULL; END $$;
-- review r1 [3]: the gate can record refusals only, never a success
DO $$ BEGIN
  PERFORM fleet.audit_record('amforge', '00000000-0000-4000-8000-0000000000e1', 'fleet-gate', 'req-forge-00001',
                             'task.update', '00000000-0000-4000-8000-00000000a001', 'ok', '{}');
  RAISE EXCEPTION 'TESTFAIL gate forged a success';
EXCEPTION WHEN SQLSTATE 'FG400' THEN NULL; END $$;
SELECT 'PASS:gate' AS result;
