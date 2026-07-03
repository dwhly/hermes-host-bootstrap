#!/usr/bin/env bash
# fleet-upgrade — upgrade Hermes on a fleet host (or all), THEN refresh the Chief
# telemetry daemon and VERIFY the /fleet page reflects the new version. Fails loud
# if any node's emitted hermes_version doesn't match its freshly-installed binary.
#
# WHY: `hermes update` restarts the gateway but NOT the hermes-node telemetry daemon
# (a separate long-lived process feeding Chief's /fleet page). After an upgrade the
# daemon keeps emitting its OLD in-memory version → the /fleet page silently drifts
# stale. This wrapper closes the gap: upgrade → refresh gateway → deploy-node (restart
# telemetry onto new code) → assert emitted version == installed binary per host.
#
# Usage:
#   fleet-upgrade h-mini              # one remote host
#   fleet-upgrade all                 # every registry host EXCEPT the control host
#   fleet-upgrade all --include-self  # also self-upgrade h-do1 LAST (detached; see note)
#
# SEQUENCING: `hermes update` restarts the gateway and kills the running agent on the
# control host. This wrapper therefore SKIPS the control host (h-do1) by default. Use
# --include-self to also upgrade it, which it does LAST via a detached self-upgrade so
# it survives its own gateway restart.
set -uo pipefail

CORE="${CHIEF_CORE_URL:-http://127.0.0.1:8088}"
BOOTSTRAP_SRC="${CHIEF_BOOTSTRAP_SRC:-/root/projects/hermes-host-bootstrap}"
HOSTS_DIR="${HERMES_HOME:-$HOME/.hermes}/hosts"
DEPLOY_NODE="$BOOTSTRAP_SRC/deploy-node.sh"

log() { printf '\033[36m[fleet-upgrade %s]\033[0m %s\n' "$1" "$2" >&2; }
err() { printf '\033[31m[fleet-upgrade %s] ERROR:\033[0m %s\n' "$1" "$2" >&2; }
ok()  { printf '\033[32m[fleet-upgrade %s] ✓\033[0m %s\n' "$1" "$2" >&2; }

# Read a top-level scalar from a host registry yaml (strips inline #comments + quotes).
_yget() {  # _yget <file> <key>
  grep -E "^[[:space:]]*$2:" "$1" 2>/dev/null | head -1 \
    | sed -E "s/^[[:space:]]*$2:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^\"?([^\"]*)\"?[[:space:]]*$/\1/"
}

# Derive ssh_target|oskind from the registry yaml — NO hardcoded host list.
host_spec() {  # host_spec <host> -> echoes "ssh_target|oskind" or returns 2
  local host="$1" yaml="$HOSTS_DIR/$1.yaml"
  [[ -f "$yaml" ]] || { err "$host" "no registry entry $yaml"; return 2; }
  local user ip oskind self
  user="$(_yget "$yaml" ssh_user)"; [[ -z "$user" ]] && user="$(_yget "$yaml" default_user)"
  ip="$(_yget "$yaml" ssh_host)"; [[ -z "$ip" ]] && ip="$(_yget "$yaml" tailscale_ip)"
  oskind="$(_yget "$yaml" kind)"
  self="$(hostname -s 2>/dev/null)"
  local ssh_target=""
  if [[ "$host" == "$self" || "$host" == "h-do1" ]]; then
    ssh_target=""
  else
    [[ -n "$user" && -n "$ip" ]] || { err "$host" "registry missing ssh_user/ssh_host"; return 2; }
    ssh_target="${user}@${ip}"
  fi
  printf '%s|%s' "$ssh_target" "$oskind"
}

# Extract a comparable version token from a `hermes --version` line. Prefers the
# v-prefixed token (v0.18.0 -> 0.18.0); the node collector's own regex currently DROPS
# the leading 0. (emits 18.0) — tracked as a bug in EDD-fleet-upgrade-telemetry-
# convergence.md — so comparison uses _ver_match to tolerate both forms.
_semver() {
  local s="$1" tok
  tok="$(grep -oiE 'v[0-9]+\.[0-9]+(\.[0-9]+)?' <<<"$s" | head -1 | tr -d 'vV')"
  [[ -z "$tok" ]] && tok="$(grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' <<<"$s" | head -1)"
  printf '%s' "$tok"
}
_ver_match() {  # tolerant compare: 0.18.0 ~= 18.0 (absorbs the collector leading-0 bug)
  local a="$1" b="$2"
  [[ -z "$a" || -z "$b" ]] && return 1
  [[ "$a" == "$b" || "0.$b" == "$a" || "0.$a" == "$b" ]] && return 0
  return 1
}

