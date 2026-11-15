#!/usr/bin/env bash
# Skip keys must reach modules: bootstrap.sh runs each module as a child `bash "$path"`,
# and Bash cannot export arrays, so SKIP_KEYS alone never arrived (every is_skipped was false).
# Drives the real bootstrap.sh entry point with a probe module; verify.sh is stubbed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
R="$WORK/repo"; mkdir -p "$R/lib" "$WORK/home"
cp "$ROOT/bootstrap.sh" "$R/"; cp "$ROOT/lib/common.sh" "$R/lib/"
printf 'verify_human() { :; }\n' >"$R/verify.sh"
cat >"$R/lib/Z9-skip-probe.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
for k in alpha beta gamma; do
  if is_skipped "$k"; then echo "PROBE skipped=$k"; else echo "PROBE kept=$k"; fi
done
SH

run() { # run [VAR=value ...] -- [bootstrap args ...]
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$WORK/home" USER=t HERMES_HOSTNAME=h-test \
    HERMES_NONINTERACTIVE=1 ${envs[@]+"${envs[@]}"} \
    bash "$R/bootstrap.sh" --role=client --only=Z9-skip-probe "$@" </dev/null 2>&1 | grep '^PROBE' | sort | tr '\n' ' '
}
expect() { [[ "$2" == "$3" ]] || fail "$1: got [$2] want [$3]"; }

expect "cli --skip"      "$(run -- --skip=alpha,beta)"            "PROBE kept=gamma PROBE skipped=alpha PROBE skipped=beta "
expect "cli --skip x y"  "$(run -- --skip alpha)"                 "PROBE kept=beta PROBE kept=gamma PROBE skipped=alpha "
expect "HERMES_SKIP"     "$(run HERMES_SKIP=gamma --)"            "PROBE kept=alpha PROBE kept=beta PROBE skipped=gamma "
expect "env + cli"       "$(run HERMES_SKIP=gamma -- --skip=alpha)" "PROBE kept=beta PROBE skipped=alpha PROBE skipped=gamma "
expect "no skips"        "$(run --)"                              "PROBE kept=alpha PROBE kept=beta PROBE kept=gamma "
# Unexported HERMES_SKIP in ~/.hermes-bootstrap.conf (how hosts actually set it), plus CLI.
printf 'HERMES_SKIP=gamma\n' >"$WORK/home/.hermes-bootstrap.conf"
expect "conf file + cli" "$(run -- --skip=alpha)"                 "PROBE kept=beta PROBE skipped=alpha PROBE skipped=gamma "
rm -f "$WORK/home/.hermes-bootstrap.conf"

echo "PASS test_skip_keys_cross_process"
