# fleet-company-db: the company's Postgres record on its own node

EDD-fleet-architecture §9 step 2 (r3.5, D4, D5). Owner: track T2. Status 2026-11-15: **prototype proven on h-do1,
ready to install, held** (`ROLLOUT=hold` on h-af and h-btp until the owner says "roll it out").

## What it is
One Postgres 16 cluster per company node (h-af = AmForge, h-btp = BTP), database `fleet_<company>`, schema `fleet`:
the identity map (principals, linked accounts, memberships, service identities), **one disposable test task** with
append-only per-field history, the audit log and the **jobs table**. T3's gate is the only network-facing reader and
writer (contract: `INTERFACE.md`, copied from `arch-tracks/INTERFACE-T2-T3.md`). Every committed change is archived
continuously as WAL to **the company's own bucket** (Cloudflare R2, D4), encrypted before it leaves the node, and a
fresh host can rebuild the database from the bucket plus two secrets (D5).

## Decisions (and why)
| | Choice | Why / rejected |
|---|---|---|
| Packaging | Ubuntu 24.04 archive packages `postgresql-16` + `pgbackrest`, systemd unit `postgresql@16-main` | Both nodes are Ubuntu 24.04; distro packages get security updates through the existing unattended-upgrades path; no Docker daemon in the record's failure path. A container was rejected: h-btp has no docker stack for this, and a container adds a second supervisor and a volume to back up. PGDG apt repo rejected for now: one more signing key/trust root (expanding trust needs Dan) for no step-2 benefit. |
| Version | PostgreSQL 16 (16.15 in the archive today), pgBackRest 2.50 | What noble ships and supports for its lifetime. Major upgrades are a deliberate, drilled change (below). |
| Archiver | pgBackRest, `archive-async`, repo type s3, path-style, bundles, zstd | Native S3/R2, encryption, full/diff/incremental, PITR, `check`, `verify`, parallel async push. wal-g was the alternative: fewer guard rails (no `check`, weaker info/verify), similar size. |
| Encryption at rest | `repo1-cipher-type=aes-256-cbc` with a ≥32-char passphrase: client-side, before upload | The bucket never sees plaintext; R2's own at-rest encryption is a second layer, not the control. Losing the passphrase loses the backups: it lives in the company's 1Password and with Dan + one person per company (D5). |
| RPO 5 min | `archive_timeout=60` + async push; the health probe forces a WAL switch when there are unarchived changes and requires the segment in the bucket within 90 s | Measured on h-do1 under host loss (SIGKILL): see Evidence. An idle database switches nothing (no false alarms, no empty segments). |
| Backups | weekly full (Sun 03:30 UTC), daily diff (Mon–Sat), `Persistent=true`, randomized 15 min, `MemoryMax=300M`, nice/idle IO | RTO 4 h: restore = 1 full + 1 diff + ≤ 1 day of WAL. |
| Retention | **`expire-auto=n`: nothing is expired or deleted in this round** (standing rule). `repo1-retention-full=35` (time) is configured but inert. R2 lifecycle (D4, 35 d on WAL) is an owner step to apply only after the first live drill passes — see Needs Dan. | |
| Fail closed | `install` creates the cluster only after the secrets resolve (HOLD, exit 3, leaves **no cluster**); then `pgbackrest check` and the first full backup must pass before the schema exists, or the cluster is stopped, **disabled and `start.conf=manual`** (survives reboot; backup units are `Requisite=`, so they never start it). After the first install, **a write fence closes the record** whenever WAL stops reaching the bucket: every mutating function refuses with `FG503` (reads continue) while (a) the health probe — every minute — has closed `fleet.write_fence`, or (b) the archiver's latest event is a failure and its last success is > 120 s old, or (c) archiving is off. It reopens by itself when WAL reaches the bucket again. | No database runs, and no write is accepted, without working backups (review r1 BLOCKER). Proven live with a real bucket outage: see Evidence (`outage_*`). |
| Memory | systemd drop-in `MemoryHigh/MemoryMax` on the unit; h-af 768M/1G with `shared_buffers=256MB`; h-btp 384M/512M with `128MB` | Baseline (`edd/evidence/fleet-architecture/memory-baseline-2026-11-15.md`) + live 2026-11-15: h-af 23.4 GB available of 32 GB; h-btp 7.0 GB available of 16 GB with swap 2034/2047 MB used. Measured: 93 MiB idle, 137 MiB peak under the workload (cap 1 GiB). |
| Network | `listen_addresses=localhost`; pg_hba: postgres by peer on the socket, `fleet_gate`/`fleet_worker` by scram-sha-256 on 127.0.0.1/::1 to `fleet_<company>` only; everything else refused | The gate runs on the same node; nothing listens on the tailnet. |
| Roles | `fleet_owner` NOLOGIN owns everything; `fleet_gate` SELECT on what it authorizes + EXECUTE on the write functions; `fleet_worker` EXECUTE on job claim/renew/complete only; PUBLIC nothing (a global default revoke is in place before the first migration, and each migration commits together with the grants); nobody can become the owner | EDD §4.1 "enforced, not just a library". History/audit/job_events/task_requests are append-only even for the superuser (triggers); no record is ever deleted. The gate may record **refusals only** (`origin='gate'`); every success is written by the mutation function itself (`origin='db'`). |
| Secrets | resolved by the node's own read/write 1Password service account (Dan 2026-11-16; the drill host's stays read-only) into `/etc/pgbackrest/conf.d/50-secrets.conf` (root:postgres 0640); the token is passed only to each `op read`, never exported; gate/worker passwords generated on the node (`/etc/fleet-company-db/*.password|*.dsn`, root 0600), and the server only ever receives the SCRAM verifier | Values never in git, argv, logs or chat. |
| OS user | the `postgresql-common` package creates the system user `postgres` (and group) on first install | Creating an OS user needs Dan's approval: part of "roll it out" (Needs Dan). No login shell use; no SSH key; peer auth on the local socket only. |