upgrade_one() {  # returns 0 ok, 1 problem
  local host="$1"
  local spec; spec="$(host_spec "$host")" || return $?
  local ssh_target="${spec%%|*}" oskind="${spec##*|}"

  if [[ "$host" == "h-do1" || -z "$ssh_target" ]]; then
    err "$host" "this is the control host — skip here; use the detached self-upgrade (--include-self)"
    return 1
  fi

  local SSH=(ssh -o ConnectTimeout=12 -o ServerAliveInterval=10 -o StrictHostKeyChecking=accept-new "$ssh_target")

  # reachability (Macs sleep) — two attempts; the first often just wakes it
  if ! "${SSH[@]}" 'true' 2>/dev/null; then
    sleep 3
    if ! "${SSH[@]}" 'true' 2>/dev/null; then
      err "$host" "unreachable (asleep/offline) — skipping; re-run when online"
      return 1
    fi
  fi

  # 1) upgrade hermes
  log "$host" "hermes update --yes"
  "${SSH[@]}" 'bash -lc "hermes update --yes 2>&1 | tail -5"' || { err "$host" "hermes update failed"; return 1; }

  # 2) refresh the launchd gateway on macOS (definition goes stale after update)
  if [[ "$oskind" == "macos" ]]; then
    log "$host" "refreshing launchd gateway"
    "${SSH[@]}" 'bash -lc "hermes gateway start 2>&1 | tail -3"' || true
  fi

  # 3) capture the newly-installed binary version
  local installed installed_sv
  installed="$("${SSH[@]}" 'bash -lc "hermes --version 2>/dev/null | head -1"')"
  installed_sv="$(_semver "$installed")"
  log "$host" "installed: $installed (semver=$installed_sv)"

  # 4) restart the telemetry daemon onto new code via deploy-node (the durable refresh)
  log "$host" "refreshing telemetry daemon via deploy-node"
  "$DEPLOY_NODE" "$host" || { err "$host" "deploy-node failed"; return 1; }

  # 5) VERIFY the /fleet page now reflects the installed version (fail loud otherwise)
  sleep 3
  local emitted emitted_sv
  emitted="$(curl -s "$CORE/v1/fleet/nodes/$host" | python3 -c "import sys,json;print((json.load(sys.stdin) or {}).get('hermes_version') or '')" 2>/dev/null)"
  emitted_sv="$(_semver "$emitted")"
  if _ver_match "$installed_sv" "$emitted_sv"; then
    ok "$host" "/fleet reflects $emitted_sv (binary=$installed_sv) — telemetry converged"
    return 0
  else
    err "$host" "DRIFT: /fleet emits '${emitted:-<none>}' (sv=$emitted_sv) but binary is '$installed' (sv=$installed_sv) — daemon did NOT converge"
    return 1
  fi
}

main() {
  local target="${1:-}" include_self=0
  shift || true
  for a in "$@"; do [[ "$a" == "--include-self" ]] && include_self=1; done
  [[ -z "$target" ]] && { err "-" "usage: fleet-upgrade <host|all> [--include-self]"; exit 2; }

  local rc=0
  if [[ "$target" == "all" ]]; then
    for y in "$HOSTS_DIR"/*.yaml; do
      [[ -e "$y" ]] || continue
      local h; h="$(basename "$y" .yaml)"
      [[ "$h" == *.live ]] && continue
      [[ "$h" == "h-do1" ]] && continue   # control host handled separately
      upgrade_one "$h" || rc=1
    done
    if [[ "$include_self" == 1 ]]; then
      log "h-do1" "control host: launch the DETACHED self-upgrade (survives gateway restart)"
      log "h-do1" "run: python3 ~/.hermes/upgrade-backup/launch-self-upgrade.py  (see fleet-upgrade-execution reference)"
      log "h-do1" "then verify: fleet-upgrade-verify h-do1"
    fi
  else
    upgrade_one "$target" || rc=$?
  fi
  exit $rc
}
main "$@"
