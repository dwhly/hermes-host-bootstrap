#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1" expected="$2"
  grep -Fq -- "$expected" "$file" || fail "$file does not contain: $expected"
}

assert_not_contains() {
  local file="$1" unexpected="$2"
  if grep -Fq -- "$unexpected" "$file"; then
    fail "$file unexpectedly contains: $unexpected"
  fi
}

assert_occurrences() {
  local file="$1" expected="$2" count="$3" actual
  actual="$(grep -Fc -- "$expected" "$file" || true)"
  [[ "$actual" == "$count" ]] || fail "$file contains $actual occurrences of '$expected', expected $count"
}

MOCK_BIN="$TMP/bin"
MOCK_HOME="$TMP/home"
MOCK_PREFIX="$TMP/homebrew"
MOCK_STATE="$TMP/state"
MOCK_LOG="$TMP/commands.log"
mkdir -p "$MOCK_BIN" "$MOCK_HOME/.docker" "$MOCK_PREFIX/lib/docker/cli-plugins" "$MOCK_STATE"

cat > "$MOCK_BIN/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo "${MOCK_UNAME_S:-Darwin}" ;;
  -m) echo "${MOCK_UNAME_M:-arm64}" ;;
  -sr) echo "${MOCK_UNAME_S:-Darwin} 25.5.0" ;;
  *) echo "${MOCK_UNAME_S:-Darwin}" ;;
esac
EOF

cat > "$MOCK_BIN/brew" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --prefix)
    printf '%s\n' "$MOCK_PREFIX"
    ;;
  list)
    [[ "${2:-}" == "--formula" ]] || exit 2
    [[ -f "$MOCK_STATE/formula-${3:-}" ]]
    ;;
  install)
    shift
    printf 'brew install %s\n' "$*" >> "$MOCK_LOG"
    for formula in "$@"; do
      touch "$MOCK_STATE/formula-$formula"
    done
    ;;
  *)
    printf 'unexpected brew invocation: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF

cat > "$MOCK_BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --version) echo 'Docker version 29.0.0, build test' ;;
  compose|buildx)
    printf 'docker %s version\n' "$1" >> "$MOCK_LOG"
    config="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
    grep -Fq "$MOCK_PREFIX/lib/docker/cli-plugins" "$config" 2>/dev/null
    [[ ! -f "$MOCK_STATE/plugin-$1-fail" ]]
    printf 'Docker %s version test\n' "$1"
    ;;
  info)
    [[ -f "$MOCK_STATE/colima-running" ]] || exit 1
    echo '29.0.0'
    ;;
  *) exit 2 ;;
esac
EOF

cat > "$MOCK_BIN/colima" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  --version) echo 'colima version 0.10.0' ;;
  status) [[ -f "$MOCK_STATE/colima-running" ]] ;;
  start)
    printf 'colima %s\n' "$*" >> "$MOCK_LOG"
    touch "$MOCK_STATE/colima-running"
    ;;
  *) exit 2 ;;
esac
EOF

cat > "$MOCK_BIN/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-nG" ]]; then
  echo "${2:-builder} docker"
else
  /usr/bin/id "$@"
fi
EOF

cat > "$MOCK_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$MOCK_LOG"
EOF

cat > "$MOCK_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

