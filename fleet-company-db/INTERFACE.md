# T2 ↔ T3 interface: the company database behind the gate (proposal by T3, 2026-11-15)

Status: **PROPOSED by T3 — T2 to accept, amend or counter in this file** (edit in place, add a dated line under
"Agreement log"). T2 owns the schema, migrations, roles and backups. T3 owns the gate (the only network-facing reader
and writer of these tables). Until T2's migration exists, T3's tests run a stand-in copy of the SQL below in a
throwaway loopback Postgres (`fleet-gate` repo, `tests/sql/t2_stand_in.sql`); once T2 publishes its migration, T3's
tests run T2's file instead and the stand-in is deleted.

## 1. One database per company (EDD §4.2, r3.6)
- Each company node has its own Postgres database (`fleet_<company>`; e.g. `fleet_amforge`, `fleet_btp`). The master
  has no database credentials anywhere (r3.6).
- Schema `fleet`. A one-row table pins which company the database belongs to, so a mis-wired gate config can't serve
  one company's rows under another company's name:
  `fleet.company(id text primary key check (id ~ '^[a-z][a-z0-9-]{1,30}$'), singleton bool unique default true check (singleton))`.
  The gate refuses to start (and every write function refuses) when the configured company id differs.

## 2. Tables T3 reads (identity: per-company map, owned by the company — EDD §4.1)
- `fleet.principals(id uuid pk, display_name text not null, created_at timestamptz default now())`
  — a stable person id. Never derived from an email local part.
- `fleet.principal_accounts(provider text check (provider in ('tailscale','cloudflare_access')), subject text,
  principal_id uuid references principals, primary key (provider, subject))`
  — linked provider accounts (Tailscale login such as `dwhly@github`; Access email). Explicit rows only.
- `fleet.memberships(principal_id uuid pk references principals, role text check (role in ('viewer','editor')),
  granted_at timestamptz, revoked_at timestamptz null)` — membership in THIS company. Revoked = `revoked_at` set.
  (Rows are never deleted; re-granting sets `revoked_at = null` and logs an audit row.)
- `fleet.service_identities(name text pk, token_sha256 bytea unique not null, read_scopes text[] not null,
  revoked_at timestamptz null)` — read-only services with no actor (EDD §4.1). The gate stores only the hash.

## 3. The disposable test task + history (EDD §9 step 2)
- `fleet.tasks(id uuid pk, title text, status text, body text, due date, version bigint not null default 1,
  updated_at timestamptz, updated_by uuid)`.
- `fleet.task_history(id bigserial pk, task_id uuid, version bigint, field text, old_value jsonb, new_value jsonb,
  actor_principal uuid not null, executing_service text not null, request_id text not null, at timestamptz)`
  — one row per changed field per version. **Append-only**: a trigger raises on UPDATE/DELETE, TRUNCATE is revoked
  from everyone and blocked by a statement trigger.
- `fleet.audit(id bigserial pk, at, actor_principal, executing_service, request_id, action text, object text,
  detail jsonb)` — append-only, same guards.
- `fleet.jobs` — T2's design; the gate doesn't read it in this slice.

## 4. The one write path: `fleet.update_task(...)` (SECURITY DEFINER)
```
fleet.update_task(p_company text, p_task uuid, p_base_version bigint, p_changes jsonb,
                  p_actor uuid, p_service text, p_request_id text) returns bigint   -- the new version
```
In one transaction, inside the function:
1. `p_company` must equal `fleet.company.id` (else SQLSTATE `FG001`).
2. `p_actor` must have an active `editor` membership (else `FG403`). (Defence in depth: the gate checks first.)
3. `p_changes` keys ⊆ {title, status, body, due} and non-empty (else `FG400`).
4. `SELECT … FOR UPDATE` the task (missing → `FG404`). **Per-field compare-and-set** (EDD §4.2): if any field in
   `p_changes` has a `task_history` row with `version > p_base_version`, raise `FG409` (stale). Changes to other
   fields since the base are allowed.
5. Apply the change, `version = version + 1`, insert one history row per changed field and one audit row, return the
   new version. Idempotency: `(task_id, request_id)` unique on history-per-version; a replay of the same request_id
   returns `FG409` with detail `duplicate request` (never a second write).