## How convergence installs and upgrades it
- Module `lib/62-fleet-company-db.sh` (auto-discovered by `bootstrap.sh`, skip key `fleet-company-db`). It acts only
  where `config/fleet-company-db/<host>.env` exists **and** contains `ROLLOUT=go`; elsewhere it writes nothing.
- It copies `fleet-company-db/` to `/usr/local/lib/fleet-company-db/<sha256>/`, swaps the `current` symlink
  atomically, links `/usr/local/sbin/fleet-company-db`, then runs `fleet-company-db install --desired <file>`, which
  is idempotent: unchanged files are not rewritten, Postgres is not restarted (reloads only; restart-only settings are
  reported "waiting for an attended restart"), applied migrations are skipped by version + sha256.
- **Schema changes:** add `migrations/NNNN_*.sql` (expand/contract; an applied file can never change — a changed
  hash stops the run). Applied in one transaction as `fleet_owner`, then `sql/roles-and-grants.sql` (idempotent).
- **Minor Postgres updates** arrive via apt (unattended-upgrades restarts the unit; WAL archiving resumes).
- **Major upgrade (16 → 17):** never automatic. A reviewed change: drill-restore to a fresh host, `pg_upgradecluster`
  there, `pgbackrest stanza-upgrade`, full backup, verify, then the same on the node in a maintenance window.
- Payload versions stay on disk (`/usr/local/lib/fleet-company-db/<sha>`), so rollback of the code is a symlink swap.

## Owner steps (Dan; nothing here was created by T2)
Per company (AmForge in AmForge's Cloudflare + 1Password; BTP in BTP's):
1. **R2 bucket** in the company's own Cloudflare account: `fleet-db-amforge` / `fleet-db-btp`, location hint
   nearest the node (h-af/h-btp: North America). **R2 has no object versioning** (D4 assumed it; Cloudflare's S3 API
   table lists `PutBucketVersioning` and Object Lock as unimplemented — review r1 [10]). The R2 equivalent is a
   **Bucket Lock rule** (prefix + age). Do **not** add a lock or lifecycle rule yet: both are Needs Dan.
2. **R2 API token** (R2 → Manage API tokens → Create): permission **Object Read & Write**, scoped to **that one
   bucket only**, no expiry or 1-year expiry, no IP filter (or the node's egress IP). Note the Account ID (the S3
   endpoint is `<account-id>.r2.cloudflarestorage.com`). Never "Roll" an existing token; "Update token" only.
3. **1Password**, in the company's vault (the one the node's service account can read):
   - item **`fleet-db-r2`** (API Credential): fields **`access_key_id`**, **`secret_access_key`**, **`endpoint`**
     (`https://<account-id>.r2.cloudflarestorage.com`), **`bucket`**.
   - item **`fleet-db-backup-key`** (Password): field **`passphrase`** = a generated password of ≥ 48 characters.
     This is the key to every backup: share the item with Dan + one named person per company (D5); keep an offline
     copy (printed, sealed) with each.
4. **Node service account** (read/write, that vault only; Dan 2026-11-16): h-af already has one (`/root/.config/amforge/op_sa_token`);
   make sure it can read the two items. h-btp has **none**: create a 1Password service account for the BTP vault
   (read/write) and place its token at `/root/.config/btp/op_sa_token` (root 0600) — or tell T2 where it should live.
5. Tell T2 (or edit the reviewed desired file): the vault name and the Account ID, replacing `owner-step-pending`
   in `config/fleet-company-db/<host>.env`.

### Drill host (D5), per company, QUARTERLY (Dan 2026-11-16: "I think we should do them quarterly") and after every major change
- A **fresh** Ubuntu 24.04 droplet/VM **in the company's own account** (DigitalOcean for BTP like h-btp; AmForge's
  provider for AmForge), 2 vCPU / 4 GB is plenty, on the tailnet with a `tag:drill` (no inbound from the internet).
- On it, as root: install `op` + a **read-only** service-account token for that company's vault (deliberately read-only: a drill only restores), copy
  the payload and the host's desired file from git, then
  `fleet-company-db drill-restore --desired h-<x>.env --latest` (and once `--target '<timestamp>+00'`). The drill copy
  runs with archiving **off**, so it can never write into the production bucket.
