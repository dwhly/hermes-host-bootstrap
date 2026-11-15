#!/usr/bin/env bash
# Prototype workload: as the gate (DSN file), update the disposable task's body to "marker <n>" every 2 s and
# log "<n> <new version> <commit time UTC>" only after the call returned (= acknowledged write).
#   writer.sh <seconds>
set -u
TASK=00000000-0000-4000-8000-00000000a001; ED=00000000-0000-4000-8000-0000000000e1
end=$(( $(date +%s) + ${1:-150} )); n=0
DSN="$(cat /etc/fleet-company-db/fleet_gate.dsn)"
while [ "$(date +%s)" -lt "$end" ]; do
  n=$((n + 1))
  r="$(psql "$DSN" -X -q -At -v n="$n" -v task="$TASK" -v ed="$ED" 2>&1 <<'SQL'
SELECT fleet.update_task('amforge', :'task', (SELECT version FROM fleet.tasks WHERE id = :'task'),
                         jsonb_build_object('body', 'marker ' || :'n'), :'ed', 'proto-writer', 'req-marker-' || :'n')
       || ' ' || to_char(clock_timestamp() AT TIME ZONE 'utc', 'YYYY-MM-DD HH24:MI:SS.US');
SQL
)"
  echo "$n $r" >>/root/writer.log
  sync /root/writer.log
  sleep 2
done