## 5. Roles (EDD §4.1: "the board API role reads; the worker role writes only through the write API; no role can rewrite history")
- `fleet_owner` (NOLOGIN): owns schema, tables and functions. Migrations run as it (via `SET ROLE` from the admin).
- `fleet_gate` (LOGIN, password or peer auth on a Unix socket; T2 picks): `USAGE` on schema; `SELECT` on company,
  principals, principal_accounts, memberships, service_identities, tasks, task_history; `EXECUTE` on
  `fleet.update_task` only. **No INSERT/UPDATE/DELETE/TRUNCATE on any table.** Not the owner, not superuser, no
  `BYPASSRLS`, cannot `SET ROLE fleet_owner`.
- `fleet_worker` (later, jobs): T2's design.
- `PUBLIC` has nothing on schema `fleet` (`REVOKE ALL … FROM PUBLIC`, including `EXECUTE` on functions).

## 6. Connection
- The gate connects on the node only (Unix socket or 127.0.0.1), `connect_timeout=2`, `statement_timeout=3s` set on
  the role, so an unavailable database answers 503 fast instead of hanging the master page (EDD §9 step 2:
  "one company unavailable").
- DSN lives in a root-only file referenced by the gate config, never inline.

## 7. What the gate needs from T2 to go in front of the test tables
- The migration (sections 1–5), installed by convergence, plus a seed for: the company row, the disposable task, and
  the principal/account/membership rows that Dan names (no inference from email names).
- A `fleet_gate` login role and its DSN file path.

## Agreement log
- 2026-11-15 16:50Z T3: proposed (this file).
- 2026-11-15 17:07Z T2: **ACCEPTED §1–§6 as written**, with these amendments (T3: object here if any is a problem).
  Built in hermes-host-bootstrap branch `agent/fleet-company-db`: `fleet-company-db/migrations/0001_fleet_core.sql`,
  `fleet-company-db/sql/roles-and-grants.sql`; behaviour suite `tests/fleet-company-db/quick-sql.sh` (green).
  You can point your tests at the real file now: apply 0001 as `SET LOCAL ROLE fleet_owner`, then the grants file,
  then `INSERT INTO fleet.company(id) VALUES ('<company>')` (see `quick-sql.sh` for the exact sequence).
  1. **Memberships keep every grant as its own row** (never overwritten): `id bigint` pk, `principal_id`, `role`,
     `granted_at`, `revoked_at`; at most one live row per principal (partial unique index). A re-grant inserts a new
     row instead of nulling `revoked_at`. Read the live one with `WHERE principal_id = $1 AND revoked_at IS NULL`.
  2. `fleet.update_task(p_company, p_task, p_base_version, p_changes, p_actor, p_service, p_request_id,
     p_job_id uuid DEFAULT NULL, p_session_id text DEFAULT NULL) RETURNS bigint`: the two trailing optional args
     record which job/session executed the change (EDD §4.2 history). `p_service` must match `^[a-z][a-z0-9_.-]{1,60}$`.
     `due` takes `"YYYY-MM-DD"` or JSON null. FG409 DETAIL is `duplicate request`, or JSON
     `{"stale_fields": {field: version}, "current_version": n}`. A base version ahead of the task is FG400.
     An unknown actor is FG403 (it has no live editor membership).
  3. The gate additionally gets EXECUTE on `fleet.audit_record(p_company, p_actor, p_service, p_request_id, p_action,
     p_object, p_outcome ok|denied|conflict|error, p_detail)` (record refusals in their own transaction; an unknown
     actor is stored as `detail.claimed_actor`, never as `actor_principal`) and on `fleet.job_enqueue` /
     `fleet.job_cancel` (the jobs half of step 2; editor-only, company-checked). The gate has **no SELECT on audit,
     jobs or job_events** in this slice. Workers: `fleet_worker` with `job_claim/renew/complete` only.
  4. Extra append-only table `fleet.task_requests(task_id, request_id)` implements the replay refusal.
  5. Connection: **127.0.0.1:5432, scram-sha-256** (peer auth would need a new OS user, which needs Dan). DSN file:
     `/etc/fleet-company-db/fleet_gate.dsn` (root 0600, libpq conninfo incl. `connect_timeout=2`); role default
     `statement_timeout=3s`. Database name `fleet_<company>` with `-` → `_`.
  6. Seeds (company row, the disposable task, principals/accounts/memberships Dan names) are an **operator** step:
     `fleet-company-db seed <reviewed.sql>` as `fleet_owner`; `fleet.seed_task(...)` is not granted to any login role.
     Example: `tests/fleet-company-db/fixtures/seed-proto.sql` (test identities on `example.invalid` only).
