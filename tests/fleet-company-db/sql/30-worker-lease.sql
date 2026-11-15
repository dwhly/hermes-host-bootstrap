-- Runs as fleet_worker: expired-lease recovery, the stale worker fenced out, dead after max attempts.
\set ON_ERROR_STOP 1
SET statement_timeout = '30s';  -- the role default (5s) is a guard; this test sleeps past a lease
SELECT fleet.job_claim('w-old', ARRAY['lease'], 10) IS NOT NULL AS claimed_lease;
SELECT fleet.job_claim('w-old', ARRAY['once'], 10) IS NOT NULL AS claimed_once;
SELECT pg_sleep(11);
DO $$ DECLARE j jsonb; BEGIN
  j := fleet.job_claim('w-new', ARRAY['lease'], 60);
  ASSERT j IS NOT NULL AND j->>'lease_owner' = 'w-new' AND (j->>'lease_epoch')::int = 2, 'expired lease reclaimed';
  BEGIN
    PERFORM fleet.job_complete((j->>'id')::uuid, 1, 'w-old', 'succeeded', '{}', NULL, 0);
    RAISE EXCEPTION 'TESTFAIL stale worker completed after reclaim';
  EXCEPTION WHEN SQLSTATE 'FG409' THEN NULL; END;
  PERFORM fleet.job_complete((j->>'id')::uuid, 2, 'w-new', 'succeeded', '{}', NULL, 0);
  -- the max_attempts=1 job expired: never reclaimed, moved to dead (kept)
  ASSERT fleet.job_claim('w-new', ARRAY['once'], 60) IS NULL, 'no retry past max attempts';
END $$;
SELECT 'PASS:worker-lease' AS result;
