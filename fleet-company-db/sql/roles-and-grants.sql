-- Idempotent; run by `fleet-company-db migrate` as the cluster superuser, connected to fleet_<company>,
-- after every migration. Roles (EDD §4.1 "enforced, not just a library"; INTERFACE-T2-T3.md §5):
--   fleet_owner  NOLOGIN  owns every object; only migrations run as it.
--   fleet_gate   LOGIN    T3's gate: reads what it must authorize, writes ONLY through functions.
--   fleet_worker LOGIN    job workers: claim/renew/complete only; no table access at all.
-- No login role can rewrite history; the append-only triggers refuse even the superuser unless the
-- operator deliberately disables them.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'fleet_owner') THEN CREATE ROLE fleet_owner NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'fleet_gate') THEN CREATE ROLE fleet_gate LOGIN NOINHERIT; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'fleet_worker') THEN CREATE ROLE fleet_worker LOGIN NOINHERIT; END IF;
  -- nobody may become the owner (the gate "cannot SET ROLE fleet_owner")
  IF EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid WHERE r.rolname = 'fleet_owner'
             AND m.member IN (SELECT oid FROM pg_roles WHERE rolname IN ('fleet_gate', 'fleet_worker'))) THEN
    REVOKE fleet_owner FROM fleet_gate, fleet_worker;
  END IF;
  EXECUTE format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database());
  EXECUTE format('GRANT CONNECT ON DATABASE %I TO fleet_gate, fleet_worker', current_database());
END $$;

ALTER ROLE fleet_owner  NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
ALTER ROLE fleet_gate   LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 20;
ALTER ROLE fleet_worker LOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 10;
ALTER ROLE fleet_gate   SET statement_timeout = '3s';
ALTER ROLE fleet_worker SET statement_timeout = '5s';
ALTER ROLE fleet_gate   SET idle_in_transaction_session_timeout = '10s';
ALTER ROLE fleet_worker SET idle_in_transaction_session_timeout = '10s';

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA fleet FROM PUBLIC;
GRANT USAGE ON SCHEMA fleet TO fleet_gate, fleet_worker;

REVOKE ALL ON ALL TABLES IN SCHEMA fleet FROM PUBLIC, fleet_gate, fleet_worker;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA fleet FROM PUBLIC, fleet_gate, fleet_worker;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA fleet FROM PUBLIC, fleet_gate, fleet_worker;
ALTER DEFAULT PRIVILEGES FOR ROLE fleet_owner IN SCHEMA fleet REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

GRANT SELECT ON fleet.company, fleet.principals, fleet.principal_accounts, fleet.memberships,
                fleet.service_identities, fleet.tasks, fleet.task_history
  TO fleet_gate;

GRANT EXECUTE ON FUNCTION
  fleet.update_task(text, uuid, bigint, jsonb, uuid, text, text, uuid, text),
  -- T2 amendment (INTERFACE log): refusals to audit, and the jobs half of step 2
  fleet.audit_record(text, uuid, text, text, text, text, text, jsonb),
  fleet.job_enqueue(text, text, uuid, jsonb, text, uuid, text, int),
  fleet.job_cancel(text, uuid, uuid, text)
  TO fleet_gate;

GRANT EXECUTE ON FUNCTION
  fleet.job_claim(text, text[], int),
  fleet.job_renew(uuid, bigint, text, int),
  fleet.job_complete(uuid, bigint, text, text, jsonb, text, int)
  TO fleet_worker;
