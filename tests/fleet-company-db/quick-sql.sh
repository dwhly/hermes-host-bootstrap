#!/usr/bin/env bash
# Quick loop: fresh postgres:16 container, apply migrations + grants + seed the way the runner does
# (each migration and the grants in ONE transaction), then the schema behaviour tests. Archiving is on
# (to /bin/true) because the record refuses writes when it is off. No ports published; removed afterwards.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; P="$HERE/../../fleet-company-db"; C=fcdb-syntax; DB=fleet_amforge
docker rm -f "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" --memory 384m -e POSTGRES_PASSWORD=unused --tmpfs /var/lib/postgresql/data postgres:16-alpine \
  -c archive_mode=on -c archive_command=/bin/true >/dev/null
for _ in $(seq 1 30); do docker exec "$C" pg_isready -q -U postgres 2>/dev/null && break; sleep 1; done
sleep 2
docker exec -i "$C" psql -q -U postgres -v ON_ERROR_STOP=1 -c "CREATE ROLE fleet_owner NOLOGIN" -c "CREATE DATABASE $DB OWNER fleet_owner"
docker exec -i "$C" psql -q -U postgres -d "$DB" -v ON_ERROR_STOP=1 \
  -c "ALTER DEFAULT PRIVILEGES FOR ROLE fleet_owner REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC"
for f in "$P"/migrations/[0-9][0-9][0-9][0-9]_*.sql; do
  { echo "BEGIN; SET LOCAL ROLE fleet_owner;"; cat "$f"; echo "RESET ROLE;"; cat "$P/sql/roles-and-grants.sql"; echo "COMMIT;"; } \
    | docker exec -i "$C" psql -q -U postgres -d "$DB" -v ON_ERROR_STOP=1
done
docker exec -i "$C" psql -q -U postgres -d "$DB" -v ON_ERROR_STOP=1 -1 <"$P/sql/roles-and-grants.sql"   # idempotent
# review r1 [4]: no fleet function is PUBLIC-executable, ever
pub="$(docker exec "$C" psql -At -U postgres -d "$DB" -c "select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'fleet' and has_function_privilege('public', p.oid, 'EXECUTE')")"
[[ "$pub" == 0 ]] && echo "ok   no PUBLIC EXECUTE on any fleet function" || { echo "FAIL $pub fleet functions PUBLIC-executable"; exit 1; }
docker exec "$C" psql -q -U postgres -d "$DB" -c "INSERT INTO fleet.company(id) VALUES ('amforge')"
for _ in 1 2; do   # the seed is re-runnable
  { echo "BEGIN; SET LOCAL ROLE fleet_owner;"; cat "$HERE/fixtures/seed-proto.sql"; echo "COMMIT;"; } \
    | docker exec -i "$C" psql -q -At -U postgres -d "$DB" -v ON_ERROR_STOP=1 >/dev/null
done
rc=0; bash "$HERE/run-sql-tests.sh" "$C" trust "$DB" || rc=$?
docker rm -f "$C" >/dev/null
exit $rc
