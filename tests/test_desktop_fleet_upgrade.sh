#!/usr/bin/env bash
# Offline/no-root/no-credentials: every SSH, update, refresh and HTTP call is stubbed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/hosts" "$TMP/bootstrap"
export FIXTURE_LOG="$TMP/calls"
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
  *image-provenance.json*) exit "${FIXTURE_MARKER_RC:-0}" ;;
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
printf '%s\n' '{"hosts":[]}' >"$TMP/intent.json"
: >"$FIXTURE_LOG"
if bash "$ROOT/fleet-upgrade.sh" mac >"$TMP/no-policy.out" 2>&1; then
  fail 'missing policy allowed update'
fi
[[ ! -s "$FIXTURE_LOG" ]] || fail 'missing policy reached SSH'
echo 'PASS: fleet-upgrade registry/marker protection, direct refusal, eligible update, fail-closed probes'
