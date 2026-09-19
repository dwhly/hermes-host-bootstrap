#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

bash -n "$ROOT/verify.sh"

mkdir -p "$TMP/bin"
VERIFY_UNDER_TEST="$TMP/verify.sh"
METADATA="$TMP/hosts.yaml"
sed "s#/opt/hermes-config-baseline/fleet/hosts.yaml#$METADATA#g" "$ROOT/verify.sh" >"$VERIFY_UNDER_TEST"

write_hostname_stub() {
  local short="$1"
  cat >"$TMP/bin/hostname" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == "-s" ]]; then
  printf '%s\n' "$short"
else
  printf '%s.example\n' "$short"
fi
SH
  chmod +x "$TMP/bin/hostname"
}

write_metadata() {
  local availability="$1"
  cat >"$METADATA" <<YAML
fleet:
  name: test
  boss: h-do1
hosts:
  - hostname: h-other
    responsibilities: [unrelated]
  - hostname: h-btp
    role: server
    management:
      mode: managed
      runtime_user: hermes
      hermes_home: /home/hermes/.hermes
      interactive_access: direct
    responsibilities:
      - btp-environment-work
    credential_scopes:
      - provider: 1password
        vault: agent
        mode: read-only
        availability: $availability
    resource_policy:
      build_host: false
      central_stack: false
YAML
}

run_verify_json() {
  TIER=minimal CHIEF_NODE_ROLE=server PATH="$TMP/bin:/usr/bin:/bin" \
    bash -c 'source "$1"; HERMES_VERIFY_CHECKS=(); verify_check "sentinel" "false" "harness" "printf '\''%s\n'\'' v1"; verify_json' _ "$VERIFY_UNDER_TEST"
}

assert_pending_shape() {
  local json_file="$1"
  /usr/bin/python3 - "$json_file" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
checks = data["checks"]
assert data["schema_version"] == 2
assert [item["name"] for item in checks] == ["sentinel", "btp-responsibility", "btp-credential"]
assert checks[0]["status"] == "ok"
assert checks[0]["version"] == "v1"
assert checks[0]["detail"] == "ok"
resp = checks[1]
cred = checks[2]
assert resp == {
    "name": "btp-responsibility",
    "required": False,
    "status": "ok",
    "detail": "BTP development/integrations; not shared fleet build host or fleet boss",
    "category": "harness",
}
assert "version" not in resp
assert cred == {
    "name": "btp-credential",
    "required": False,
    "status": "missing",
    "detail": "1Password agent read-only availability pending (operator-reported)",
    "category": "harness",
}
assert "version" not in cred
assert all(len(item["detail"]) <= 256 for item in checks[1:])
PY
}

assert_credential_state() {
  local json_file="$1" expected_status="$2" expected_detail="$3"
  /usr/bin/python3 - "$json_file" "$expected_status" "$expected_detail" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
cred = [item for item in data["checks"] if item["name"] == "btp-credential"][0]
assert cred["status"] == sys.argv[2]
assert cred["detail"] == sys.argv[3]
assert len(cred["detail"]) <= 256
PY
}

write_hostname_stub "h-btp"
write_metadata "pending"
run_verify_json >"$TMP/pending.json"
assert_pending_shape "$TMP/pending.json"

write_metadata "unavailable"
run_verify_json >"$TMP/unavailable.json"
assert_credential_state "$TMP/unavailable.json" "error" "1Password agent read-only availability unavailable (operator-reported)"

write_metadata "verified"
run_verify_json >"$TMP/verified.json"
assert_credential_state "$TMP/verified.json" "ok" "1Password agent read-only availability verified (operator-reported)"

long_raw="raw,quoted,\"$(printf 'x%.0s' {1..300})"
cat >"$METADATA" <<YAML
hosts:
  - hostname: h-btp
    responsibilities: btp-environment-work
    credential_scopes:
      provider: 1password
      vault: agent
      mode: read-only
      availability: "$long_raw"
    resource_policy: wrong-type
YAML
run_verify_json >"$TMP/wrong-types.json"
/usr/bin/python3 - "$TMP/wrong-types.json" "$long_raw" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
raw = sys.argv[2]
for name in ("btp-responsibility", "btp-credential"):
    check = [item for item in data["checks"] if item["name"] == name][0]
    assert check["status"] == "error"
    assert raw not in check["detail"]
    assert len(check["detail"]) <= 256
assert [item["name"] for item in data["checks"]] == ["sentinel", "btp-responsibility", "btp-credential"]
PY

