#!/usr/bin/env bash
# tests/test_hermes_pane.sh — scripts/hermes-pane session lookup across the two
# Hermes install layouts:
#   managed (0.21+): PATH shim -> <root>/.hermes/bin/hermes, which answers
#                    --print-runtime-command and needs `import hermes_bootstrap`
#                    before hermes_state is importable;
#   legacy:          PATH shim -> "<root>/venv/bin/hermes" (venv python3).
# Fake launchers log their argv; nothing here starts a real Hermes.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PANE="$ROOT/scripts/hermes-pane"
PY="$(command -v python3)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hermes-pane-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; FAIL=1; }

# A fake Hermes project root. hermes_state refuses to import unless
# hermes_bootstrap ran first (mirrors the store Python having no deps of its own
# when $BOOTSTRAP_REQUIRED=1). The session store answers from $FAKE_SESSIONS
# ("source=id" lines) or raises when $FAKE_DB_BROKEN=1.
make_root() {
  local root="$1" require_bootstrap="$2"
  mkdir -p "$root"
  cat >"$root/hermes_bootstrap.py" <<'PY'
BOOTSTRAPPED = True
PY
  cat >"$root/hermes_constants.py" <<'PY'
def get_default_hermes_root():
    return "/nonexistent-hermes-home"
PY
  cat >"$root/hermes_state.py" <<PY
import os, sys
if $require_bootstrap and "hermes_bootstrap" not in sys.modules:
    raise ImportError("No module named 'ruamel' (bootstrap not run)")
class SessionDB:
    def __init__(self):
        if os.environ.get("FAKE_DB_BROKEN") == "1":
            raise RuntimeError("database is locked")
    def search_sessions(self, source=None, limit=1):
        for line in os.environ.get("FAKE_SESSIONS", "").split():
            src, _, sid = line.partition("=")
            if src == source:
                return [{"id": sid}]
        return []
    def close(self):
        pass
PY
}

# Managed layout: <base>/root/.hermes/bin/hermes + PATH shim <base>/bin/hermes.
make_managed() {
  local base="$1" root="$1/root"
  make_root "$root" True
  mkdir -p "$root/.hermes/bin" "$base/bin"
  cat >"$root/.hermes/bin/hermes" <<SH
#!/bin/sh
if [ "\$1" = "--print-runtime-command" ]; then
  printf '%s\n' '["$PY", "-I", "-c", "import os, sys, runpy; sys.path.insert(0, '"'"'$root'"'"'); import hermes_bootstrap; runpy.run_module('"'"'hermes_cli.main'"'"', run_name='"'"'__main__'"'"', alter_sys=True)"]'
  exit 0
fi
printf '%s\n' "\$*" >>"$base/launch.log"
SH
  chmod +x "$root/.hermes/bin/hermes"
  printf '#!/bin/sh\nexec %s/.hermes/bin/hermes "$@"\n' "$root" >"$base/bin/hermes"
  chmod +x "$base/bin/hermes"
}

# Legacy layout: <base>/root/venv/bin/{hermes,python3} + quoted PATH shim.
make_legacy() {
  local base="$1" root="$1/root"
  make_root "$root" False
  mkdir -p "$root/venv/bin" "$base/bin"
  ln -s "$PY" "$root/venv/bin/python3"
  cat >"$root/venv/bin/hermes" <<SH
#!/bin/sh
printf '%s\n' "\$*" >>"$base/launch.log"
SH
  chmod +x "$root/venv/bin/hermes"
  printf '#!/usr/bin/env bash\nexec "%s/venv/bin/hermes" "$@"\n' "$root" >"$base/bin/hermes"
  chmod +x "$base/bin/hermes"
}

run_pane() {  # base, then hermes-pane args; stdout+stderr -> $base/out
  local base="$1"; shift
  : >"$base/launch.log"
  env -i HOME="$TMP" PATH="$base/bin:/usr/bin:/bin" SHELL=/usr/bin/true \
    FAKE_SESSIONS="${FAKE_SESSIONS:-}" FAKE_DB_BROKEN="${FAKE_DB_BROKEN:-0}" \
    ${HMW_RESUME_ID:+HMW_RESUME_ID="$HMW_RESUME_ID"} \
    bash "$PANE" "$@" >"$base/out" 2>&1
}

