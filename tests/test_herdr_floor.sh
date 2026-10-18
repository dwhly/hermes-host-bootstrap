#!/usr/bin/env bash
# Offline end-to-end module checks, including the macOS /bin/bash 3.2 path.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/home/.config"
export REPO_ROOT="$TMP/repo" HERDR_TEST_ROOT="$ROOT"
export HERDR_TEST_LOG="$TMP/commands.log" HERDR_TEST_PAYLOAD="$TMP/payload"
export HERDR_TEST_OS=Linux HERDR_TEST_ARCH=x86_64
export HERDR_TEST_SESSIONS=stopped HERDR_TEST_PGREP=1 HERDR_TEST_POST_FAIL=0
export HERDR_TEST_DOWNLOAD_FAIL=0 HERDR_TEST_START_DURING_DOWNLOAD=0
export TIER=recommended
unset SKIP_KEYS
mkdir -p "$TMP/tools" "$TMP/stubs" "$REPO_ROOT/lib" "$REPO_ROOT/packages" "$REPO_ROOT/scripts"
for helper in hmw-herdr.sh hmw-tmux.sh herdr-new-agent; do
  printf '#!/bin/bash\nexit 99\n' > "$REPO_ROOT/scripts/$helper"
done
# An allowlist prevents the test from finding a real Herdr or network client.
for tool in bash awk cat chmod cp date dirname grep id ln mkdir mktemp mv python3 rm sed touch; do
  ln -s "$(command -v "$tool")" "$TMP/tools/$tool"
done
for tool in sha256sum shasum; do
  if command -v "$tool" >/dev/null 2>&1; then
    ln -s "$(command -v "$tool")" "$TMP/tools/$tool"
  fi
done
# macOS does not ship sha256sum. Use its native tool for Linux fixture cases.
if [[ ! -x "$TMP/tools/sha256sum" ]]; then
  cat > "$TMP/tools/sha256sum" <<'STUB'
#!/bin/bash
exec shasum -a 256 "$@"
STUB
  chmod +x "$TMP/tools/sha256sum"
fi
cp "$ROOT/lib/42-herdr.sh" "$REPO_ROOT/lib/42-herdr.sh"
cat > "$REPO_ROOT/lib/common.sh" <<'STUB'
# shellcheck source=lib/common.sh
source "$HERDR_TEST_ROOT/lib/common.sh"
# Undo common.sh's Homebrew PATH injection inside this isolated test only.
export PATH="$HERDR_TEST_PATH"
STUB
cat > "$TMP/stubs/uname" <<'STUB'
#!/bin/bash
case "$1" in
  -s) echo "$HERDR_TEST_OS" ;;
  -m) echo "$HERDR_TEST_ARCH" ;;
  *) exit 2 ;;
esac
STUB
cat > "$TMP/stubs/pgrep" <<'STUB'
#!/bin/bash
printf 'pgrep %s\n' "$*" >> "$HERDR_TEST_LOG"
[[ "$*" == "-u $(id -u) -x herdr" ]] || exit 2
exit "$HERDR_TEST_PGREP"
STUB
cat > "$TMP/stubs/curl" <<'STUB'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$HERDR_TEST_LOG"
[[ "$1" == -fsSL && "$3" == -o ]] || exit 2
[[ "$HERDR_TEST_DOWNLOAD_FAIL" == 0 ]] || exit 22
cp "$HERDR_TEST_PAYLOAD" "$4"
if [[ "$HERDR_TEST_START_DURING_DOWNLOAD" == 1 ]]; then
  touch "$HOME/session-started"
fi
STUB
chmod +x "$TMP/stubs/"*
export HERDR_TEST_PATH="$TMP/stubs:$HOME/.local/bin:$TMP/tools"
export PATH="$HERDR_TEST_PATH"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
export PATH="$HERDR_TEST_PATH"

fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$TMP/output" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
contains() { grep -Fq -- "$1" "$TMP/output" || fail "missing output: $1"; }
no_download() { if grep -q '^curl ' "$HERDR_TEST_LOG"; then fail 'unexpected download'; fi; }
unchanged() {
  [[ "$(sha256_of "$HOME/.local/bin/herdr")" == "$BEFORE" ]] || fail 'installed binary changed'
}
make_binary() {
  printf '#!/bin/bash\nFIXTURE_VERSION=%s\n' "$2" > "$1"
  cat >> "$1" <<'STUB'
printf 'herdr %s %s\n' "$FIXTURE_VERSION" "$*" >> "$HERDR_TEST_LOG"
case "$*" in
  --version)
    if [[ "$HERDR_TEST_POST_FAIL" == 1 && "$FIXTURE_VERSION" == 0.9.3 && "$0" == "$HOME/.local/bin/herdr" ]]; then
      exit 1
    fi
    printf 'herdr %s\n' "$FIXTURE_VERSION"
    ;;
  'session list')
    if [[ -f "$HOME/session-started" ]]; then printf 'ws running\n'; exit 0; fi
    case "$HERDR_TEST_SESSIONS" in
      stopped) printf 'NAME STATUS\ndefault stopped\n' ;;
      none) printf 'No sessions found.\n' ;;
      default) printf 'NAME STATUS\ndefault running\n' ;;
      named) printf 'NAME STATUS\ndefault stopped\nws running\n' ;;
      failed) exit 1 ;;
      unsupported) exit 2 ;;
      unknown) printf 'unexpected response\n' ;;
      unknown_status) printf 'NAME STATUS\ndefault stopped\nstopped unknown\n' ;;
      empty) : ;;
    esac
    ;;
  'status server --json')
    if [[ "$HERDR_TEST_SESSIONS" == default ]]; then printf '{"running":true}\n'
    else printf '{"running":false}\n'; fi
    ;;
  'server reload-config') : ;;
  'integration status') printf 'hermes: current\n' ;;
  *) printf 'UNEXPECTED HERDR ACTION: %s\n' "$*" >> "$HERDR_TEST_LOG"; exit 99 ;;
esac
STUB
  chmod +x "$1"
}
reset_case() {
  rm -rf "$HOME" "$TMP/shadow"
  mkdir -p "$HOME/.local/bin"
  : > "$HERDR_TEST_LOG"
  : > "$TMP/output"
  HERDR_TEST_SESSIONS=stopped HERDR_TEST_PGREP=1 HERDR_TEST_POST_FAIL=0
  HERDR_TEST_DOWNLOAD_FAIL=0 HERDR_TEST_START_DURING_DOWNLOAD=0
  HERDR_TEST_OS=Linux HERDR_TEST_ARCH=x86_64
  HERDR_TEST_PATH="$TMP/stubs:$HOME/.local/bin:$TMP/tools"
  PATH="$HERDR_TEST_PATH"; OS=linux
  make_binary "$HERDR_TEST_PAYLOAD" 0.9.3
  write_record
  if [[ "$1" != absent ]]; then
    make_binary "$HOME/.local/bin/herdr" "$1"
    BEFORE="$(sha256_of "$HOME/.local/bin/herdr")"
  fi
}
write_record() {
  # Preserve the actual record shape; replace release digests with fixture digests.
  local digest
  digest="$(sha256_of "$HERDR_TEST_PAYLOAD")"
  sed "s/^sha256_\\([^:]*\\):.*/sha256_\\1: $digest/" "$ROOT/packages/herdr.yaml" > "$REPO_ROOT/packages/herdr.yaml"
}
run_module() {
  "$BASH" "$REPO_ROOT/lib/42-herdr.sh" > "$TMP/output" 2>&1 || fail 'module did not return 0'
  if grep -q 'UNEXPECTED HERDR ACTION' "$HERDR_TEST_LOG"; then fail 'unexpected Herdr action'; fi
  local staged
  for staged in "$HOME/.local/bin/".herdr.*; do
    [[ ! -e "$staged" ]] || fail 'staging file leaked'
  done
}

