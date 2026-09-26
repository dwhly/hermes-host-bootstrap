#!/usr/bin/env bash
# Offline/no-root/no-credentials: every SSH, update, refresh and HTTP call is stubbed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/hosts" "$TMP/bootstrap"
export FIXTURE_LOG="$TMP/calls"
export HOME="$TMP/home" HERMES_HOME="$TMP/home/.hermes"
export FIXTURE_BASELINE="$TMP/opt/hermes-config-baseline/fleet/hosts.yaml"
export REAL_PYTHON FIXTURE_RUNNER="$TMP/python-fixture.py"
REAL_PYTHON="$(command -v python3)"
cat >"$FIXTURE_RUNNER" <<'PYTHON'
import os
from pathlib import Path
import runpy
import sys
sys.argv = sys.argv[1:]
sys.path.insert(0, str(Path(sys.argv[0]).parent))
from desktop_fleet import common
common.BASELINE_INTENT = Path(os.environ['FIXTURE_BASELINE'])
runpy.run_path(sys.argv[0], run_name='__main__')
PYTHON
cat >"$TMP/bin/python3" <<'SHIM'
#!/usr/bin/env bash
options=()
[[ -z "${FIXTURE_NO_YAML:-}" ]] || options+=(-S)
if [[ "${1:-}" == */desktop-fleet-policy.py ]]; then
  exec "$REAL_PYTHON" "${options[@]}" "$FIXTURE_RUNNER" "$@"
fi
exec "$REAL_PYTHON" "${options[@]}" "$@"
SHIM
chmod +x "$TMP/bin/python3"
export HERMES_FLEET_HOSTS_DIR="$TMP/hosts" HERMES_FLEET_INTENT="$TMP/intent.json"
export CHIEF_BOOTSTRAP_SRC="$TMP/bootstrap"
export PATH="$TMP/bin:$PATH"
cat >"$TMP/intent.json" <<'JSON'
{"hosts":[{"hostname":"h-af","update_policy":"protected"},{"hostname":"h-btp","update_policy":"protected"},{"hostname":"h-do1","update_policy":"protected"},{"hostname":"marker","update_policy":"eligible"},{"hostname":"mac","update_policy":"eligible"}]}
JSON
for host in h-af h-btp h-do1 marker mac; do
  cat >"$TMP/hosts/$host.yaml" <<YAML
ssh_user: fixture
ssh_host: $host
kind: macos
YAML
done
cat >"$TMP/bin/ssh" <<'SHIM'
#!/usr/bin/env bash
set -eu
printf 'ssh %s\n' "$*" >>"$FIXTURE_LOG"
case "$*" in
  *fixture@h-af*|*fixture@h-btp*|*fixture@h-do1*) echo 'registry protected host reached SSH' >&2; exit 99 ;;
  *fixture@marker*)
    [[ "$*" == *image-provenance.json* ]] || exit 99
    exit 3 ;;
  *image-provenance.json*)
    [[ "$*" == *StrictHostKeyChecking=accept-new* ]] || exit 99
    if [[ -n "${FIXTURE_SLEEP_ONCE:-}" && ! -e "$FIXTURE_SLEEP_ONCE" ]]; then
      touch "$FIXTURE_SLEEP_ONCE"
      exit 255
    fi
    exit "${FIXTURE_MARKER_RC:-0}" ;;
  *'hermes --version'*) echo 'Hermes v0.20.0' ;;
  *) exit 0 ;;
esac
SHIM
cat >"$TMP/bin/curl" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' '{"hermes_version":"0.20.0"}'
SHIM
cat >"$TMP/bin/sleep" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
cat >"$TMP/bootstrap/deploy-node.sh" <<'SHIM'
#!/usr/bin/env bash
printf 'deploy-node %s\n' "$*" >>"$FIXTURE_LOG"
SHIM
chmod +x "$TMP/bin/ssh" "$TMP/bin/curl" "$TMP/bin/sleep" "$TMP/bootstrap/deploy-node.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
bash "$ROOT/fleet-upgrade.sh" all --include-self >"$TMP/all.out" 2>&1 || fail 'all failed'
for host in h-af h-btp h-do1 marker; do
  grep -q "\[fleet-upgrade $host\].*protected" "$TMP/all.out" || fail "$host not reported protected"
done
grep -q 'fixture@mac.*hermes update' "$FIXTURE_LOG" || fail 'eligible fixture never updated'
grep -q 'deploy-node mac' "$FIXTURE_LOG" || fail 'eligible fixture never refreshed'
! grep -q 'fixture@h-' "$FIXTURE_LOG" || fail 'registry protected hosts touched'
! grep -q 'fixture@marker.*hermes update' "$FIXTURE_LOG" || fail 'marker host updated'
for host in h-af h-btp h-do1 marker; do
  : >"$FIXTURE_LOG"
  if bash "$ROOT/fleet-upgrade.sh" "$host" >"$TMP/direct.out" 2>&1; then
    fail "$host direct update was allowed"
  fi
  grep -q 'direct protected-host update refused' "$TMP/direct.out" || fail 'direct refusal unclear'
  ! grep -qE 'hermes update|gateway start|deploy-node' "$FIXTURE_LOG" || fail 'direct attempt mutated host'
done
: >"$FIXTURE_LOG"
if FIXTURE_MARKER_RC=255 bash "$ROOT/fleet-upgrade.sh" mac >"$TMP/unknown.out" 2>&1; then
  fail 'unknown marker state allowed update'