# ── managed layout ──────────────────────────────────────────────────────────
M="$TMP/managed"; make_managed "$M"

FAKE_SESSIONS="pane:H1=20261010_060349_b38386 pane:H2=other" run_pane "$M" H1
if grep -qx 'chat --source pane:H1 --resume 20261010_060349_b38386' "$M/launch.log"; then
  pass "managed: resumes this pane's own session (bootstrap imported first)"
else fail "managed: expected resume of pane:H1 session; log=$(cat "$M/launch.log") out=$(cat "$M/out")"; fi

FAKE_SESSIONS="pane:H1=20261010_060349_b38386" run_pane "$M" --print-resume-id H1; rc=$?
if [[ $rc == 0 && "$(cat "$M/out")" == 20261010_060349_b38386 && ! -s "$M/launch.log" ]]; then
  pass "managed: --print-resume-id prints the id and launches nothing"
else fail "managed: --print-resume-id rc=$rc out=$(cat "$M/out") log=$(cat "$M/launch.log")"; fi

FAKE_SESSIONS="" run_pane "$M" H3
if grep -qx 'chat --source pane:H3' "$M/launch.log" && grep -q "no prior session for source 'pane:H3'" "$M/out"; then
  pass "managed: a new label starts fresh and says so"
else fail "managed: new label; log=$(cat "$M/launch.log") out=$(cat "$M/out")"; fi

FAKE_DB_BROKEN=1 FAKE_SESSIONS="pane:H1=x" run_pane "$M" H1
if grep -qx 'chat --source pane:H1' "$M/launch.log" && grep -q 'WARNING could not look up' "$M/out" \
   && ! grep -q 'no prior session' "$M/out"; then
  pass "managed: a failed lookup warns instead of claiming no prior session"
else fail "managed: broken lookup; log=$(cat "$M/launch.log") out=$(cat "$M/out")"; fi

FAKE_DB_BROKEN=1 run_pane "$M" --print-resume-id H1; rc=$?
if [[ $rc != 0 && ! -s "$M/launch.log" ]]; then
  pass "managed: --print-resume-id fails closed on a broken lookup"
else fail "managed: --print-resume-id broken rc=$rc log=$(cat "$M/launch.log")"; fi

HMW_RESUME_ID=pinned_123 FAKE_SESSIONS="pane:H1=other" run_pane "$M" H1
if grep -qx 'chat --source pane:H1 --resume pinned_123' "$M/launch.log"; then
  pass "managed: HMW_RESUME_ID still overrides the label lookup"
else fail "managed: HMW_RESUME_ID; log=$(cat "$M/launch.log")"; fi

# ── legacy layout ───────────────────────────────────────────────────────────
L="$TMP/legacy"; make_legacy "$L"

FAKE_SESSIONS="pane:H1=legacy_id" run_pane "$L" H1
if grep -qx 'chat --source pane:H1 --resume legacy_id' "$L/launch.log" \
   && ! grep -q -- '--print-runtime-command' "$L/launch.log"; then
  pass "legacy: venv shim still resumes; old launcher never sees --print-runtime-command"
else fail "legacy: log=$(cat "$L/launch.log") out=$(cat "$L/out")"; fi

FAKE_SESSIONS="pane:H1=legacy_id" run_pane "$L" --print-resume-id H1; rc=$?
if [[ $rc == 0 && "$(cat "$L/out")" == legacy_id && ! -s "$L/launch.log" ]]; then
  pass "legacy: --print-resume-id prints the id and launches nothing"
else fail "legacy: --print-resume-id rc=$rc out=$(cat "$L/out") log=$(cat "$L/launch.log")"; fi

bash -n "$PANE" && pass "hermes-pane parses" || fail "hermes-pane syntax"

exit $FAIL
