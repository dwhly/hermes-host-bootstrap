#!/usr/bin/env bash
# Mutation check for fleet-trace-retention: each load-bearing guard removed in turn must make the suite FAIL.
set -u
cd "$(dirname "$0")/.." || exit 2
S=scripts/fleet-trace-retention
cp "$S" /tmp/ftr-orig
trap 'cp /tmp/ftr-orig "$S"' EXIT
mutate() {  # name, python replace old->new (exact, must occur once)
  python3 - "$S" "$2" "$3" <<'EOF'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
assert s.count(old) == 1, (old, s.count(old))
open(p, "w").write(s.replace(old, new))
EOF
  if bash tests/run_fleet_trace_retention.sh >/tmp/ftr-mut.log 2>&1; then echo "SURVIVED  $1"; else echo "killed    $1 ($(grep -cE '^(FAIL|ERROR):' /tmp/ftr-mut.log) failing)"; fi
  cp /tmp/ftr-orig "$S"
}
mutate keep_days        'if rc["copied_at"] > cutoff:' 'if False:'
mutate content_hash     'if sha != rc["sha"] or n != rc["message_count"]:' 'if False:'
mutate job_binding      'if rc["job_id"] not in jobs:' 'if False:'
mutate ended            'if ended_at is None:' 'if False:'
mutate pinned           'if pinned:' 'if False:'
mutate active_job       'if any(states.get(j) in ACTIVE_JOB_STATES or states.get(j) == "unreadable" for j in jobs):' 'if False:'
mutate delegates        'if covered != rc["covered"]:' 'if False:'
mutate min_keep         'if args.keep_days < MIN_KEEP_DAYS:' 'if False:'
mutate store_unreadable 'if report["copy_store"]["readable"] is False:
                report["deleted"] = []
            else:
                report = apply(args, report)' 'report = apply(args, report)'
mutate password_dsn     'if re.search(r"password\s*=|://[^/@\s]*:[^/@\s]*@", dsn, re.I):' 'if False:'
mutate native_prune     'np_["at_risk"] = bool(np_["enabled"]) and bool(no_copy)' 'np_["at_risk"] = False'
mutate hash_version     'or r.get("hash_version") != HASH_VERSION:' ':'
mutate tz_required      'if at.tzinfo is None:
        return None' 'pass'
