#!/usr/bin/env bash
#
# Read-only verification checks for hermes-host-bootstrap.
# This file defines checks and runners only. It must not install packages,
# change files, invoke sudo, or otherwise mutate the host.

if [[ -z "${HOME:-}" ]]; then
  HOME="$(cd ~ && pwd)"
fi

HERMES_VERIFY_SCHEMA_VERSION=1
HERMES_VERIFY_CHECKS=()

verify_check() {
  local name="$1" required="$2" cmd="$3"
  HERMES_VERIFY_CHECKS+=("${name}|${required}|${cmd}")
}

verify_check "git"        "true"  "git --version"
verify_check "tmux"       "true"  "tmux -V"
verify_check "tmux-autoattach" "false" "test -f '$HOME/.hermes-host-bootstrap.tmux-autoattach.sh' && echo present"
verify_check "hssh"       "false" "test -f '$HOME/.hermes-host-bootstrap.hssh.sh' && echo present"
verify_check "tmux-workspace-colors" "false" "test -f '$HOME/.hermes-host-bootstrap.tmux-workspace-colors.conf' && echo present"
verify_check "aliases"    "false" "test -f '$HOME/.hermes-host-bootstrap.aliases.sh' && echo present"
verify_check "op"         "true"  "op --version 2>&1 | sed -n '1p'"
verify_check "mosh"       "false" "mosh-server --help 2>&1 | sed -n '1p'"
verify_check "neovim"     "false" "nvim --version"
verify_check "ripgrep"    "true"  "rg --version"
verify_check "fzf"        "false" "fzf --version"
verify_check "jq"         "true"  "jq --version"
verify_check "python3"    "true"  "python3 --version"
verify_check "uv"         "true"  "uv --version"
verify_check "pipx"       "false" "pipx --version"
verify_check "node"       "false" "node --version"
verify_check "docker"     "false" "docker --version"
verify_check "gh"         "false" "gh --version"
verify_check "hermes"     "false" "hermes --version"
verify_check "himalaya"   "false" "himalaya --version"
verify_check "ffmpeg"     "false" "ffmpeg -version"
verify_check "tailscale"  "false" "tailscale version"
verify_check "hermes-fleet"   "false" "test -x '$HOME/.local/bin/hermes-fleet' && '$HOME/.local/bin/hermes-fleet' --help 2>&1 | sed -n '1p'"
verify_check "hermes-reload"  "false" "test -L '$HOME/.local/bin/hermes-reload' && echo present"
verify_check "hermes-config"  "false" "test -L '$HOME/.local/bin/hermes-config' && echo present"
verify_check "hermes-backlog" "false" "test -L '$HOME/.local/bin/hermes-backlog' && echo present"
verify_check "hermes-wiki"    "false" "test -L '$HOME/.local/bin/hermes-wiki' && echo present"

verify_tier() {
  if [[ -n "${TIER:-}" ]]; then
    printf '%s\n' "$TIER"
  elif [[ -f "$HOME/.hermes-host-bootstrap.tier" ]]; then
    sed -n '1p' "$HOME/.hermes-host-bootstrap.tier"
  else
    printf '%s\n' "minimal"
  fi
}

verify_json_escape() {
  local s="${1:-}"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json, sys; print(json.dumps(sys.argv[1])[1:-1], end="")' "$s" 2>/dev/null && return
  fi

  # Fallback covers shell-representable JSON escapes; Bash strings cannot carry NUL bytes.
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\b'/\\b}"
  s="${s//$'\f'/\\f}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

verify_run_check() {
  local cmd="$1" out rc first
  out="$(eval "$cmd" 2>&1)"
  rc=$?
  first="$(printf '%s\n' "$out" | sed '/^[[:space:]]*$/d; q')"
  if [[ "$rc" -eq 0 ]]; then
    printf 'ok\t%s\t%s\n' "$first" "ok"
  else
    printf 'missing\t\t%s\n' "${first:-not found or failed}"
  fi
}

verify_json() {
  local tier first=1 entry name required cmd result status version detail
  tier="$(verify_tier)"
  printf '{"schema_version":%s,"tier":"%s","checks":[' \
    "$HERMES_VERIFY_SCHEMA_VERSION" "$(verify_json_escape "$tier")"
  for entry in "${HERMES_VERIFY_CHECKS[@]}"; do
    name="${entry%%|*}"
    entry="${entry#*|}"
    required="${entry%%|*}"
    cmd="${entry#*|}"
    result="$(verify_run_check "$cmd")"
    status="${result%%$'\t'*}"
    result="${result#*$'\t'}"
    version="${result%%$'\t'*}"
    detail="${result#*$'\t'}"
    [[ "$first" -eq 1 ]] || printf ','
    first=0
    printf '{"name":"%s","required":%s,"status":"%s"' \
      "$(verify_json_escape "$name")" "$required" "$(verify_json_escape "$status")"
    if [[ -n "$version" ]]; then
      printf ',"version":"%s"' "$(verify_json_escape "$version")"
    fi
    printf ',"detail":"%s"}' "$(verify_json_escape "$detail")"
  done
  printf ']}\n'
}

verify_human() {
  local entry name cmd result status
  for entry in "${HERMES_VERIFY_CHECKS[@]}"; do
    name="${entry%%|*}"
    entry="${entry#*|}"
    entry="${entry#*|}"
    cmd="$entry"
    result="$(verify_run_check "$cmd")"
    status="${result%%$'\t'*}"
    if [[ "$status" == "ok" ]]; then
      if declare -F ok >/dev/null 2>&1; then
        ok "$name"
      else
        printf 'ok: %s\n' "$name"
      fi
    else
      if declare -F warn >/dev/null 2>&1; then
        warn "$name — not found or failed"
      else
        printf 'warn: %s — not found or failed\n' "$name"
      fi
    fi
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    --json-supported)
      exit 0
      ;;
    --json)
      verify_json
      exit 0
      ;;
    ""|--human)
      verify_human
      exit 0
      ;;
    *)
      echo "usage: $0 [--json|--json-supported|--human]" >&2
      exit 2
      ;;
  esac
fi