- Record: restore seconds (RTO), last restored change vs last known change (RPO), `fleet.tasks` + history counts,
  `pgbackrest verify`. Then destroy the droplet (the bucket is untouched; nothing is deleted from it).

## Install, per node (after "roll it out")
```
# on h-do1, in the bootstrap repo (reviewed PR merged)
sed -i 's/^ROLLOUT=hold$/ROLLOUT=go/' config/fleet-company-db/h-af.env   # + owner values; PR, review, merge
# on h-af (root), as one heavy job, under a memory cap:
cd <bootstrap checkout> && git pull --ff-only && \
  systemd-run --wait --pty -p MemoryMax=700M bash lib/62-fleet-company-db.sh
fleet-company-db status          # healthy=1
fleet-company-db seed <reviewed seed with the people Dan names>.sql
```
Backups before the change (standing rule): `/root/legacy-capture/<date>-fleet-company-db/` gets `dpkg -l`, the
`systemctl list-units` list and `ss -ltn`; a row goes into `oa-c0/docs/c0-delta-ledger.md`.

## Rollback, per node (never deletes data)
1. `systemctl disable --now fleet-db-backup-full.timer fleet-db-backup-diff.timer fleet-db-health.timer`
2. `systemctl disable --now postgresql@16-main` and `echo manual > /etc/postgresql/16/main/start.conf` (the
   postgresql-common generator starts `auto` clusters at boot even when disabled) — the cluster stays on disk, the
   bucket keeps every backup and WAL.
3. Set `ROLLOUT=hold` in the desired file (reviewed). Code rollback only: point `/usr/local/lib/fleet-company-db/current`
   at the previous `<sha>` and re-run `fleet-company-db install`.
   Removing packages/data is out of scope for rollback (archive = keep).

## Needs Dan (each with a recommendation)
1. **"Roll it out"**, per host: a reviewed one-line `ROLLOUT=go` in `config/fleet-company-db/<host>.env`. It
   creates the `postgres` system user on that node; neither node has one today, and h-af's own `fleet-pages-pg`
   runs as `fleet-pages-pg` on :55499, so there's no clash. Recommend h-af first (23 GB available). h-btp only
   after its swap pressure is dealt with: 6.7 GB available but swap 2034/2047 MB used (2026-11-15).
2. **D4 correction, retention without versioning** (a hard install prerequisite: `BUCKET_PROTECTION` in each
   host's desired file, `owner-decision-pending` today). R2 has no object versioning and no S3 Object Lock, only
   prefix Bucket Lock rules, and the node's key is read-write. A lock can only cover what pgBackRest never
   rewrites: WAL segments are write-once, but `archive.info`, `backup.info` and the in-progress manifests are
   rewritten. Recommend:
   - An R2 **Bucket Lock** on prefix `pgbackrest/archive/<stanza>/16-` for 35 days.
   - Prove it on the real bucket (one archive, one backup, one restore drill), then set
     `BUCKET_PROTECTION=wal-bucket-lock`.
   - After the first live drill: pgBackRest-managed expiry (`expire-auto=y`, `repo1-retention-full-type=time`,
     `repo1-retention-full=35`). No blind R2 lifecycle rule, because R2 can't tell which WAL a kept backup needs.
   - The alternative is a dated `owner-waiver-YYYY-MM-DD`.
3. **Owner steps** above, per company: the R2 bucket, the scoped token in the company vault, and the cipher
   passphrase. h-btp needs a new read/write 1Password service account for the BTP vault (its existing one is read-only and can't be upgraded).
4. **Drill hosts** (D5) in each company's account, quarterly (Dan 2026-11-16).

## Evidence
`tests/fleet-company-db/proto.sh` (h-do1, throwaway containers) — results in
`/root/code/chief/docs/edd/evidence/fleet-architecture/T2-company-db-proto-2026-11-15.md`.
`tests/fleet-company-db/quick-sql.sh` — the schema/roles behaviour suite in a throwaway postgres:16 (~30 s).

## Owner decisions, 2026-11-16/17 (Dan)
- **Expiry:** "Definitely let backups older than 35 days expire after the first drill." After the first live drill
  passes, a reviewed change sets `expire-auto=y`, `repo1-retention-full-type=time`, `repo1-retention-full=35`.
  Until then nothing is expired.
- **Drills:** quarterly per company, plus after every major change.
- **Bucket protection (D4 correction accepted):** R2 Bucket Lock `wal-35d`, 35 days, prefix
  `pgbackrest/archive/<stanza>/16-` only. AmForge's stanza is `fleet-amforge` (see `config/fleet-company-db/h-af.env`).
  **Never put a probe inside a stanza's archive path before `stanza-create`:** pgBackRest refuses a non-empty
  archive path, and a locked probe can't be removed. Verify the rule's prefix text from its form instead.
- **h-af roll-out:** "roll it out", including creating the `postgres` OS user.
- **1Password service accounts are read/write** on the company vault. h-af uses `Hermes-af-2`. For BTP, a new
  read/write account is needed: 1Password can't add write access to the existing read-only one.
