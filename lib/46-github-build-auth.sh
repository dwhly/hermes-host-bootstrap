#!/usr/bin/env bash
# 46-github-build-auth: h-mini2-only GitHub CLI/Git write authentication.
#
# The fleet-wide token wired by lib/45 remains read-only. This module consumes
# CHIEF_BUILD_GIT_TOKEN from the h-mini2 env overlay and configures gh + Git for
# reviewed branch pushes and pull-request operations on the designated build host.

set -euo pipefail
# Modules are sourced by bootstrap.sh but also support direct execution.
# shellcheck disable=SC1091,SC2317
source "$(dirname "$0")/common.sh"

step "GitHub build auth (h-mini2 only)"

if is_skipped github-build-auth; then
  skip "--skip=github-build-auth passed"
  return 0 2>/dev/null || exit 0
fi

HOST_SHORT="${HERMES_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"
if [[ "$HOST_SHORT" != "h-mini2" ]]; then
  skip "GitHub build credential is restricted to h-mini2 (current: $HOST_SHORT)"
  return 0 2>/dev/null || exit 0
fi

if ! have gh; then
  warn "gh CLI is not installed; install it through the fleet CLI module first"
  return 0 2>/dev/null || exit 0
fi

ENV_FILE="${HERMES_HOME:-$HOME/.hermes}/.env"
TOKEN=""
if [[ -f "$ENV_FILE" ]]; then
  TOKEN="$(grep -E '^CHIEF_BUILD_GIT_TOKEN=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)"
fi
TOKEN="${CHIEF_BUILD_GIT_TOKEN:-$TOKEN}"

if [[ -z "$TOKEN" || "$TOKEN" == op://* ]]; then
  warn "CHIEF_BUILD_GIT_TOKEN is unresolved; expected the h-mini2 env overlay"
  return 0 2>/dev/null || exit 0
fi

# gh stores the credential in its normal protected config/keychain path. stdin
# avoids exposing it in argv, process listings, logs, or shell history.
printf '%s' "$TOKEN" | gh auth login --hostname github.com --git-protocol https --with-token >/dev/null

gh auth setup-git >/dev/null

if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  warn "gh authentication did not become active"
  return 1
fi

# Verify repository visibility and that this host's token can push. The API
# reports permissions without mutating a repo or creating a branch.
PERMISSION="$(gh api repos/dwhly/chief-core --jq '.permissions.push' 2>/dev/null || echo false)"
if [[ "$PERMISSION" != "true" ]]; then
  warn "GitHub token authenticates but lacks push permission on dwhly/chief-core"
  return 1
fi

if ! git ls-remote https://github.com/dwhly/chief-core.git HEAD >/dev/null 2>&1; then
  warn "Git credential helper could not read dwhly/chief-core"
  return 1
fi

ok "gh authenticated on h-mini2 with Chief repo push access"
ok "GitHub build auth complete"
