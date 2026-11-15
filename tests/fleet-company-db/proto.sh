#!/usr/bin/env bash
# fleet-company-db prototype + restore drill on h-do1 (EDD-fleet-architecture §9 step 2, T2 brief step 3).
#
# Everything is throwaway and side by side: a private docker network, MinIO (TLS, unversioned like R2) as the
# stand-in for the company's R2 bucket, published on 127.0.0.1 only; a systemd Ubuntu 24.04 container as the
# company node, converged by the REAL bootstrap module lib/62-fleet-company-db.sh; then FRESH containers as
# drill hosts (D5) that restore from the bucket alone. A fake `op` stands in for 1Password.
#
# Proves: HOLD with no secrets (no cluster created) -> a wrong bucket secret fails the first install closed
# -> install -> idempotent re-run (no restart) -> the schema suite over loopback with the generated DSN files
# -> health/RPO probe -> memory containment -> a bucket outage closes the record for writes and it reopens
# -> a workload, a diff backup, a PITR mark, host loss (SIGKILL) -> restore latest on a fresh host (RPO, RTO)
# -> point-in-time restore on another fresh host (exact marker).
#
#   OUT=<dir> tests/fleet-company-db/proto.sh      (default OUT under $TMPDIR)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(cd "$HERE/../.." && pwd)"
OUT="${OUT:-${TMPDIR:-/tmp}/fcdb-proto-$(date -u +%Y%m%dT%H%M%SZ)}"; mkdir -p "$OUT"; chmod 0700 "$OUT"
NET=fcdb-proto-net; MINIO=fcdb-minio; NODE=fcdb-node; DRILL1=fcdb-drill-latest; DRILL2=fcdb-drill-pitr
IMG=fleet-company-db-node:noble
MINIO_IMG=minio/minio:RELEASE.2025-09-07T16-13-09Z; MC_IMG=minio/mc:RELEASE.2025-08-13T08-35-41Z
TASK=00000000-0000-4000-8000-00000000a001; ED=00000000-0000-4000-8000-0000000000e1
FIX=/opt/bootstrap/tests/fleet-company-db/fixtures
WORKLOAD_SECONDS="${WORKLOAD_SECONDS:-150}"
log() { printf '[proto %s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$OUT/proto.log"; }
res() { printf '%s=%s\n' "$1" "$2" >>"$OUT/results.env"; log "RESULT $1=$2"; }
fail() { log "FAIL: $*"; exit 1; }
: >"$OUT/results.env"

for c in "$NODE" "$DRILL1" "$DRILL2" "$MINIO"; do docker rm -f "$c" >/dev/null 2>&1 || true; done
docker network rm "$NET" >/dev/null 2>&1 || true

# ---------------------------------------------------------------- 1. TLS + MinIO + versioned bucket
log "certs + MinIO (TLS, 127.0.0.1:19000 only)"
mkdir -p "$OUT/certs/CAs"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=fcdb-proto-ca -keyout "$OUT/certs/ca.key" -out "$OUT/certs/CAs/ca.crt" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj /CN=minio -keyout "$OUT/certs/private.key" -out "$OUT/certs/s.csr" 2>/dev/null
printf 'subjectAltName=DNS:minio\n' >"$OUT/certs/ext"
openssl x509 -req -in "$OUT/certs/s.csr" -CA "$OUT/certs/CAs/ca.crt" -CAkey "$OUT/certs/ca.key" -CAcreateserial -days 2 \
  -extfile "$OUT/certs/ext" -out "$OUT/certs/public.crt" 2>/dev/null
chmod 0644 "$OUT/certs/private.key" "$OUT/certs/public.crt"   # read by the minio container only
S3_KEY="proto$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
S3_SECRET="$(head -c 30 /dev/urandom | base64 | tr -d '/+=\n')"
CIPHER="$(head -c 48 /dev/urandom | base64 | tr -d '/+=\n')"
OPTOKEN="ops_proto_$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
docker network create "$NET" >/dev/null
docker run -d --name "$MINIO" --network "$NET" --network-alias minio --memory 512m -p 127.0.0.1:19000:9000 \
  -e MINIO_ROOT_USER="$S3_KEY" -e MINIO_ROOT_PASSWORD="$S3_SECRET" -e MINIO_REGION=auto \
  -v "$OUT/certs:/certs:ro" "$MINIO_IMG" server /data --certs-dir /certs >/dev/null
for _ in $(seq 1 30); do curl -sf --cacert "$OUT/certs/CAs/ca.crt" --resolve minio:19000:127.0.0.1 https://minio:19000/minio/health/live && break; sleep 1; done
docker run --rm --network "$NET" -v "$OUT/certs/CAs:/root/.mc/certs/CAs:ro" -e MC_HOST_p="https://$S3_KEY:$S3_SECRET@minio:9000" \
  "$MC_IMG" mb --region auto p/amforge-fleet-db >/dev/null
# No object versioning: Cloudflare R2 has none (review r1 [10]), so the prototype doesn't rely on it either.
res bucket_versioning "off (matches R2, which has no S3 versioning)"

# ---------------------------------------------------------------- helpers for a node/drill container
start_host() {  # start_host <name> <hostname>
  docker run -d --name "$1" --hostname "$2" --network "$NET" --privileged --cgroupns=private \
    --tmpfs /run --tmpfs /run/lock --memory 2g "$IMG" >/dev/null
  for _ in $(seq 1 30); do docker exec "$1" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break; sleep 1; done
  docker exec "$1" mkdir -p /opt/bootstrap /etc/fleet-company-db /etc/fake-op /root/.config/amforge
  tar -C "$REPO" --exclude=.git -cf - . | docker exec -i "$1" tar -C /opt/bootstrap -xf -
  docker cp "$OUT/certs/CAs/ca.crt" "$1:/etc/fleet-company-db/proto-ca.crt"
  docker cp "$HERE/fake-op" "$1:/usr/local/bin/op"; docker exec "$1" chmod 0755 /usr/local/bin/op
  printf '%s' "$OPTOKEN" | docker exec -i "$1" sh -c 'cat >/root/.config/amforge/op_sa_token; cp /root/.config/amforge/op_sa_token /etc/fake-op/.token; chmod 600 /root/.config/amforge/op_sa_token /etc/fake-op/.token'
}
put_items() {   # the owner step: items in the company's 1Password vault (fake); $2 overrides the secret key
  printf '%s' "$S3_KEY"    | docker exec -i "$1" sh -c 'cat >/etc/fake-op/Hermes__fleet-db-r2__access_key_id'
  printf '%s' "${2:-$S3_SECRET}" | docker exec -i "$1" sh -c 'cat >/etc/fake-op/Hermes__fleet-db-r2__secret_access_key'
  printf '%s' "$CIPHER"    | docker exec -i "$1" sh -c 'cat >/etc/fake-op/Hermes__fleet-db-backup-key__passphrase'
}
su_sql() { docker exec -i "$1" runuser -u postgres -- psql -X -q -At -d fleet_amforge -v ON_ERROR_STOP=1 -c "$2"; }
gate_sql() { docker exec -i "$1" sh -c 'psql "$(cat /etc/fleet-company-db/fleet_gate.dsn)" -X -q -At -v ON_ERROR_STOP=1 -c "$0"' "$2"; }
run_module() { docker exec -e FLEET_HOST_ID=h-proto -e FCDB_CONFIG_DIR="$FIX" -e REPO_ROOT=/opt/bootstrap "$NODE" bash /opt/bootstrap/lib/62-fleet-company-db.sh; }

# ---------------------------------------------------------------- 2. node: HOLD without secrets
log "node: start + converge with NO backup secrets (expect HOLD, no cluster)"
start_host "$NODE" h-proto
run_module >"$OUT/01-hold.log" 2>&1 || fail "module errored without secrets (see 01-hold.log)"
grep -q 'HOLD' "$OUT/01-hold.log" || fail "no HOLD reported"
docker exec "$NODE" test ! -e /var/lib/postgresql/16/main/PG_VERSION || fail "a cluster was created without backup secrets"
docker exec "$NODE" sh -c 'ls /var/lib/postgresql/16 2>/dev/null | wc -l' | grep -q '^0$' || fail "cluster dir exists after HOLD"
res hold_without_secrets "ok (no cluster)"

# ---------------------------------------------------------------- 2b. first install with a WRONG bucket secret
log "node: wrong bucket secret -> first install must fail closed (cluster stopped, disabled, start.conf manual)"
put_items "$NODE" "wrong-secret-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
if run_module >"$OUT/01b-badkey.log" 2>&1; then fail "install succeeded with a wrong bucket secret"; fi
docker exec "$NODE" sh -c 'echo "active=$(systemctl is-active postgresql@16-main.service) enabled=$(systemctl is-enabled postgresql@16-main.service) start.conf=$(grep -v "^#" /etc/postgresql/16/main/start.conf | tr -d "\n")"' >"$OUT/01b-badkey-state.txt" 2>&1 || true
grep -qE 'active=inactive enabled=disabled start.conf=manual' "$OUT/01b-badkey-state.txt" || fail "not fail-closed: $(cat "$OUT/01b-badkey-state.txt")"
log "node: REBOOT (container restart) after the failed first install; the cluster must stay down"
docker restart "$NODE" >/dev/null
for _ in $(seq 1 30); do docker exec "$NODE" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break; sleep 1; done
sleep 5
after_boot="$(docker exec "$NODE" systemctl is-active postgresql@16-main.service 2>&1 || true)"
[[ "$after_boot" == inactive ]] || fail "cluster came back after reboot: $after_boot"
res failed_first_install "fail-closed ($(cat "$OUT/01b-badkey-state.txt"); after reboot: $after_boot)"

# ---------------------------------------------------------------- 3. install
log "node: owner step done (items in 1Password) -> converge"
put_items "$NODE"
t0=$(date +%s); run_module >"$OUT/02-install.log" 2>&1 || { tail -30 "$OUT/02-install.log"; fail "install failed"; }; t1=$(date +%s)
res install_seconds "$((t1 - t0))"
grep -q 'converged' "$OUT/02-install.log" || fail "module did not report converged"
docker exec "$NODE" sh -c 'grep -c "repo1-cipher-pass" /etc/pgbackrest/conf.d/50-secrets.conf; stat -c "%a %U:%G" /etc/pgbackrest/conf.d/50-secrets.conf' >"$OUT/03-secrets-perms.txt"
grep -q '640 root:postgres' "$OUT/03-secrets-perms.txt" || fail "secrets file perms"
docker exec "$NODE" sh -c 'stat -c "%n %a %U" /etc/fleet-company-db/fleet_gate.dsn /etc/fleet-company-db/fleet_worker.dsn /etc/fleet-company-db/fleet_gate.password' >>"$OUT/03-secrets-perms.txt"
res listen_addresses "$(su_sql "$NODE" 'show listen_addresses')"
res ss_listen "$(docker exec "$NODE" sh -c "ss -ltnH '( sport = :5432 )' | awk '{print \$4}' | sort | tr '\n' ' '")"
res server_version "$(su_sql "$NODE" 'show server_version')"
res archive_mode "$(su_sql "$NODE" 'show archive_mode')/$(su_sql "$NODE" 'show archive_timeout')"
res data_checksums "$(su_sql "$NODE" 'show data_checksums')"
res pgbackrest_version "$(docker exec "$NODE" pgbackrest version)"
res timers "$(docker exec "$NODE" sh -c 'systemctl list-timers --all --no-legend "fleet-db-*" | awk "{print \$NF}" | sort | tr "\n" " "')"

# ---------------------------------------------------------------- 4. idempotent re-run: no restart, no change
log "node: converge again (expect no change, no restart)"
st0="$(su_sql "$NODE" 'select pg_postmaster_start_time()')"
sum0="$(docker exec "$NODE" sh -c 'cat /etc/postgresql/16/main/conf.d/50-fleet-company-db.conf /etc/postgresql/16/main/pg_hba.conf /etc/pgbackrest/pgbackrest.conf /etc/pgbackrest/conf.d/50-secrets.conf /etc/fleet-company-db/fleet_gate.password | sha256sum')"
run_module >"$OUT/04-rerun.log" 2>&1 || fail "re-run failed"
st1="$(su_sql "$NODE" 'select pg_postmaster_start_time()')"
sum1="$(docker exec "$NODE" sh -c 'cat /etc/postgresql/16/main/conf.d/50-fleet-company-db.conf /etc/postgresql/16/main/pg_hba.conf /etc/pgbackrest/pgbackrest.conf /etc/pgbackrest/conf.d/50-secrets.conf /etc/fleet-company-db/fleet_gate.password | sha256sum')"
[[ "$st0" == "$st1" && "$sum0" == "$sum1" ]] || fail "re-run restarted postgres or changed managed files"
grep -q 'applying migration' "$OUT/04-rerun.log" && fail "re-run re-applied a migration"
res idempotent_rerun "ok (same postmaster start, same files, no migration)"

# ---------------------------------------------------------------- 5. seed + schema suite over loopback (DSN files)
log "node: operator seed (twice) + schema suite as fleet_gate / fleet_worker over 127.0.0.1"
docker exec "$NODE" /usr/local/sbin/fleet-company-db seed "$FIX/seed-proto.sql" >"$OUT/05-seed.log" 2>&1
docker exec "$NODE" /usr/local/sbin/fleet-company-db seed "$FIX/seed-proto.sql" >>"$OUT/05-seed.log" 2>&1
bash "$HERE/run-sql-tests.sh" "$NODE" node fleet_amforge | tee "$OUT/05-sql-suite.log"
grep -q '^FAIL' "$OUT/05-sql-suite.log" && fail "schema suite failed on the node"
# wrong password and non-loopback access are refused
if docker exec "$NODE" sh -c 'PGPASSWORD=wrong psql -X -h 127.0.0.1 -U fleet_gate -d fleet_amforge -c "select 1"' >/dev/null 2>&1; then fail "wrong password accepted"; fi
if docker exec "$NODE" sh -c 'psql -X -h 127.0.0.1 -U postgres -d fleet_amforge -c "select 1" </dev/null' >/dev/null 2>&1; then fail "postgres over TCP accepted"; fi
res auth_refusals "ok (wrong password, superuser over TCP refused)"

# ---------------------------------------------------------------- 6. health + memory containment
log "node: health/RPO probe + memory"
docker exec "$NODE" /usr/local/sbin/fleet-company-db status --json >"$OUT/06-status.json" || fail "status unhealthy: $(cat "$OUT/06-status.json")"
res status_healthy "$(grep -o '"healthy":[a-z]*' "$OUT/06-status.json")"
docker exec "$NODE" systemctl show -p MemoryHigh -p MemoryMax -p MemoryCurrent postgresql@16-main.service >"$OUT/06-memory-idle.txt"
res pg_memory_idle "$(tr '\n' ' ' <"$OUT/06-memory-idle.txt")"

# ---------------------------------------------------------------- 6b. bucket outage: the record closes for writes, then reopens
# (review r1 BLOCKER [1]). Nothing is faked: MinIO is stopped, the gate keeps writing every 5 s, and the
# node's own health timer / the in-band archiver check must refuse writes within the 5-min RPO budget.
upd() { gate_sql "$NODE" "select fleet.update_task('amforge', '$TASK', (select version from fleet.tasks where id = '$TASK'), jsonb_build_object('status', 'outage-' || $1), '$ED', 'fleet-gate', 'req-outage-' || lpad('$1', 6, '0'))" 2>&1; }
log "outage: bucket DOWN (MinIO stopped); gate writes every 5 s until refused"
docker stop "$MINIO" >/dev/null; t0=$(date +%s); n=0; closed=""
while (( $(date +%s) - t0 < 330 )); do
  n=$((n+1)); r="$(upd "$n" || true)"
  if grep -q 'record closed for writes' <<<"$r"; then closed="$r"; break; fi
  sleep 5
done
[[ -n "$closed" ]] || fail "writes still accepted 330 s into a bucket outage"
res outage_writes_refused_after_seconds "$(( $(date +%s) - t0 )) ($n attempts; $(grep -o 'record closed for writes: .*' <<<"$closed" | head -1))"
docker exec "$NODE" /usr/local/sbin/fleet-company-db status --json >"$OUT/06b-status-outage.json" 2>&1 || true
res outage_status "$(grep -oE '"writes":"[a-z]+"|"healthy":[a-z]+' "$OUT/06b-status-outage.json" | tr '\n' ' ')"
su_sql "$NODE" "select at || ' ' || (detail->>'reason') from fleet.audit where action = 'record.close' order by id desc limit 1" >"$OUT/06b-close-audit.txt" || true
log "outage: bucket UP again; expect writes to resume"
docker start "$MINIO" >/dev/null; t0=$(date +%s); reopened=""
while (( $(date +%s) - t0 < 330 )); do
  n=$((n+1)); r="$(upd "$n" || true)"
  [[ "$r" =~ ^[0-9]+$ ]] && { reopened=1; break; }
  sleep 5
done
[[ -n "$reopened" ]] || fail "writes still refused 330 s after the bucket came back"
res outage_writes_resumed_after_seconds "$(( $(date +%s) - t0 ))"
docker exec "$NODE" /usr/local/sbin/fleet-company-db status --json >"$OUT/06b-status-after.json" || fail "unhealthy after the outage"

# ---------------------------------------------------------------- 7. workload, diff backup, PITR mark, host loss
log "node: workload for ${WORKLOAD_SECONDS}s (one task update every 2 s), diff backup at 20 s, PITR mark at 60 s"
docker exec -d "$NODE" bash /opt/bootstrap/tests/fleet-company-db/writer.sh "$(( WORKLOAD_SECONDS + 30 ))"
sleep 20
docker exec "$NODE" /usr/local/sbin/fleet-company-db backup diff >"$OUT/07-diff-backup.log" 2>&1 || fail "diff backup failed"
sleep 38
PITR_ROW="$(su_sql "$NODE" "select to_char(now() at time zone 'utc', 'YYYY-MM-DD HH24:MI:SS.US') || '+00|' || body from fleet.tasks where id = '$TASK'")"
PITR="${PITR_ROW%%|*}"; PITR_MARKER="${PITR_ROW#*|}"   # target and the state seen by the same snapshot
res pitr_target "$PITR"; res pitr_marker_at_target "$PITR_MARKER"
sleep 2
docker exec "$NODE" systemctl show -p MemoryCurrent -p MemoryPeak postgresql@16-main.service >"$OUT/07-memory-load.txt" || true
res pg_memory_under_load "$(tr '\n' ' ' <"$OUT/07-memory-load.txt")"
sleep $(( WORKLOAD_SECONDS - 60 ))
log "node: HOST LOSS (SIGKILL, no shutdown, no final archive)"
docker kill -s KILL "$NODE" >/dev/null
KILL_AT="$(date -u +'%Y-%m-%d %H:%M:%S')"
res host_killed_at "$KILL_AT"
docker cp "$NODE:/root/writer.log" "$OUT/07-writer.log"
LAST_ACK="$(grep -E '^[0-9]+ [0-9]+ [0-9-]+ [0-9:.]+$' "$OUT/07-writer.log" | tail -1)"
res last_acknowledged_write "$LAST_ACK"
grep -vE '^[0-9]+ [0-9]+ [0-9-]+ [0-9:.]+$' "$OUT/07-writer.log" | head -3 >"$OUT/07-writer-errors.txt" || true

# ---------------------------------------------------------------- 8. drill: restore latest on a fresh host
log "drill 1: FRESH host, restore latest from the bucket alone"
start_host "$DRILL1" h-drill-1; put_items "$DRILL1"
t0=$(date +%s)
docker exec "$DRILL1" /opt/bootstrap/fleet-company-db/bin/fleet-company-db drill-restore --desired "$FIX/h-proto.env" --latest >"$OUT/08-drill-latest.log" 2>&1 \
  || { tail -30 "$OUT/08-drill-latest.log"; fail "drill restore (latest) failed"; }
t1=$(date +%s); res rto_restore_latest_seconds "$((t1 - t0)) (incl. package install)"
REST="$(su_sql "$DRILL1" "select body || ' ' || version from fleet.tasks where id = '$TASK'")"
res restored_latest "$REST"
REST_N="${REST#marker }"; REST_N="${REST_N%% *}"
ACK_N="${LAST_ACK%% *}"; ACK_T="$(cut -d' ' -f3- <<<"$LAST_ACK")"
REST_T="$(grep -E "^$REST_N " "$OUT/07-writer.log" | cut -d' ' -f3-)"
RPO_S="$(python3 -c "import datetime as d,sys; f='%Y-%m-%d %H:%M:%S.%f'; print(round((d.datetime.strptime(sys.argv[1],f)-d.datetime.strptime(sys.argv[2],f)).total_seconds(),1))" "$ACK_T" "$REST_T")"
res rpo_lost_writes "$((ACK_N - REST_N)) of $ACK_N"
res rpo_seconds "$RPO_S (last acknowledged write $ACK_T vs last restored write $REST_T)"
python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) <= 300 else 1)" "$RPO_S" || fail "RPO above 5 min"
su_sql "$DRILL1" "select count(*) from fleet.task_history where task_id = '$TASK'" >"$OUT/08-history-count.txt"
res drill_archive_mode "$(su_sql "$DRILL1" 'show archive_mode')"
res drill_append_only "$(docker exec -i "$DRILL1" runuser -u postgres -- psql -X -q -At -d fleet_amforge -c "update fleet.task_history set field = 'x'" 2>&1 | grep -o 'not allowed' | head -1)"
docker exec "$DRILL1" runuser -u postgres -- pgbackrest --stanza=amforge info >"$OUT/08-pgbackrest-info.txt" 2>&1