# Dotted comparison, including missing components, leading zeros and overflow.
for row in '0.7.1 0.9.3 0' '0.9.3 0.9.3 1' '0.10.0 0.9.3 1' '1.0 1.0.1 0' \
           '1 1.0.0 1' '0.09.2 0.9.3 0' '999999999999999999999 2 1' 'bad 0.9.3 2'; do
  read -r a b expected <<< "$row"
  result=0
  version_lt "$a" "$b" || result=$?
  [[ "$result" == "$expected" ]] || fail "version_lt $a $b: $result != $expected"
done
pass 'version_lt numeric dotted comparison table'

reset_case 0.7.1
printf 'older backup\n' > "$HOME/.local/bin/herdr.prev"
run_module
[[ "$("$HOME/.local/bin/herdr" --version)" == 'herdr 0.9.3' ]] || fail 'upgrade version'
[[ "$(sha256_of "$HOME/.local/bin/herdr.prev")" == "$BEFORE" ]] || fail '.prev differs from old binary'
grep -Fq 'https://github.com/ogulcancelik/herdr/releases/download/v0.9.3/herdr-linux-x86_64' "$HERDR_TEST_LOG" || fail 'wrong URL'
pass 'below floor upgrades exact release with verified digest; .prev overwrites older backup'

for version in 0.9.3 0.10.0; do
  reset_case "$version"
  run_module
  unchanged; no_download
  if grep -q '^pgrep ' "$HERDR_TEST_LOG"; then fail 'unnecessary activity probe'; fi
  pass "$version meets floor without download or replacement"
done

reset_case 0.8.2
printf '\n# corrupt transfer\n' >> "$HERDR_TEST_PAYLOAD"
run_module
unchanged; contains 'sha256 mismatch'
if grep -q 'herdr 0.9.3 --version' "$HERDR_TEST_LOG"; then fail 'unverified payload executed'; fi
pass 'digest mismatch leaves old binary untouched and never executes payload'

reset_case 0.8.2
make_binary "$HERDR_TEST_PAYLOAD" 0.9.2
write_record
run_module
unchanged; contains 'staged --version does not equal'
pass 'staged version mismatch leaves old binary untouched'

for sessions in default named failed unsupported unknown unknown_status empty; do
  reset_case 0.8.2
  HERDR_TEST_SESSIONS="$sessions"
  run_module
  unchanged; no_download
  contains 'installed 0.8.2, floor 0.9.3'
  contains 'herdr update --handoff'
  contains 'bootstrap.sh --only=42-herdr'
  grep -q '^pgrep ' "$HERDR_TEST_LOG" || fail 'process probe skipped'
  [[ -L "$HOME/.local/bin/herdr-new-agent" ]] || fail 'existing helper setup skipped'
  grep -q 'BEGIN HERMES FLEET KEYBINDINGS' "$XDG_CONFIG_HOME/herdr/config.toml" || fail 'existing keybinding setup skipped'
  if [[ "$sessions" == default ]]; then
    grep -q 'server reload-config' "$HERDR_TEST_LOG" || fail 'existing config reload skipped'
  fi
  pass "session detection ($sessions) defers safely"
done

for process_status in 0 2 127; do
  reset_case 0.8.2
  HERDR_TEST_PGREP="$process_status"
  run_module
  unchanged; no_download; contains 'upgrade deferred'
  pass "process detection ($process_status) defers safely"
done

reset_case 0.8.2
HERDR_TEST_START_DURING_DOWNLOAD=1
run_module
unchanged; contains 'upgrade deferred'
pass 'session starting during download prevents replacement'

reset_case absent
run_module
[[ "$("$HOME/.local/bin/herdr" --version)" == 'herdr 0.9.3' ]] || fail 'fresh install version'
[[ ! -e "$HOME/.local/bin/herdr.prev" ]] || fail 'fresh install created backup'
if grep -q '^pgrep ' "$HERDR_TEST_LOG"; then fail 'fresh install activity probe'; fi
pass 'absent binary installs from record without activity probes'

