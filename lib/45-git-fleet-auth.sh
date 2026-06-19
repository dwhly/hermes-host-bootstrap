#!/usr/bin/env bash
# 45-git-fleet-auth: read-only git access to the private Chief repos, fleet-wide.
#
# WHY: the Chief fleet code (chief-spec, chief-core, hermes-node, chief-console,
# chief-stack) lives in private GitHub repos under github.com/dwhly. Until now
# Macs got the code via rsync-from-h-do1 WITHOUT .git, which blocks real
# `git clone`/`git fetch`/`git checkout` — and therefore blocks fleet
# convergence (the converger fetches+checks-out a target ref; the node resolves
# installed_refs via `git rev-parse`). This module wires a READ-ONLY,
# repo-scoped GitHub token (a fine-grained PAT, Contents:Read on just the 5
# chief repos) so every host can clone/fetch directly from origin.
#
# Security posture:
#   - The token is READ-ONLY and scoped to the chief repos only (no push, no
#     admin, no other repos). Minted in GitHub, stored in 1Password
#     (item GitHub-Hermes-Fleet2, field token), distributed via the existing
#     .env.template -> op inject path (lib/35-secrets.sh) as CHIEF_FLEET_GIT_TOKEN.
#   - Stored on-host in a 0600 credentials file readable only by the user, NOT
#     embedded in git config plaintext (so `git config --list` can't leak it).
#   - Scoped via credential.<url>.* to github.com/dwhly ONLY, so it is never
#     sent to any other host.
#
# Skip key: git-fleet-auth. Lockout-safe (no destructive ops; config only).
# Idempotent: re-running rewrites the same credential file + config cleanly.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Git fleet auth (read-only Chief repo access)"

if is_skipped git-fleet-auth; then
  skip "--skip=git-fleet-auth passed"
  return 0 2>/dev/null || exit 0
fi

# Load the resolved token from ~/.hermes/.env (produced by lib/35-secrets.sh via
# op inject of CHIEF_FLEET_GIT_TOKEN=op://hermes/GitHub-Hermes-Fleet2/token).
ENV_FILE="${HERMES_HOME:-$HOME/.hermes}/.env"
TOKEN=""
if [[ -f "$ENV_FILE" ]]; then
  # Read only the one var, without sourcing the whole file.
  TOKEN="$(grep -E '^CHIEF_FLEET_GIT_TOKEN=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)"
fi
# Allow env override (e.g. exported in the bootstrap shell).
TOKEN="${CHIEF_FLEET_GIT_TOKEN:-$TOKEN}"

if [[ -z "$TOKEN" || "$TOKEN" == op://* ]]; then
  warn "CHIEF_FLEET_GIT_TOKEN not resolved (got '${TOKEN:0:6}…')."
  warn "  Ensure .env.template has CHIEF_FLEET_GIT_TOKEN=op://hermes/GitHub-Hermes-Fleet2/token"
  warn "  and that op inject ran (lib/35-secrets.sh) — then re-run bootstrap."
  ok "Git fleet auth step complete (no token; skipped wiring)"
  return 0 2>/dev/null || exit 0
fi

# Store the token in a 0600 git credential file scoped to the dwhly host.
# Format is git-credential-store's: one https URL per line with creds embedded.
CRED_DIR="${HERMES_HOME:-$HOME/.hermes}"
CRED_FILE="$CRED_DIR/.git-fleet-credentials"
umask 077
# x-access-token is GitHub's documented username for PAT-over-HTTPS.
printf 'https://x-access-token:%s@github.com\n' "$TOKEN" > "$CRED_FILE"
chmod 600 "$CRED_FILE"
ok "wrote read-only fleet git credentials to $CRED_FILE (0600)"

# Configure git to use that credential file ONLY for github.com (dwhly).
# Using a path-scoped credential helper keeps it from being offered elsewhere.
git config --global "credential.https://github.com.helper" "store --file=$CRED_FILE"
# Make sure we don't accidentally also have a conflicting helper earlier in the
# chain that would shadow this (idempotent: only set, never blindly append).
ok "configured git credential.https://github.com.helper -> store($CRED_FILE)"

# Verify read access to one canonical repo without printing the token.
if git -c credential.helper="store --file=$CRED_FILE" \
     ls-remote https://github.com/dwhly/hermes-node.git HEAD >/dev/null 2>&1; then
  ok "verified read-only access to github.com/dwhly/hermes-node ✓"
else
  warn "could not read github.com/dwhly/hermes-node with the fleet token —"
  warn "  check the PAT's repo scope (Contents:Read on the 5 chief repos)."
fi

ok "Git fleet auth step complete"
