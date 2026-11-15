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
mutate keep_days        'if rc["copied_at"] > ctx.cutoff:' 'if False:'
mutate content_hash     'if sha != rc["sha"] or n != rc["message_count"]:' 'if False:'
mutate job_binding      'if rc["job_id"] not in jobs:' 'if False:'
mutate ended            'if row is None or row[0] is None:' 'if row is None:'
mutate pinned           'if row[1]:' 'if False:'
mutate active_job       'if any(st.get(j) in ACTIVE_JOB_STATES' 'if False and any(st.get(j) in ACTIVE_JOB_STATES'
mutate delegates        'if covered != rc["covered"]:' 'if False:'
mutate min_keep         'if args.keep_days < MIN_KEEP_DAYS:' 'if False:'
mutate delegate_sql     'if row[0] not in found:' 'if False:'
mutate plan_no_lock     'if args.apply:
        lock_path' 'if True:
        lock_path'
mutate password_dsn     'if re.search(r"password\s*=|://[^/@\s]*:[^/@\s]*@", dsn, re.I):' 'if False:'
mutate native_prune     'np_["at_risk"] = np_["enabled"] is not False and unverified > 0' 'np_["at_risk"] = False'
mutate unverified_count 'if not info["verified"]:' 'if False:'
mutate defaults_as_data 'default = default_sessions(src) if src_ok else {}' 'default = {}'
mutate hash_version     'or r.get("hash_version") != HASH_VERSION:' ':'
mutate tz_required      'if at.tzinfo is None:
        return None' 'pass'
mutate any_malformed    'store["usable"] = False' 'store["usable"] = store["readable"] is True'
mutate duplicate        'if pr is None or pr["session_id"] in seen:' 'if pr is None:'
mutate fresh_job_state  'fresh_states=True)' 'states={j: "done" for j in ctx.bindings.get(session_id, ())})'
mutate source_pin       'if digest not in DELETE_SOURCE_SHA256:' 'if False:'
mutate in_tx_check      'return token if reason is None else None' 'return token'
