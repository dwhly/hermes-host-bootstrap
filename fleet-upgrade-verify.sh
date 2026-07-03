#!/usr/bin/env bash
# fleet-upgrade-verify — read-only audit: does Chief's /fleet page reflect the ACTUAL
# hermes version installed on each fleet host? Prints a per-host table and exits non-zero
# if ANY reachable host has drifted (emitted telemetry version != installed binary).
#
# Use this after ANY fleet upgrade, or any time, to catch stale telemetry before the
# user has to notice it. No mutations — pure comparison of ground-truth vs the /fleet API.
#
# Usage: fleet-upgrade-verify [host]   (no arg = all registry hosts)
set -uo pipefail

CORE="${CHIEF_CORE_URL:-http://127.0.0.1:8088}"
HOSTS_DIR="${HERMES_HOME:-$HOME/.hermes}/hosts"

_yget() { grep -E "^[[:space:]]*$2:" "$1" 2>/dev/null | head -1 \
  | sed -E "s/^[[:space:]]*$2:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^\"?([^\"]*)\"?[[:space:]]*$/\1/"; }
# Normalize a version string to a comparable dotted number. Handles BOTH the buggy
# collector form ("18.0", leading 0. dropped) and the raw binary form
# ("Hermes Agent v0.18.0 ..."). Strategy: prefer a v-prefixed token (v0.18.0 -> 0.18.0);
# else take the first dotted-number token; then strip a spurious leading-zero-loss by
# comparing on the last two components (minor.patch are stable), which makes 18.0 and
# 0.18.0 compare equal until the collector regex bug (see EDD) is fixed through the gate.
_semver() {
  local s="$1" tok
  tok="$(grep -oiE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' <<<"$s" | head -1 | tr -d 'vV')"
  [[ -z "$tok" ]] && tok="$(grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' <<<"$s" | head -1)"
  printf '%s' "$tok"
}
# Compare two version strings tolerantly: equal if their normalized forms match OR if
# one is a "leading-0.-dropped" variant of the other (18.0 ~= 0.18.0). This absorbs the
# known collector regex bug so the verifier only flags REAL drift, not the display quirk.
_ver_match() {  # _ver_match <installed-sv> <emitted-sv>
  local a="$1" b="$2"
  [[ -z "$a" || -z "$b" ]] && return 1
  [[ "$a" == "$b" ]] && return 0
  [[ "0.$b" == "$a" || "0.$a" == "$b" ]] && return 0   # 0.18.0 vs 18.0
  return 1
}

# installed binary version for a host (local for h-do1, ssh otherwise)
_installed() {  # _installed <host>
  local host="$1" yaml="$HOSTS_DIR/$1.yaml" self user ip
  self="$(hostname -s 2>/dev/null)"
  if [[ "$host" == "$self" || "$host" == "h-do1" ]]; then
    hermes --version 2>/dev/null | head -1; return
  fi
  user="$(_yget "$yaml" ssh_user)"; ip="$(_yget "$yaml" ssh_host)"; [[ -z "$ip" ]] && ip="$(_yget "$yaml" tailscale_ip)"
  [[ -n "$user" && -n "$ip" ]] || { echo ""; return; }
  ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "${user}@${ip}" \
    'bash -lc "hermes --version 2>/dev/null | head -1"' 2>/dev/null
}

# emitted telemetry version from /fleet
_emitted() { curl -s "$CORE/v1/fleet/nodes/$1" \
  | python3 -c "import sys,json;print((json.load(sys.stdin) or {}).get('hermes_version') or '')" 2>/dev/null; }

check_one() {  # 0=match 1=drift 2=unreachable
  local host="$1" inst inst_sv emit emit_sv
  inst="$(_installed "$host")"
  if [[ -z "$inst" ]]; then
    printf '%-10s %-10s %-40s %s\n' "$host" "UNREACH" "-" "(asleep/offline)"; return 2
  fi
  inst_sv="$(_semver "$inst")"
  emit="$(_emitted "$host")"; emit_sv="$(_semver "$emit")"
  if _ver_match "$inst_sv" "$emit_sv"; then
    printf '\033[32m%-10s %-10s\033[0m binary=%-14s /fleet=%s\n' "$host" "OK" "$inst_sv" "$emit_sv"; return 0
  else
    printf '\033[31m%-10s %-10s\033[0m binary=%-14s /fleet=%s  ← DRIFT (run: fleet-upgrade %s)\n' "$host" "DRIFT" "${inst_sv:-?}" "${emit_sv:-<none>}" "$host"; return 1
  fi
}

main() {
  local rc=0
  echo "Chief /fleet telemetry vs installed binary  (core=$CORE)"
  echo "----------------------------------------------------------------------"
  if [[ -n "${1:-}" ]]; then
    check_one "$1" || rc=$?
  else
    for y in "$HOSTS_DIR"/*.yaml; do
      [[ -e "$y" ]] || continue
      local h; h="$(basename "$y" .yaml)"
      [[ "$h" == *.live ]] && continue
      check_one "$h"; local c=$?
      [[ "$c" == 1 ]] && rc=1   # drift is the only failure; unreachable is not
    done
  fi
  echo "----------------------------------------------------------------------"
  [[ "$rc" == 0 ]] && echo "✓ no drift among reachable hosts" || echo "✗ DRIFT detected — see rows marked DRIFT above"
  exit $rc
}
main "$@"
