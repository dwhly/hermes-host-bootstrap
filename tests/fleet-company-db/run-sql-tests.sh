#!/usr/bin/env bash
# Runs the schema behaviour tests (sql/*.sql) against a seeded database in a container.
#   run-sql-tests.sh <container> trust [db]   plain postgres image (local trust auth), quick loop
#   run-sql-tests.sh <container> node  [db]   a fleet-company-db node: gate/worker log in over loopback
#                                             with the generated DSN files, exactly as T3's gate will
set -euo pipefail
C="$1"; MODE="$2"; DB="${3:-fleet_amforge}"
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0

psql_as() {  # psql_as <role> <psql args...>; SQL on stdin or -c
  local role="$1"; shift
  if [[ "$MODE" == trust ]]; then
    docker exec -i "$C" psql -X -q -At -U "$role" -d "$DB" -v ON_ERROR_STOP=1 "$@"
  elif [[ "$role" == postgres ]]; then
    docker exec -i "$C" runuser -u postgres -- psql -X -q -At -d "$DB" -v ON_ERROR_STOP=1 "$@"
  else
    docker exec -i "$C" sh -c 'psql "$(cat /etc/fleet-company-db/'"$role"'.dsn)" -X -q -At -v ON_ERROR_STOP=1 "$@"' sh "$@"
  fi
}

run_as() {  # run_as <role> <file>
  local role="$1" file="$2" out
  out="$(psql_as "$role" <"$file" 2>&1)" || true
  if grep -q '^PASS:' <<<"$out" && ! grep -qE 'ERROR|TESTFAIL' <<<"$out"; then
    echo "ok   $(basename "$file") as $role: $(grep '^PASS:' <<<"$out")"
  else
    echo "FAIL $(basename "$file") as $role:"; sed 's/^/     /' <<<"$out" | tail -15; fail=1
  fi
}

run_as fleet_gate   "$HERE/sql/10-gate.sql"
run_as fleet_worker "$HERE/sql/20-worker.sql"

# SKIP LOCKED: while one worker holds a claim inside an open transaction, a second worker
# gets the OTHER job at once instead of blocking.
skip_test() {
  local t0 t1 got ms
  psql_as fleet_worker -c "BEGIN; SELECT fleet.job_claim('w-hold', ARRAY['skip'], 60); SELECT pg_sleep(6); COMMIT;" >/dev/null 2>&1 &
  sleep 1; t0=$(date +%s%N)
  got="$(psql_as fleet_worker -c "SELECT (fleet.job_claim('w-fast', ARRAY['skip'], 60))->'payload'->>'n'" 2>&1)"
  t1=$(date +%s%N); ms=$(( (t1 - t0) / 1000000 ))
  if [[ "$got" =~ ^[56]$ ]] && (( ms < 2000 )); then echo "ok   skip-locked: second worker got job n=$got in ${ms}ms"
  else echo "FAIL skip-locked: got '$got' after ${ms}ms"; fail=1; fi
  wait
}
skip_test
run_as fleet_worker "$HERE/sql/30-worker-lease.sql"
run_as postgres     "$HERE/sql/35-recovery-and-fence.sql"
run_as postgres     "$HERE/sql/40-superuser.sql"
exit $fail