printf '%s\n' 'hosts: [' >"$METADATA"
run_verify_json >"$TMP/malformed.json"
/usr/bin/python3 - "$TMP/malformed.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
for name in ("btp-responsibility", "btp-credential"):
    check = [item for item in data["checks"] if item["name"] == name][0]
    assert check["status"] == "error"
    assert check["detail"] == "approved h-btp metadata invalid"
PY

write_hostname_stub "h-do1"
rm -f "$METADATA"
parser_log="$TMP/parser.log"
cat >"$TMP/bin/python3" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == "-" ]]; then
  printf 'parser invoked\n' >>"$parser_log"
  exit 97
fi
exec /usr/bin/python3 "\$@"
SH
chmod +x "$TMP/bin/python3"
run_verify_json >"$TMP/non-host.json"
[[ ! -e "$parser_log" ]] || fail "non-h-btp host attempted metadata parsing"
/usr/bin/python3 - "$TMP/non-host.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
assert [item["name"] for item in data["checks"]] == ["sentinel"]
assert data["checks"][0]["detail"] == "ok"
PY

write_hostname_stub "h-btp"
write_metadata "pending"
cat >"$TMP/bin/python3" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-" ]]; then
  printf 'error\tapproved h-btp metadata parser unavailable\terror\tapproved h-btp metadata parser unavailable\n'
  exit 0
fi
exec /usr/bin/python3 "$@"
SH
chmod +x "$TMP/bin/python3"
run_verify_json >"$TMP/parser-unavailable.json"
/usr/bin/python3 - "$TMP/parser-unavailable.json" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
for name in ("btp-responsibility", "btp-credential"):
    check = [item for item in data["checks"] if item["name"] == name][0]
    assert check["status"] == "error"
    assert check["detail"] == "approved h-btp metadata parser unavailable"
PY

UNIT="$ROOT/systemd/h-btp/chief-node.service"
[[ -f "$UNIT" ]] || fail "h-btp telemetry unit missing"
grep -qx 'Wants=network-online.target' "$UNIT" || fail "h-btp unit wants network-online only"
grep -qx 'After=network-online.target' "$UNIT" || fail "h-btp unit after line is not bounded"
grep -qx 'Type=simple' "$UNIT" || fail "h-btp unit type changed"
grep -qx 'EnvironmentFile=-/etc/chief/node.env' "$UNIT" || fail "h-btp unit env file missing"
grep -qx 'Environment=HOME=/root' "$UNIT" || fail "h-btp unit HOME missing"
grep -qx 'Environment=HERMES_BOOTSTRAP_DIR=/root/hermes-host-bootstrap' "$UNIT" || fail "h-btp bootstrap dir missing"
grep -qx 'WorkingDirectory=/root/code/chief/hermes-node' "$UNIT" || fail "h-btp working directory wrong"
grep -qx 'ExecStart=/root/code/chief/hermes-node/.venv/bin/python -m hermes_node.daemon run --node-id h-btp --core ${CHIEF_CORE_URL} --interval 60' "$UNIT" || fail "h-btp exec start wrong"
grep -qx 'Restart=on-failure' "$UNIT" || fail "restart policy missing"
grep -qx 'RestartSec=10' "$UNIT" || fail "restart delay missing"
grep -qx 'StartLimitIntervalSec=600' "$UNIT" || fail "start limit interval missing"
grep -qx 'StartLimitBurst=5' "$UNIT" || fail "start limit burst missing"
grep -qx 'RestartPreventExitStatus=75' "$UNIT" || fail "prevent exit status missing"
grep -qx 'User=root' "$UNIT" || fail "h-btp user wrong"
grep -qx 'Group=root' "$UNIT" || fail "h-btp group wrong"
grep -qx 'WantedBy=multi-user.target' "$UNIT" || fail "install target missing"
! grep -Eq '^(Requires|ExecStartPre|ExecStartPost)=' "$UNIT" || fail "h-btp unit contains forbidden requirement/hook"
! grep -Eq 'reconcile|supervisor|converger' "$UNIT" || fail "h-btp unit contains convergence coupling"

grep -q 'chief-node-reconcile.service' "$ROOT/systemd/chief-node.service" || fail "existing converging unit no longer references reconcile"
grep -qx 'Group=chief' "$ROOT/systemd/chief-node.service" || fail "existing converging unit group changed"

pass "h-btp verifier notes and telemetry-only unit contract"
