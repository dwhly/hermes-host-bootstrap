#!/usr/bin/env bash
# Quick loop: fresh postgres:16 container, apply migrations + grants + seed the way the runner does,
# then the schema behaviour tests. No ports published; removed afterwards.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; P="$HERE/../../fleet-company-db"; C=fcdb-syntax; DB=fleet_amforge
docker rm -f "$C" >/dev/null 2>&1 || true
docker run -d --name "$C" --memory 384m -e POSTGRES_PASSWORD=unused --tmpfs /var/lib/postgresql/data postgres:16-alpine >/dev/null
for _ in $(seq 1 30); do docker exec "$C" pg_isready -q -U postgres 2>/dev/null && break; sleep 1; done
sleep 2
docker exec -i "$C" psql -q -U postgres -v ON_ERROR_STOP=1 -c "CREATE ROLE fleet_owner NOLOGIN" -c "CREATE DATABASE $DB OWNER fleet_owner"
for f in "$P"/migrations/[0-9][0-9][0-9][0-9]_*.sql; do
  { echo "BEGIN; SET LOCAL ROLE fleet_owner;"; cat "$f"; echo "COMMIT;"; } | docker exec -i "$C" psql -q -U postgres -d "$DB" -v ON_ERROR_STOP=1
done
docker exec -i "$C" psql -q -U postgres -d "$DB" -v ON_ERROR_STOP=1 <"$P/sql/roles-and-grants.sql"
docker exec -i "$C" psql -q -U postgres -d "$DB" -v ON_ERROR_STOP=1 <"$P/sql/roles-and-grants.sql"   # idempotent
docker exec "$C" psql -q -U postgres -d "$DB" -c "INSERT INTO fleet.company(id) VALUES ('amforge')"
for _ in 1 2; do   # the seed is re-runnable
  { echo "BEGIN; SET LOCAL ROLE fleet_owner;"; cat "$HERE/fixtures/seed-proto.sql"; echo "COMMIT;"; } \
    | docker exec -i "$C" psql -q -At -U postgres -d "$DB" -v ON_ERROR_STOP=1 >/dev/null
done
rc=0; bash "$HERE/run-sql-tests.sh" "$C" trust "$DB" || rc=$?
docker rm -f "$C" >/dev/null
exit $rc