chmod +x "$MOCK_BIN"/*
export MOCK_PREFIX MOCK_STATE MOCK_LOG

cat > "$MOCK_HOME/.docker/config.json" <<'EOF'
{
  "auths": {"registry.example": {"auth": "keep-me"}},
  "currentContext": "existing",
  "cliPluginsExtraDirs": ["/existing/plugins"]
}
EOF

run_module() {
  HOME="$MOCK_HOME" \
  PATH="$MOCK_BIN:/usr/bin:/bin" \
  TIER=recommended \
  ROLE="${ROLE_OVERRIDE:-client}" \
  HERMES_COLIMA_START="${HERMES_COLIMA_START_OVERRIDE:-}" \
  HERMES_COLIMA_CPU="${HERMES_COLIMA_CPU_OVERRIDE:-}" \
  HERMES_COLIMA_MEMORY="${HERMES_COLIMA_MEMORY_OVERRIDE:-}" \
  HERMES_COLIMA_DISK="${HERMES_COLIMA_DISK_OVERRIDE:-}" \
  HERMES_COLIMA_ARCH="${HERMES_COLIMA_ARCH_OVERRIDE:-}" \
  bash "$ROOT/lib/60-containers.sh"
}

run_module > "$TMP/install.out"
assert_contains "$MOCK_LOG" "brew install colima docker docker-compose docker-buildx qemu"
assert_not_contains "$MOCK_LOG" "colima start"
assert_occurrences "$MOCK_LOG" "docker compose version" 2
assert_occurrences "$MOCK_LOG" "docker buildx version" 1
assert_contains "$TMP/install.out" "Docker Compose and Buildx plugin discovery configured"

python3 - "$MOCK_HOME/.docker/config.json" "$MOCK_PREFIX" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)
assert config["auths"]["registry.example"]["auth"] == "keep-me"
assert config["currentContext"] == "existing"
assert config["cliPluginsExtraDirs"] == [
    "/existing/plugins",
    f"{sys.argv[2]}/lib/docker/cli-plugins",
]
PY

cat > "$MOCK_HOME/.docker/config.json" <<'EOF'
{
  "auths": {"registry.example": {"auth": "keep-me"}},
  "currentContext": "existing"
}
EOF
touch "$MOCK_STATE/plugin-compose-fail"
: > "$MOCK_LOG"
run_module > "$TMP/plugin-failure.out" 2>&1
assert_occurrences "$MOCK_LOG" "docker compose version" 2
assert_occurrences "$MOCK_LOG" "docker buildx version" 1
assert_contains "$TMP/plugin-failure.out" "Docker Compose or Buildx plugin discovery still fails"
assert_not_contains "$TMP/plugin-failure.out" "plugin discovery configured"
rm -f "$MOCK_STATE/plugin-compose-fail"

: > "$MOCK_LOG"
HERMES_COLIMA_START_OVERRIDE=1 \
HERMES_COLIMA_CPU_OVERRIDE=6 \
HERMES_COLIMA_MEMORY_OVERRIDE=12 \
HERMES_COLIMA_DISK_OVERRIDE=120 \
HERMES_COLIMA_ARCH_OVERRIDE=x86_64 \
run_module > "$TMP/start.out"
assert_not_contains "$MOCK_LOG" "brew install"
assert_contains "$MOCK_LOG" "colima start --cpu 6 --memory 12 --disk 120 --arch x86_64"

: > "$MOCK_LOG"
HERMES_COLIMA_START_OVERRIDE=1 \
HERMES_COLIMA_CPU_OVERRIDE=63 \
HERMES_COLIMA_MEMORY_OVERRIDE=255 \
HERMES_COLIMA_DISK_OVERRIDE=2047 \
HERMES_COLIMA_ARCH_OVERRIDE=aarch64 \
run_module > "$TMP/already-running.out"
assert_not_contains "$MOCK_LOG" "colima start"
assert_contains "$TMP/already-running.out" "Colima already running"

rm -f "$MOCK_STATE/colima-running"
: > "$MOCK_LOG"
HERMES_COLIMA_START_OVERRIDE=1 \
HERMES_COLIMA_CPU_OVERRIDE=64 \
HERMES_COLIMA_MEMORY_OVERRIDE=256 \
HERMES_COLIMA_DISK_OVERRIDE=2048 \
run_module > "$TMP/resource-boundaries.out"
assert_contains "$MOCK_LOG" "colima start --cpu 64 --memory 256 --disk 2048"

for resource in CPU MEMORY DISK; do
  rm -f "$MOCK_STATE/colima-running"
  : > "$MOCK_LOG"
  HERMES_COLIMA_START_OVERRIDE=1
  HERMES_COLIMA_CPU_OVERRIDE=4
  HERMES_COLIMA_MEMORY_OVERRIDE=8
  HERMES_COLIMA_DISK_OVERRIDE=80
  case "$resource" in
    CPU) HERMES_COLIMA_CPU_OVERRIDE=65; maximum=64 ;;
    MEMORY) HERMES_COLIMA_MEMORY_OVERRIDE=257; maximum=256 ;;
    DISK) HERMES_COLIMA_DISK_OVERRIDE=2049; maximum=2048 ;;
  esac
  export HERMES_COLIMA_START_OVERRIDE HERMES_COLIMA_CPU_OVERRIDE
  export HERMES_COLIMA_MEMORY_OVERRIDE HERMES_COLIMA_DISK_OVERRIDE
  run_module > "$TMP/resource-$resource.out" 2>&1
  assert_not_contains "$MOCK_LOG" "colima start"
  assert_contains "$TMP/resource-$resource.out" "HERMES_COLIMA_$resource must be at most $maximum"
done
unset HERMES_COLIMA_START_OVERRIDE HERMES_COLIMA_CPU_OVERRIDE
unset HERMES_COLIMA_MEMORY_OVERRIDE HERMES_COLIMA_DISK_OVERRIDE

rm -f "$MOCK_STATE/colima-running"
: > "$MOCK_LOG"
HERMES_COLIMA_START_OVERRIDE=1 \
HERMES_COLIMA_CPU_OVERRIDE=99999999999999999999999999999999999999999999999999 \
run_module > "$TMP/resource-huge.out" 2>&1
assert_not_contains "$MOCK_LOG" "colima start"
assert_contains "$TMP/resource-huge.out" "HERMES_COLIMA_CPU must be at most 64"

rm -f "$MOCK_STATE/colima-running"
: > "$MOCK_LOG"
ROLE_OVERRIDE=server run_module > "$TMP/role-start.out"
assert_contains "$MOCK_LOG" "colima start --cpu 4 --memory 8 --disk 80"
assert_not_contains "$MOCK_LOG" "--arch"

assert_contains "$ROOT/verify.sh" 'verify_check "docker-cli"'
assert_contains "$ROOT/verify.sh" 'verify_check "docker-daemon"'
assert_contains "$ROOT/verify.sh" 'verify_check "colima"'
assert_contains "$ROOT/lib/99-register-host.sh" 'COLIMA_VER='
assert_contains "$ROOT/lib/99-register-host.sh" 'colima: "$COLIMA_VER"'

: > "$MOCK_LOG"
HOME="$MOCK_HOME" \
PATH="$MOCK_BIN:/usr/bin:/bin" \
USER=builder \
TIER=recommended \
ROLE=server \
MOCK_UNAME_S=Linux \
bash "$ROOT/lib/60-containers.sh" > "$TMP/linux.out"
assert_contains "$MOCK_LOG" "systemctl enable --now docker"
assert_not_contains "$MOCK_LOG" "brew install"
assert_not_contains "$MOCK_LOG" "colima start"
assert_contains "$TMP/linux.out" "Docker ready"

printf 'ok: container module tests\n'