fi
grep -q 'indeterminate' "$TMP/unknown.out" || fail 'unknown marker state not explicit'
! grep -q 'hermes update' "$FIXTURE_LOG" || fail 'unknown marker state mutated host'
cp "$ROOT/tests/fixtures/desktop-missing-hosts.yaml" "$TMP/intent.json"
: >"$FIXTURE_LOG"
bash "$ROOT/fleet-upgrade.sh" mac >"$TMP/missing-legacy.out" 2>&1 || fail 'missing host in undeclared Intent blocked'
grep -q 'hermes update' "$FIXTURE_LOG" || fail 'undeclared missing host did not take legacy flow'
printf '%s\n' '{"complete":false,"hosts":[]}' >"$TMP/intent.json"
: >"$FIXTURE_LOG"
if bash "$ROOT/fleet-upgrade.sh" mac >"$TMP/no-policy.out" 2>&1; then
  fail 'missing policy allowed update'
fi
[[ ! -s "$FIXTURE_LOG" ]] || fail 'missing policy reached SSH'
printf '%s\n' '{"hosts":[{"hostname":"mac","update_policy":"eligible"},{"hostname":"h-do1","update_policy":"eligible"}]}' >"$TMP/intent.json"
: >"$FIXTURE_LOG"
FIXTURE_SLEEP_ONCE="$TMP/woken" bash "$ROOT/fleet-upgrade.sh" mac >"$TMP/wake.out" 2>&1 || fail 'sleeping Mac not retried'
[[ "$(grep -c image-provenance.json "$FIXTURE_LOG")" == 2 ]] || fail 'probe must retry exactly once'
grep -q 'hermes update' "$FIXTURE_LOG" || fail 'awake Mac not updated'
: >"$FIXTURE_LOG"
if bash -c 'source "$1/fleet-upgrade.sh"; local_marker_status() { return 3; }; main h-do1' _ "$ROOT" >"$TMP/local.out" 2>&1; then
  fail 'eligible h-do1 local marker bypassed'
fi
grep -q 'protected (image-provenance marker)' "$TMP/local.out" || fail 'local marker not reported'
[[ ! -s "$FIXTURE_LOG" ]] || fail 'local marker reached SSH/deploy'

# Existing upgrade flows remain available without the new rollout schema/dependency.
printf '%s\n' '{"hosts":[{"hostname":"mac"}]}' >"$TMP/intent.json"
bash "$ROOT/fleet-upgrade.sh" mac >"$TMP/legacy.out" 2>&1 || fail 'legacy policy blocked'
rm "$TMP/intent.json"
bash "$ROOT/fleet-upgrade.sh" mac >"$TMP/absent.out" 2>&1 || fail 'absent Intent blocked'
# A selected but partially declared row must fail before any SSH/service action.
cp "$ROOT/tests/fixtures/desktop-partial-hosts.yaml" "$TMP/intent.json"
: >"$FIXTURE_LOG"
if bash "$ROOT/fleet-upgrade.sh" h-af >"$TMP/partial.out" 2>&1; then
  fail 'partial Intent allowed h-af update'
fi
grep -q 'indeterminate Intent' "$TMP/partial.out" || fail 'partial Intent diagnostic absent'
[[ ! -s "$FIXTURE_LOG" ]] || fail 'partial Intent reached SSH'

# The baseline-existing /opt path is resolved even if the preferred path is absent.
mkdir -p "$(dirname "$FIXTURE_BASELINE")"
printf 'hosts:\n  - hostname: h-af\n    update_policy: protected\n' >"$FIXTURE_BASELINE"
rm "$TMP/intent.json"
: >"$FIXTURE_LOG"
if bash "$ROOT/fleet-upgrade.sh" h-af >"$TMP/opt.out" 2>&1; then
  fail '/opt Intent allowed protected update'
fi
grep -q 'protected (registry Intent)' "$TMP/opt.out" || fail '/opt Intent was not resolved'
[[ ! -s "$FIXTURE_LOG" ]] || fail '/opt protected Intent reached SSH'
rm "$FIXTURE_BASELINE"

# Missing PyYAML is legacy only when the raw seven-host Intent has no declarations.
cp "$ROOT/tests/fixtures/desktop-legacy-hosts.yaml" "$TMP/intent.json"
FIXTURE_NO_YAML=1 HERMES_FLEET_YAML_RETRY=1 bash "$ROOT/fleet-upgrade.sh" mac >"$TMP/no-yaml.out" 2>&1 || fail 'missing PyYAML blocked undeclared update'
grep -q 'PyYAML unavailable' "$TMP/no-yaml.out" || fail 'missing YAML diagnostic absent'
printf 'hosts:\n  - hostname: mac\n    update_policy: protected\n' >"$TMP/intent.json"
: >"$FIXTURE_LOG"
if FIXTURE_NO_YAML=1 HERMES_FLEET_YAML_RETRY=1 bash "$ROOT/fleet-upgrade.sh" mac >"$TMP/declared-no-yaml.out" 2>&1; then
  fail 'missing PyYAML allowed declared update'
fi
grep -q 'PyYAML unavailable' "$TMP/declared-no-yaml.out" || fail 'declared missing YAML diagnostic absent'
[[ ! -s "$FIXTURE_LOG" ]] || fail 'undecodable declared Intent reached SSH'
echo 'PASS: protected Intent/markers, local h-do1, sleeping Mac retry, legacy and declared Intent, /opt discovery, fail-closed probes'
