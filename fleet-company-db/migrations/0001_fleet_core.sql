-- 0001_fleet_core: the per-company record for EDD-fleet-architecture §9 step 2.
-- One disposable test task per company + the jobs table, behind T3's gate.
-- Interface: /root/work/fleet-build/arch-tracks/INTERFACE-T2-T3.md (T3 proposal, T2 amendments in its log),
-- mirrored in fleet-company-db/INTERFACE.md. Expand/contract only: never edit this file once it is applied
-- anywhere; add 0002_... instead. The runner applies it in one transaction as role fleet_owner.
--
-- Error contract (SQLSTATE): FG001 company mismatch, FG400 invalid input, FG403 forbidden (no live editor
-- membership, or an append-only violation), FG404 not found, FG409 conflict (stale version, stale worker,
-- expired lease, duplicate request, idempotency key reused), FG503 record closed for writes (backups failing).
--
-- No unarchived writes (fail closed, EDD D4 RPO 5 min): every mutating function first calls
-- fleet._assert_writable(), which refuses while (a) the health probe has closed fleet.write_fence, or
-- (b) the archiver's latest event is a failure and its last success is over 120 s old, or (c) archiving is off.

CREATE SCHEMA fleet;

-- One row: the company this database belongs to.
CREATE TABLE fleet.company (
  id         text PRIMARY KEY CHECK (id ~ '^[a-z][a-z0-9-]{1,30}$'),
  singleton  boolean NOT NULL DEFAULT true UNIQUE CHECK (singleton),
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- identity (the company's own map, EDD §4.1)
CREATE TABLE fleet.principals (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name text NOT NULL CHECK (length(display_name) BETWEEN 1 AND 200),
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- Explicit rows only; never inferred from email names.
CREATE TABLE fleet.principal_accounts (
  provider     text NOT NULL CHECK (provider IN ('tailscale', 'cloudflare_access')),
  subject      text NOT NULL CHECK (length(subject) BETWEEN 1 AND 320),
  principal_id uuid NOT NULL REFERENCES fleet.principals(id),
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (provider, subject)
);

-- Every grant is its own row and is never overwritten: revoke sets revoked_at; a re-grant adds a new row.
-- The live membership is the one row with revoked_at IS NULL (at most one per principal).
CREATE TABLE fleet.memberships (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  principal_id uuid NOT NULL REFERENCES fleet.principals(id),
  role         text NOT NULL CHECK (role IN ('viewer', 'editor')),
  granted_at   timestamptz NOT NULL DEFAULT now(),
  revoked_at   timestamptz,
  CHECK (revoked_at IS NULL OR revoked_at >= granted_at)
);
CREATE UNIQUE INDEX memberships_one_live ON fleet.memberships (principal_id) WHERE revoked_at IS NULL;

-- Read-only services with no actor (EDD §4.1). Only the token's hash is stored.
CREATE TABLE fleet.service_identities (
  name         text PRIMARY KEY CHECK (name ~ '^[a-z][a-z0-9_.-]{1,60}$'),
  token_sha256 bytea NOT NULL UNIQUE CHECK (length(token_sha256) = 32),
  read_scopes  text[] NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  revoked_at   timestamptz
);

-- ---------------------------------------------------------------- the disposable test task + history
CREATE TABLE fleet.tasks (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title          text NOT NULL CHECK (length(title) BETWEEN 1 AND 500),
  status         text NOT NULL CHECK (length(status) BETWEEN 1 AND 40),
  body           text NOT NULL DEFAULT '' CHECK (length(body) <= 100000),
  due            date,
  is_test        boolean NOT NULL DEFAULT true,
  version        bigint NOT NULL DEFAULT 1 CHECK (version >= 1),
  -- field -> the task version at which that field last changed (per-field compare-and-set)
  field_versions jsonb NOT NULL DEFAULT '{"title":1,"status":1,"body":1,"due":1}',
  created_at     timestamptz NOT NULL DEFAULT now(),
  created_by     uuid NOT NULL REFERENCES fleet.principals(id),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  updated_by     uuid NOT NULL REFERENCES fleet.principals(id)
);

CREATE TABLE fleet.task_history (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  task_id           uuid NOT NULL REFERENCES fleet.tasks(id),
  version           bigint NOT NULL,
  field             text NOT NULL,
  old_value         jsonb,
  new_value         jsonb,
  actor_principal   uuid NOT NULL REFERENCES fleet.principals(id),
  executing_service text NOT NULL,
  request_id        text NOT NULL,
  job_id            uuid,
  session_id        text,
  at                timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX task_history_task ON fleet.task_history (task_id, version);

-- One row per applied write request: a replay of the same (task, request_id) is refused, never re-applied.
CREATE TABLE fleet.task_requests (
  task_id     uuid NOT NULL REFERENCES fleet.tasks(id),
  request_id  text NOT NULL CHECK (length(request_id) BETWEEN 8 AND 128),
  new_version bigint NOT NULL,
  at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (task_id, request_id)
);

CREATE TABLE fleet.audit (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at                timestamptz NOT NULL DEFAULT now(),
  -- 'db': written by the database's own mutation functions (authoritative, incl. every success);
  -- 'gate': a refusal the gate reported through audit_record (never a success).
  origin            text NOT NULL DEFAULT 'db' CHECK (origin IN ('db', 'gate')),
  actor_principal   uuid,                 -- NULL when no identity was established
  executing_service text NOT NULL,
  request_id        text NOT NULL,
  action            text NOT NULL,
  object            text,
  outcome           text NOT NULL CHECK (outcome IN ('ok', 'denied', 'conflict', 'error')),
  detail            jsonb NOT NULL DEFAULT '{}',
  CHECK (origin = 'db' OR outcome <> 'ok')
);

-- One row. Closed by the health probe when WAL stops reaching the bucket; reopened when it does again.
CREATE TABLE fleet.write_fence (
  singleton  boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  closed     boolean NOT NULL DEFAULT false,
  reason     text NOT NULL DEFAULT '',
  changed_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO fleet.write_fence DEFAULT VALUES;

-- ---------------------------------------------------------------- jobs (EDD §4.2)
CREATE TABLE fleet.jobs (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind             text NOT NULL CHECK (kind ~ '^[a-z][a-z0-9_.-]{1,40}$'),
  task_id          uuid REFERENCES fleet.tasks(id),
  payload          jsonb NOT NULL DEFAULT '{}',
  idempotency_key  text NOT NULL UNIQUE CHECK (length(idempotency_key) BETWEEN 8 AND 200),
  state            text NOT NULL DEFAULT 'queued'
                   CHECK (state IN ('queued', 'running', 'succeeded', 'failed', 'cancelled', 'dead')),
  attempts         int NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  max_attempts     int NOT NULL DEFAULT 3 CHECK (max_attempts BETWEEN 1 AND 20),
  lease_owner      text,
  lease_epoch      bigint NOT NULL DEFAULT 0,
  lease_expires_at timestamptz,
  not_before       timestamptz NOT NULL DEFAULT now(),
  cancel_requested boolean NOT NULL DEFAULT false,
  result           jsonb,
  last_error       text,
  created_by       uuid NOT NULL REFERENCES fleet.principals(id),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CHECK ((state = 'running') = (lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL))
);
CREATE INDEX jobs_claimable ON fleet.jobs (not_before) WHERE state = 'queued';
CREATE INDEX jobs_running_lease ON fleet.jobs (lease_expires_at) WHERE state = 'running';

CREATE TABLE fleet.job_events (
  id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  job_id uuid NOT NULL REFERENCES fleet.jobs(id),
  at     timestamptz NOT NULL DEFAULT now(),
  event  text NOT NULL,
  epoch  bigint NOT NULL,
  worker text,
  detail jsonb NOT NULL DEFAULT '{}'
);
CREATE INDEX job_events_job ON fleet.job_events (job_id, id);

-- ---------------------------------------------------------------- append-only / never-delete guards
CREATE FUNCTION fleet.refuse_rewrite() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'fleet: % on %.% is not allowed (append-only / never delete)', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME
    USING ERRCODE = 'FG403';
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['task_history', 'audit', 'job_events', 'task_requests'] LOOP
    EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON fleet.%I FOR EACH ROW EXECUTE FUNCTION fleet.refuse_rewrite()', t || '_append_only', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['company', 'principals', 'principal_accounts', 'memberships', 'service_identities', 'tasks', 'jobs', 'write_fence'] LOOP
    EXECUTE format('CREATE TRIGGER %I BEFORE DELETE ON fleet.%I FOR EACH ROW EXECUTE FUNCTION fleet.refuse_rewrite()', t || '_no_delete', t);
  END LOOP;
  FOREACH t IN ARRAY ARRAY['task_history', 'audit', 'job_events', 'task_requests', 'company', 'principals',
                           'principal_accounts', 'memberships', 'service_identities', 'tasks', 'jobs', 'write_fence'] LOOP
    EXECUTE format('CREATE TRIGGER %I BEFORE TRUNCATE ON fleet.%I FOR EACH STATEMENT EXECUTE FUNCTION fleet.refuse_rewrite()', t || '_no_truncate', t);
  END LOOP;
END $$;
CREATE TRIGGER company_frozen BEFORE UPDATE ON fleet.company FOR EACH ROW EXECUTE FUNCTION fleet.refuse_rewrite();

-- ---------------------------------------------------------------- helpers
CREATE FUNCTION fleet._require_company(p_company text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_company IS NULL OR p_company IS DISTINCT FROM (SELECT id FROM fleet.company) THEN
    RAISE EXCEPTION 'fleet: this database belongs to another company' USING ERRCODE = 'FG001';
  END IF;
END $$;

CREATE FUNCTION fleet._require_editor(p_actor uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_actor IS NULL OR NOT EXISTS (
       SELECT 1 FROM fleet.memberships WHERE principal_id = p_actor AND revoked_at IS NULL AND role = 'editor') THEN
    RAISE EXCEPTION 'fleet: actor has no live editor membership' USING ERRCODE = 'FG403';
  END IF;
END $$;

CREATE FUNCTION fleet._require_principal(p_actor uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_actor IS NULL OR NOT EXISTS (SELECT 1 FROM fleet.principals WHERE id = p_actor) THEN
    RAISE EXCEPTION 'fleet: unknown principal' USING ERRCODE = 'FG400';
  END IF;
END $$;

CREATE FUNCTION fleet._assert_writable() RETURNS void LANGUAGE plpgsql AS $$
DECLARE f fleet.write_fence; a record;
BEGIN
  -- (review r2 [1]) Every check must see the present, not the transaction's start. Only READ COMMITTED takes
  -- a fresh snapshot per statement; the archiver statistics are cached per transaction, so clear that cache;
  -- and a transaction older than 30 s can no longer be admitted (bounds what an outage-spanning one commits).
  IF pg_catalog.current_setting('transaction_isolation') <> 'read committed' THEN
    RAISE EXCEPTION 'fleet: mutations must run in READ COMMITTED' USING ERRCODE = 'FG400';
  END IF;
  IF pg_catalog.clock_timestamp() - pg_catalog.transaction_timestamp() > interval '30 seconds' THEN
    RAISE EXCEPTION 'fleet: record closed for writes: transaction older than 30 s' USING ERRCODE = 'FG503';
  END IF;
  PERFORM pg_catalog.pg_stat_clear_snapshot();
  IF pg_catalog.current_setting('archive_mode') = 'off' THEN
    RAISE EXCEPTION 'fleet: record closed for writes: WAL archiving is off' USING ERRCODE = 'FG503';
  END IF;
  SELECT * INTO f FROM fleet.write_fence;
  IF f.closed THEN
    RAISE EXCEPTION 'fleet: record closed for writes: %', f.reason USING ERRCODE = 'FG503';
  END IF;
  SELECT s.last_archived_time, s.last_failed_time INTO a FROM pg_catalog.pg_stat_archiver s;
  IF a.last_failed_time IS NOT NULL AND a.last_failed_time > coalesce(a.last_archived_time, '-infinity')
     AND coalesce(a.last_archived_time, pg_catalog.pg_postmaster_start_time())
         < pg_catalog.clock_timestamp() - interval '120 seconds' THEN
    RAISE EXCEPTION 'fleet: record closed for writes: WAL archiving failing (last success %)', a.last_archived_time
      USING ERRCODE = 'FG503';
  END IF;
END $$;

-- Operator-only (the health probe, as the superuser): open/close the fence; every change is audited.
CREATE FUNCTION fleet.set_write_fence(p_closed boolean, p_reason text) RETURNS void
LANGUAGE plpgsql SET search_path = fleet, pg_temp AS $$
DECLARE f fleet.write_fence;
BEGIN
  SELECT * INTO f FROM fleet.write_fence FOR UPDATE;
  IF f.closed IS DISTINCT FROM p_closed THEN
    UPDATE fleet.write_fence SET closed = p_closed, reason = coalesce(p_reason, ''), changed_at = now();
    INSERT INTO fleet.audit (executing_service, request_id, action, object, outcome, detail)
    VALUES ('fleet-company-db.health', 'fence-' || pg_catalog.txid_current(), CASE WHEN p_closed THEN 'record.close' ELSE 'record.open' END,
            'write_fence', 'ok', jsonb_build_object('reason', coalesce(p_reason, '')));
  END IF;
END $$;

-- ---------------------------------------------------------------- the one task write path
CREATE FUNCTION fleet.update_task(
  p_company text, p_task uuid, p_base_version bigint, p_changes jsonb,
  p_actor uuid, p_service text, p_request_id text,
  p_job_id uuid DEFAULT NULL, p_session_id text DEFAULT NULL
) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = fleet, pg_temp AS $$
DECLARE
  t fleet.tasks; f text; newv bigint; oldval jsonb; newval jsonb; stale jsonb := '{}';
BEGIN
  PERFORM fleet._require_company(p_company);
  PERFORM fleet._require_editor(p_actor);
  PERFORM fleet._assert_writable();
  IF p_service IS NULL OR p_service !~ '^[a-z][a-z0-9_.-]{1,60}$' THEN
    RAISE EXCEPTION 'fleet: executing service required' USING ERRCODE = 'FG400';
  END IF;
  IF p_request_id IS NULL OR length(p_request_id) NOT BETWEEN 8 AND 128 THEN
    RAISE EXCEPTION 'fleet: request_id must be 8..128 chars' USING ERRCODE = 'FG400';
  END IF;
  IF p_session_id IS NOT NULL AND length(p_session_id) > 200 THEN
    RAISE EXCEPTION 'fleet: session_id longer than 200 chars' USING ERRCODE = 'FG400';
  END IF;
  IF p_base_version IS NULL OR p_base_version < 1 THEN
    RAISE EXCEPTION 'fleet: base version required' USING ERRCODE = 'FG400';
  END IF;
  IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' OR p_changes = '{}' THEN
    RAISE EXCEPTION 'fleet: changes must be a non-empty object' USING ERRCODE = 'FG400';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_object_keys(p_changes) k WHERE k NOT IN ('title', 'status', 'body', 'due')) THEN
    RAISE EXCEPTION 'fleet: changes may only touch title, status, body, due' USING ERRCODE = 'FG400';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_each(p_changes) e
             WHERE NOT (jsonb_typeof(e.value) = 'string' OR (e.key = 'due' AND jsonb_typeof(e.value) = 'null'))) THEN
    RAISE EXCEPTION 'fleet: values must be strings (due: YYYY-MM-DD or null)' USING ERRCODE = 'FG400';
  END IF;
  -- Same bounds as the table CHECKs, but refused here with the contract's FG400 instead of 23514.
  IF (p_changes ? 'title' AND length(p_changes ->> 'title') NOT BETWEEN 1 AND 500)
     OR (p_changes ? 'status' AND length(p_changes ->> 'status') NOT BETWEEN 1 AND 40)
     OR (p_changes ? 'body' AND length(p_changes ->> 'body') > 100000) THEN
    RAISE EXCEPTION 'fleet: title 1..500, status 1..40, body <= 100000 chars' USING ERRCODE = 'FG400';
  END IF;
  -- due: exactly YYYY-MM-DD and a real, finite date (Postgres would also accept 'infinity', 'today', ...).
  IF jsonb_typeof(p_changes -> 'due') = 'string' THEN
    IF (p_changes ->> 'due') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
      RAISE EXCEPTION 'fleet: due must be YYYY-MM-DD' USING ERRCODE = 'FG400';
    END IF;
    BEGIN
      IF to_char((p_changes ->> 'due')::date, 'YYYY-MM-DD') <> (p_changes ->> 'due') THEN
        RAISE EXCEPTION 'not canonical';
      END IF;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'fleet: due must be a real YYYY-MM-DD date' USING ERRCODE = 'FG400';
    END;
  END IF;

  SELECT * INTO t FROM fleet.tasks WHERE id = p_task FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fleet: no such task' USING ERRCODE = 'FG404'; END IF;

  IF EXISTS (SELECT 1 FROM fleet.task_requests WHERE task_id = p_task AND request_id = p_request_id) THEN
    RAISE EXCEPTION 'fleet: duplicate request' USING ERRCODE = 'FG409', DETAIL = 'duplicate request';
  END IF;
  IF p_base_version > t.version THEN
    RAISE EXCEPTION 'fleet: base version % is ahead of the task (%)', p_base_version, t.version USING ERRCODE = 'FG400';
  END IF;
  -- Per-field compare-and-set: stale only if a field being changed moved after the caller's base.
  FOR f IN SELECT jsonb_object_keys(p_changes) LOOP
    IF (t.field_versions ->> f)::bigint > p_base_version THEN
      stale := stale || jsonb_build_object(f, (t.field_versions ->> f)::bigint);
    END IF;
  END LOOP;
  IF stale <> '{}' THEN
    RAISE EXCEPTION 'fleet: stale update' USING ERRCODE = 'FG409',
      DETAIL = jsonb_build_object('stale_fields', stale, 'current_version', t.version)::text;
  END IF;

  newv := t.version + 1;
  FOR f IN SELECT jsonb_object_keys(p_changes) LOOP
    oldval := to_jsonb(t) -> f;
    newval := p_changes -> f;
    IF f = 'due' AND jsonb_typeof(newval) = 'string' THEN
      newval := to_jsonb((newval #>> '{}')::date);   -- validated above
    END IF;
    IF oldval IS DISTINCT FROM newval THEN
      INSERT INTO fleet.task_history (task_id, version, field, old_value, new_value, actor_principal,
                                      executing_service, request_id, job_id, session_id)
      VALUES (p_task, newv, f, oldval, newval, p_actor, p_service, p_request_id, p_job_id, p_session_id);
      t.field_versions := jsonb_set(t.field_versions, ARRAY[f], to_jsonb(newv));
    END IF;
  END LOOP;

  UPDATE fleet.tasks SET
    title  = CASE WHEN p_changes ? 'title'  THEN p_changes ->> 'title'  ELSE title  END,
    status = CASE WHEN p_changes ? 'status' THEN p_changes ->> 'status' ELSE status END,
    body   = CASE WHEN p_changes ? 'body'   THEN p_changes ->> 'body'   ELSE body   END,
    due    = CASE WHEN p_changes ? 'due'    THEN (p_changes ->> 'due')::date ELSE due END,
    version = newv, field_versions = t.field_versions, updated_at = now(), updated_by = p_actor
  WHERE id = p_task;
  INSERT INTO fleet.task_requests (task_id, request_id, new_version) VALUES (p_task, p_request_id, newv);
  INSERT INTO fleet.audit (actor_principal, executing_service, request_id, action, object, outcome, detail)
  VALUES (p_actor, p_service, p_request_id, 'task.update', p_task::text, 'ok',
          jsonb_build_object('version', newv, 'fields', (SELECT jsonb_agg(k) FROM jsonb_object_keys(p_changes) k)));
  PERFORM pg_notify('fleet_tasks', p_task::text);   -- a wake-up hint only
  RETURN newv;
END $$;

-- The gate records REFUSALS only (denied reads/writes, forged headers, conflicts), in its own transaction.
-- They are stored with origin 'gate' and can never be a success: authoritative successes are written only by
-- the mutation functions themselves (origin 'db'). An actor that isn't a known principal is kept only as
-- detail.claimed_actor.
CREATE FUNCTION fleet.audit_record(
  p_company text, p_actor uuid, p_service text, p_request_id text, p_action text, p_object text,
  p_outcome text, p_detail jsonb DEFAULT '{}'
) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = fleet, pg_temp AS $$
DECLARE i bigint; known boolean;
BEGIN
  PERFORM fleet._require_company(p_company);
  PERFORM fleet._assert_writable();
  IF p_outcome IS NULL OR p_outcome NOT IN ('denied', 'conflict', 'error') THEN
    RAISE EXCEPTION 'fleet: the gate may record only denied, conflict or error' USING ERRCODE = 'FG400';
  END IF;
  IF p_service IS NULL OR p_service !~ '^[a-z][a-z0-9_.-]{1,60}$'
     OR p_request_id IS NULL OR length(p_request_id) NOT BETWEEN 1 AND 128
     OR p_action IS NULL OR p_action !~ '^[a-z][a-z0-9_.:-]{1,80}$'
     OR (p_object IS NOT NULL AND length(p_object) > 300)
     OR (p_detail IS NOT NULL AND (jsonb_typeof(p_detail) <> 'object' OR length(p_detail::text) > 8000)) THEN
    RAISE EXCEPTION 'fleet: bad audit record' USING ERRCODE = 'FG400';
  END IF;
  known := EXISTS (SELECT 1 FROM fleet.principals WHERE id = p_actor);
  INSERT INTO fleet.audit (origin, actor_principal, executing_service, request_id, action, object, outcome, detail)
  VALUES ('gate', CASE WHEN known THEN p_actor END, p_service, p_request_id, p_action, p_object, p_outcome,
          coalesce(p_detail, '{}') || CASE WHEN p_actor IS NOT NULL AND NOT known
                                           THEN jsonb_build_object('claimed_actor', p_actor::text) ELSE '{}' END)
  RETURNING id INTO i;
  RETURN i;
END $$;

-- Operator-only (granted to no login role): create a task with its 'create' history rows.
CREATE FUNCTION fleet.seed_task(p_id uuid, p_title text, p_status text, p_body text, p_actor uuid, p_request_id text)
RETURNS uuid LANGUAGE plpgsql SET search_path = fleet, pg_temp AS $$
DECLARE t fleet.tasks;
BEGIN
  PERFORM fleet._require_principal(p_actor);
  IF EXISTS (SELECT 1 FROM fleet.tasks WHERE id = p_id) THEN RETURN p_id; END IF;   -- seeds are re-runnable
  INSERT INTO fleet.tasks (id, title, status, body, created_by, updated_by)
  VALUES (p_id, p_title, p_status, coalesce(p_body, ''), p_actor, p_actor) RETURNING * INTO t;
  INSERT INTO fleet.task_history (task_id, version, field, old_value, new_value, actor_principal, executing_service, request_id)
  SELECT t.id, 1, x.f, NULL, x.v, p_actor, 'fleet-company-db.seed', p_request_id
  FROM (VALUES ('title', to_jsonb(t.title)), ('status', to_jsonb(t.status)), ('body', to_jsonb(t.body)), ('due', to_jsonb(t.due))) AS x(f, v);
  INSERT INTO fleet.task_requests (task_id, request_id, new_version) VALUES (t.id, p_request_id, 1);
  INSERT INTO fleet.audit (actor_principal, executing_service, request_id, action, object, outcome)
  VALUES (p_actor, 'fleet-company-db.seed', p_request_id, 'task.create', t.id::text, 'ok');
  RETURN t.id;
END $$;

-- ---------------------------------------------------------------- jobs API
CREATE FUNCTION fleet.job_enqueue(
  p_company text, p_kind text, p_task uuid, p_payload jsonb, p_idempotency_key text,
  p_actor uuid, p_service text, p_max_attempts int DEFAULT 3
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = fleet, pg_temp AS $$
DECLARE j fleet.jobs;
BEGIN
  PERFORM fleet._require_company(p_company);
  PERFORM fleet._require_editor(p_actor);
  PERFORM fleet._assert_writable();
  IF p_kind IS NULL OR p_kind !~ '^[a-z][a-z0-9_.-]{1,40}$'
     OR p_idempotency_key IS NULL OR length(p_idempotency_key) NOT BETWEEN 8 AND 200
     OR p_max_attempts IS NULL OR p_max_attempts NOT BETWEEN 1 AND 20
     OR p_service IS NULL OR p_service !~ '^[a-z][a-z0-9_.-]{1,60}$'
     OR (p_payload IS NOT NULL AND (jsonb_typeof(p_payload) <> 'object' OR length(p_payload::text) > 65536)) THEN
    RAISE EXCEPTION 'fleet: bad job (kind, idempotency key 8..200, max_attempts 1..20, payload object <= 64 KiB)'
      USING ERRCODE = 'FG400';
  END IF;
  IF p_task IS NOT NULL AND NOT EXISTS (SELECT 1 FROM fleet.tasks WHERE id = p_task) THEN
    RAISE EXCEPTION 'fleet: no such task' USING ERRCODE = 'FG404';
  END IF;
  INSERT INTO fleet.jobs (kind, task_id, payload, idempotency_key, max_attempts, created_by)
  VALUES (p_kind, p_task, coalesce(p_payload, '{}'), p_idempotency_key, p_max_attempts, p_actor)
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING * INTO j;
  IF NOT FOUND THEN
    SELECT * INTO j FROM fleet.jobs WHERE idempotency_key = p_idempotency_key;
    -- A replay is the SAME request: same initiating principal and every execution-affecting parameter.
    IF j.created_by <> p_actor OR j.kind <> p_kind OR j.payload <> coalesce(p_payload, '{}')
       OR j.task_id IS DISTINCT FROM p_task OR j.max_attempts <> p_max_attempts THEN
      RAISE EXCEPTION 'fleet: idempotency key reused with a different request' USING ERRCODE = 'FG409';
    END IF;
    RETURN to_jsonb(j);           -- the same job, enqueued once
  END IF;
  INSERT INTO fleet.job_events (job_id, event, epoch, worker, detail)
  VALUES (j.id, 'enqueued', 0, NULL, jsonb_build_object('by', p_actor, 'service', p_service));
  PERFORM pg_notify('fleet_jobs', j.id::text);   -- a wake-up hint only
  RETURN to_jsonb(j);
END $$;

-- Claims one queued job, or one whose lease expired (recovery). NULL when none.
-- An expired job that already used all its attempts becomes 'dead' (kept) instead of being reclaimed.
CREATE FUNCTION fleet.job_claim(p_worker text, p_kinds text[], p_lease_seconds int DEFAULT 300)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = fleet, pg_temp AS $$
DECLARE j fleet.jobs;
BEGIN
  IF p_worker IS NULL OR p_worker = '' OR length(p_worker) > 120 OR p_lease_seconds IS NULL
     OR p_lease_seconds NOT BETWEEN 10 AND 3600 OR p_kinds IS NULL THEN
    RAISE EXCEPTION 'fleet: worker and a lease of 10..3600 s required' USING ERRCODE = 'FG400';
  END IF;
  PERFORM fleet._assert_writable();
  -- Recovery sweep over expired leases of these kinds: a cancel-requested job ends 'cancelled'; one that
  -- used all its attempts ends 'dead'. Both are kept, with an event; the old worker is fenced (state <> running).
  WITH d AS (
    UPDATE fleet.jobs SET state = CASE WHEN cancel_requested THEN 'cancelled' ELSE 'dead' END,
           lease_owner = NULL, lease_expires_at = NULL,
           last_error = CASE WHEN cancel_requested THEN last_error
                             ELSE coalesce(last_error, 'lease expired after the final attempt') END,
           updated_at = now()
    WHERE id IN (SELECT id FROM fleet.jobs
                 WHERE state = 'running' AND lease_expires_at < clock_timestamp()
                   AND (cancel_requested OR attempts >= max_attempts) AND kind = ANY (p_kinds)
                 FOR UPDATE SKIP LOCKED)
    RETURNING id, lease_epoch, state)
  INSERT INTO fleet.job_events (job_id, event, epoch, worker, detail)
  SELECT id, CASE WHEN state = 'cancelled' THEN 'cancelled' ELSE 'dead' END, lease_epoch, p_worker,
         jsonb_build_object('reason', 'lease expired') FROM d;

  SELECT * INTO j FROM fleet.jobs
  WHERE kind = ANY (p_kinds) AND NOT cancel_requested AND (
        (state = 'queued' AND not_before <= clock_timestamp())
     OR (state = 'running' AND lease_expires_at < clock_timestamp() AND attempts < max_attempts))
  ORDER BY not_before, created_at
  LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN NULL; END IF;

  UPDATE fleet.jobs SET state = 'running', attempts = attempts + 1, lease_epoch = lease_epoch + 1,
         lease_owner = p_worker,
         lease_expires_at = clock_timestamp() + make_interval(secs => p_lease_seconds), updated_at = now()
  WHERE id = j.id RETURNING * INTO j;
  INSERT INTO fleet.job_events (job_id, event, epoch, worker) VALUES (j.id, 'claimed', j.lease_epoch, p_worker);
  RETURN to_jsonb(j);
END $$;

-- Renew a held, unexpired lease. {"ok": bool, "cancel_requested": bool}. A stale epoch never renews.
CREATE FUNCTION fleet.job_renew(p_id uuid, p_epoch bigint, p_worker text, p_lease_seconds int DEFAULT 300)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = fleet, pg_temp AS $$
DECLARE j fleet.jobs;
BEGIN
  IF p_lease_seconds IS NULL OR p_lease_seconds NOT BETWEEN 10 AND 3600 THEN
    RAISE EXCEPTION 'fleet: lease of 10..3600 s required' USING ERRCODE = 'FG400';
  END IF;
  PERFORM fleet._assert_writable();
  UPDATE fleet.jobs SET lease_expires_at = clock_timestamp() + make_interval(secs => p_lease_seconds), updated_at = now()
  WHERE id = p_id AND state = 'running' AND lease_epoch = p_epoch AND lease_owner = p_worker
    AND lease_expires_at >= clock_timestamp()
  RETURNING * INTO j;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'cancel_requested', false); END IF;
  RETURN jsonb_build_object('ok', true, 'cancel_requested', j.cancel_requested);
END $$;

-- Finish a job. A worker whose epoch is stale (its lease was reclaimed) or whose lease has expired gets
-- FG409 and changes nothing.
CREATE FUNCTION fleet.job_complete(
  p_id uuid, p_epoch bigint, p_worker text, p_outcome text, p_result jsonb DEFAULT NULL,
  p_error text DEFAULT NULL, p_retry_after_seconds int DEFAULT 30
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = fleet, pg_temp AS $$
DECLARE j fleet.jobs; nextstate text;
BEGIN
  PERFORM fleet._assert_writable();
  IF (p_result IS NOT NULL AND length(p_result::text) > 65536) OR (p_error IS NOT NULL AND length(p_error) > 4000)
     OR (p_retry_after_seconds IS NOT NULL AND p_retry_after_seconds NOT BETWEEN 0 AND 86400) THEN
    RAISE EXCEPTION 'fleet: result <= 64 KiB, error <= 4000 chars, retry 0..86400 s' USING ERRCODE = 'FG400';
  END IF;
  SELECT * INTO j FROM fleet.jobs WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fleet: no such job' USING ERRCODE = 'FG404'; END IF;
  IF j.state <> 'running' OR j.lease_epoch <> p_epoch OR j.lease_owner IS DISTINCT FROM p_worker THEN
    RAISE EXCEPTION 'fleet: stale worker (epoch %, current %)', p_epoch, j.lease_epoch USING ERRCODE = 'FG409';
  END IF;
  IF j.lease_expires_at < clock_timestamp() THEN
    RAISE EXCEPTION 'fleet: lease expired' USING ERRCODE = 'FG409', DETAIL = 'lease expired';
  END IF;
  IF p_outcome = 'succeeded' THEN nextstate := 'succeeded';
  ELSIF p_outcome = 'cancelled' AND j.cancel_requested THEN nextstate := 'cancelled';
  ELSIF p_outcome = 'failed' THEN
    nextstate := CASE WHEN j.attempts < j.max_attempts AND NOT j.cancel_requested THEN 'queued' ELSE 'failed' END;
  ELSE RAISE EXCEPTION 'fleet: bad outcome %', p_outcome USING ERRCODE = 'FG400';
  END IF;
  UPDATE fleet.jobs SET state = nextstate, lease_owner = NULL, lease_expires_at = NULL,
         result = coalesce(p_result, result), last_error = coalesce(p_error, last_error),
         not_before = CASE WHEN nextstate = 'queued'
                           THEN clock_timestamp() + make_interval(secs => greatest(coalesce(p_retry_after_seconds, 30), 0))
                           ELSE not_before END,
         updated_at = now()
  WHERE id = p_id RETURNING * INTO j;
  INSERT INTO fleet.job_events (job_id, event, epoch, worker, detail)
  VALUES (p_id, 'completed:' || p_outcome, p_epoch, p_worker, jsonb_build_object('next_state', nextstate));
  RETURN to_jsonb(j);
END $$;

CREATE FUNCTION fleet.job_cancel(p_company text, p_id uuid, p_actor uuid, p_service text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = fleet, pg_temp AS $$
DECLARE j fleet.jobs;
BEGIN
  PERFORM fleet._require_company(p_company);
  PERFORM fleet._require_editor(p_actor);
  PERFORM fleet._assert_writable();
  SELECT * INTO j FROM fleet.jobs WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'fleet: no such job' USING ERRCODE = 'FG404'; END IF;
  IF j.state = 'queued' THEN
    UPDATE fleet.jobs SET state = 'cancelled', cancel_requested = true, updated_at = now() WHERE id = p_id RETURNING * INTO j;
  ELSIF j.state = 'running' THEN
    UPDATE fleet.jobs SET cancel_requested = true, updated_at = now() WHERE id = p_id RETURNING * INTO j;
  END IF;
  INSERT INTO fleet.job_events (job_id, event, epoch, worker, detail)
  VALUES (p_id, 'cancel_requested', j.lease_epoch, NULL, jsonb_build_object('by', p_actor, 'service', p_service));
  RETURN to_jsonb(j);
END $$;
