#!/usr/bin/env bash
#
# Read-only verification checks for hermes-host-bootstrap.
# This file defines checks and runners only. It must not install packages,
# change files, invoke sudo, or otherwise mutate the host.

if [[ -z "${HOME:-}" ]]; then
  HOME="$(cd ~ && pwd)"
fi

HERMES_VERIFY_SCHEMA_VERSION=2
HERMES_VERIFY_CHECKS=()

verify_check() {
  local name="$1" required="$2" category="$3" cmd="$4"
  HERMES_VERIFY_CHECKS+=("${name}|${required}|${category}|${cmd}")
}

verify_check "git"        "true"  "system" "git --version"
verify_check "tmux"       "true"  "system" "tmux -V"
verify_check "tmux-autoattach" "false" "harness" "test -f '$HOME/.hermes-host-bootstrap.tmux-autoattach.sh' && echo present"
verify_check "hssh"       "false" "harness" "test -f '$HOME/.hermes-host-bootstrap.hssh.sh' && echo present"
verify_check "tmux-workspace-colors" "false" "harness" "test -f '$HOME/.hermes-host-bootstrap.tmux-workspace-colors.conf' && echo present"
verify_check "aliases"    "false" "harness" "test -f '$HOME/.hermes-host-bootstrap.aliases.sh' && echo present"
verify_check "op"         "true"  "system" "op --version 2>&1 | sed -n '1p'"
verify_check "mosh"       "false" "system" "mosh-server --help 2>&1 | sed -n '1p'"
verify_check "neovim"     "false" "system" "nvim --version"
verify_check "ripgrep"    "true"  "system" "rg --version"
verify_check "fzf"        "false" "system" "fzf --version"
verify_check "jq"         "true"  "system" "jq --version"
verify_check "python3"    "true"  "system" "python3 --version"
verify_check "uv"         "true"  "system" "uv --version"
verify_check "pipx"       "false" "system" "pipx --version"
verify_check "node"       "false" "system" "node --version"
verify_check "docker"     "false" "system" "docker --version"
verify_check "gh"         "false" "system" "gh --version"
verify_check "hermes"     "false" "hermes" "hermes --version"
verify_check "himalaya"   "false" "system" "himalaya --version"
verify_check "ffmpeg"     "false" "system" "ffmpeg -version"
verify_check "tailscale"  "false" "system" "tailscale version"
verify_check "hermes-fleet"   "false" "harness" "test -x '$HOME/.local/bin/hermes-fleet' && '$HOME/.local/bin/hermes-fleet' --help 2>&1 | sed -n '1p'"
verify_check "hermes-reload"  "false" "harness" "test -L '$HOME/.local/bin/hermes-reload' && echo present"
verify_check "hermes-config"  "false" "harness" "test -L '$HOME/.local/bin/hermes-config' && echo present"
verify_check "hermes-backlog" "false" "harness" "test -L '$HOME/.local/bin/hermes-backlog' && echo present"
verify_check "hermes-wiki"    "false" "harness" "test -L '$HOME/.local/bin/hermes-wiki' && echo present"

verify_tier() {
  if [[ -n "${TIER:-}" ]]; then
    printf '%s\n' "$TIER"
  elif [[ -f "$HOME/.hermes-host-bootstrap.tier" ]]; then
    sed -n '1p' "$HOME/.hermes-host-bootstrap.tier"
  else
    printf '%s\n' "minimal"
  fi
}

verify_role() {
  local role=""
  if [[ -n "${CHIEF_NODE_ROLE:-}" ]]; then
    role="${CHIEF_NODE_ROLE}"
  elif [[ -s "$HOME/.hermes/node-role" ]]; then
    IFS= read -r role < "$HOME/.hermes/node-role" || true
  fi
  # Strip any stray CR/whitespace; empty (unset, empty file, blank line) -> unknown.
  role="${role//[$'\r\n']/}"
  role="${role## }"; role="${role%% }"
  if [[ -z "$role" ]]; then
    role="unknown"
  fi
  printf '%s\n' "$role"
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
  local tier role first=1 entry name required category cmd result status version detail
  tier="$(verify_tier)"
  role="$(verify_role)"
  printf '{"schema_version":%s,"tier":"%s","role":"%s","checks":[' \
    "$HERMES_VERIFY_SCHEMA_VERSION" "$(verify_json_escape "$tier")" "$(verify_json_escape "$role")"
  for entry in "${HERMES_VERIFY_CHECKS[@]}"; do
    name="${entry%%|*}"
    entry="${entry#*|}"
    required="${entry%%|*}"
    entry="${entry#*|}"
    category="${entry%%|*}"
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
    printf ',"detail":"%s","category":"%s"}' "$(verify_json_escape "$detail")" "$(verify_json_escape "$category")"
  done
  printf ']}\n'
}

verify_human() {
  local entry name cmd result status
  for entry in "${HERMES_VERIFY_CHECKS[@]}"; do
    name="${entry%%|*}"
    entry="${entry#*|}"
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
