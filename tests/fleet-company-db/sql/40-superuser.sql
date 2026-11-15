-- Runs as the superuser (operator): even it can't rewrite history through normal statements.
\set ON_ERROR_STOP 1
DO $$ BEGIN UPDATE fleet.task_history SET new_value = '"x"'; RAISE EXCEPTION 'TESTFAIL su rewrote history';
EXCEPTION WHEN SQLSTATE 'FG403' THEN NULL; END $$;
DO $$ BEGIN TRUNCATE fleet.audit; RAISE EXCEPTION 'TESTFAIL su truncated audit';
EXCEPTION WHEN SQLSTATE 'FG403' THEN NULL; END $$;
DO $$ BEGIN DELETE FROM fleet.tasks; RAISE EXCEPTION 'TESTFAIL su deleted a task';
EXCEPTION WHEN SQLSTATE 'FG403' THEN NULL; END $$;
DO $$ BEGIN DELETE FROM fleet.jobs; RAISE EXCEPTION 'TESTFAIL su deleted a job';
EXCEPTION WHEN SQLSTATE 'FG403' THEN NULL; END $$;
DO $$ BEGIN DELETE FROM fleet.memberships; RAISE EXCEPTION 'TESTFAIL su deleted a membership';
EXCEPTION WHEN SQLSTATE 'FG403' THEN NULL; END $$;
DO $$ BEGIN UPDATE fleet.company SET id = 'btp'; RAISE EXCEPTION 'TESTFAIL company changed';
EXCEPTION WHEN SQLSTATE 'FG403' THEN NULL; END $$;
DO $$ BEGIN INSERT INTO fleet.company (id) VALUES ('btp'); RAISE EXCEPTION 'TESTFAIL second company';
EXCEPTION WHEN unique_violation THEN NULL; END $$;
DO $$ BEGIN
  ASSERT (SELECT state FROM fleet.jobs WHERE kind = 'once') = 'dead', 'dead job kept';
  ASSERT (SELECT count(*) FROM fleet.job_events WHERE event = 'dead') = 1;
  ASSERT (SELECT actor_principal IS NULL AND detail->>'claimed_actor' = '00000000-0000-4000-8000-0000000000ff'
          FROM fleet.audit WHERE request_id = 'req-denied-00001'), 'unknown actor kept only as a claim';
  ASSERT (SELECT count(*) FROM fleet.audit WHERE action = 'task.update' AND outcome = 'ok') = 3;
  ASSERT NOT has_table_privilege('fleet_gate', 'fleet.tasks', 'UPDATE');
  ASSERT NOT has_table_privilege('fleet_gate', 'fleet.task_history', 'INSERT');
  ASSERT NOT has_table_privilege('fleet_gate', 'fleet.tasks', 'TRUNCATE');
  ASSERT NOT has_function_privilege('public', 'fleet.update_task(text,uuid,bigint,jsonb,uuid,text,text,uuid,text)', 'EXECUTE');
  ASSERT NOT has_function_privilege('fleet_worker', 'fleet.update_task(text,uuid,bigint,jsonb,uuid,text,text,uuid,text)', 'EXECUTE');
  ASSERT NOT has_function_privilege('fleet_gate', 'fleet.seed_task(uuid,text,text,text,uuid,text)', 'EXECUTE');
  ASSERT NOT has_schema_privilege('fleet_gate', 'fleet', 'CREATE');
  ASSERT NOT pg_has_role('fleet_gate', 'fleet_owner', 'MEMBER');
  ASSERT (SELECT NOT rolcanlogin FROM pg_roles WHERE rolname = 'fleet_owner');
  ASSERT (SELECT NOT rolsuper AND NOT rolbypassrls FROM pg_roles WHERE rolname = 'fleet_gate');
  ASSERT (SELECT id FROM fleet.company) = 'amforge';
END $$;
SELECT 'PASS:superuser' AS result;