# ---------------------------------------------------------------- 9. drill: point-in-time on another fresh host
log "drill 2: FRESH host, point-in-time restore to $PITR"
start_host "$DRILL2" h-drill-2; put_items "$DRILL2"
t0=$(date +%s)
docker exec "$DRILL2" /opt/bootstrap/fleet-company-db/bin/fleet-company-db drill-restore --desired "$FIX/h-proto.env" --target "$PITR" >"$OUT/09-drill-pitr.log" 2>&1 \
  || { tail -30 "$OUT/09-drill-pitr.log"; fail "drill restore (PITR) failed"; }
t1=$(date +%s); res rto_restore_pitr_seconds "$((t1 - t0)) (incl. package install)"
GOT="$(su_sql "$DRILL2" "select body from fleet.tasks where id = '$TASK'")"
res restored_pitr "$GOT"
[[ "$GOT" == "$PITR_MARKER" ]] || fail "PITR restored '$GOT', expected '$PITR_MARKER'"
res pitr_exact "ok"

# ---------------------------------------------------------------- 10. tidy (containers only; logs stay in OUT)
for c in "$NODE" "$DRILL1" "$DRILL2" "$MINIO"; do docker rm -f "$c" >/dev/null 2>&1 || true; done
docker network rm "$NET" >/dev/null 2>&1 || true
rm -f "$OUT/certs/ca.key" "$OUT/certs/private.key"
log "ALL PASSED. Evidence: $OUT"