reset_case absent
rm "$REPO_ROOT/packages/herdr.yaml"
run_module
[[ ! -e "$HOME/.local/bin/herdr" ]] || fail 'installed without record'
no_download; contains 'missing/invalid packages/herdr.yaml'
pass 'missing record prevents fresh install'

for invalid in digest floor duplicate; do
  reset_case 0.8.2
  case "$invalid" in
    digest) sed '/^sha256_linux_x86_64:/d' "$REPO_ROOT/packages/herdr.yaml" > "$TMP/record" ;;
    floor) sed 's/^minimum_version:.*/minimum_version: broken/' "$REPO_ROOT/packages/herdr.yaml" > "$TMP/record" ;;
    duplicate) cat "$REPO_ROOT/packages/herdr.yaml" > "$TMP/record"; printf 'minimum_version: 0.9.4\n' >> "$TMP/record" ;;
  esac
  mv "$TMP/record" "$REPO_ROOT/packages/herdr.yaml"
  run_module
  unchanged; no_download
  pass "invalid record ($invalid) prevents upgrade"
done

reset_case invalid
run_module
unchanged; no_download; contains 'unparsable installed version'
pass 'unparsable installed version prevents upgrade'

reset_case 0.8.2
mkdir -p "$TMP/shadow"
make_binary "$TMP/shadow/herdr" 0.10.0
SHADOW_BEFORE="$(sha256_of "$TMP/shadow/herdr")"
HERDR_TEST_PATH="$TMP/shadow:$HERDR_TEST_PATH"
run_module
contains "PATH shadow: $TMP/shadow/herdr (0.10.0)"
contains "fleet destination $HOME/.local/bin/herdr (0.8.2)"
[[ "$(sha256_of "$TMP/shadow/herdr")" == "$SHADOW_BEFORE" ]] || fail 'shadow modified'
[[ "$("$HOME/.local/bin/herdr" --version)" == 'herdr 0.9.3' ]] || fail 'version decision used shadow'
pass 'PATH shadow warning includes both paths/versions; destination alone determines upgrade'

reset_case absent
mkdir -p "$TMP/shadow"
make_binary "$TMP/shadow/herdr" 0.7.1
HERDR_TEST_PATH="$TMP/shadow:$HERDR_TEST_PATH"
HERDR_TEST_SESSIONS=named
run_module
[[ ! -e "$HOME/.local/bin/herdr" ]] || fail 'fresh destination installed alongside running shadow'
no_download; contains 'upgrade deferred'
pass 'running shadow copy defers even when fleet destination is absent'

for previous in 0.8.2 absent; do
  reset_case "$previous"
  HERDR_TEST_POST_FAIL=1
  run_module
  contains 'post-install --version failed'
  if [[ "$previous" == absent ]]; then
    [[ ! -e "$HOME/.local/bin/herdr" ]] || fail 'failed fresh install remains'
  else
    unchanged
  fi
  pass "post-install failure restores previous state ($previous)"
done

reset_case 0.8.2
HERDR_TEST_DOWNLOAD_FAIL=1
run_module
unchanged; contains 'download failed'
pass 'download failure preserves existing binary and returns success'

for platform in 'Linux aarch64 linux-aarch64' 'Darwin arm64 macos-aarch64' 'Darwin x86_64 macos-x86_64'; do
  reset_case 0.8.2
  read -r HERDR_TEST_OS HERDR_TEST_ARCH asset_platform <<< "$platform"
  run_module
  [[ "$("$HOME/.local/bin/herdr" --version)" == 'herdr 0.9.3' ]] || fail 'platform upgrade'
  grep -Fq "/herdr-$asset_platform " "$HERDR_TEST_LOG" || fail 'platform asset URL'
  pass "asset and digest selected for $asset_platform"
done

printf 'PASS: all Herdr floor tests (offline, isolated HOME, no real Herdr)\n'
