#!/usr/bin/env bash
# 62-fleet-company-db: the per-company Postgres record (Postgres 16 + pgBackRest WAL archiving to
# the company's own bucket) on company nodes only. EDD-fleet-architecture §9 step 2, r3.5, D4, D5.
#
# OPT-IN PER HOST: runs only where config/fleet-company-db/<host>.env exists (the reviewed,
# git-tracked desired state). Every other host skips, so a fleet-wide bootstrap never installs a
# database by accident. Today that is h-af (AmForge) and h-btp (BTP).
#
# Payload: fleet-company-db/ is copied to /usr/local/lib/fleet-company-db/<sha256-prefix>/ and
# /usr/local/lib/fleet-company-db/current is swapped to it (a running invocation keeps its dir);
# /usr/local/sbin/fleet-company-db points into `current`. Then `fleet-company-db install` converges.
# It is idempotent and fail-closed: until the owner steps are done (bucket, token, passphrase in the
# company's 1Password) it HOLDs before creating a cluster, and nothing else on the host changes.
#
# Skip key: fleet-company-db. Tier: E for opted-in hosts (the record of the company).
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

step "Fleet company database (Postgres + WAL archiving)"

if is_skipped fleet-company-db; then
  skip "fleet-company-db skipped (--skip)"; return 0 2>/dev/null || exit 0
fi
FCDB_HOST="${FLEET_HOST_ID:-$(hostname -s)}"
FCDB_CONFIG_DIR="${FCDB_CONFIG_DIR:-$REPO_ROOT/config/fleet-company-db}"
DESIRED="$FCDB_CONFIG_DIR/$FCDB_HOST.env"
if [[ ! -f "$DESIRED" ]]; then
  skip "no desired state for $FCDB_HOST ($DESIRED): not a company database node"
  return 0 2>/dev/null || exit 0
fi
# Dan's "roll it out" is a reviewed one-line change to ROLLOUT=go in the host's desired file.
# Until then nothing at all is written on the host (not even the payload).
if ! grep -qx 'ROLLOUT=go' "$DESIRED"; then
  skip "fleet-company-db on $FCDB_HOST: ROLLOUT is not go (held for the owner's roll-out)"
  return 0 2>/dev/null || exit 0
fi
if [[ "$OS" != "ubuntu" ]]; then
  warn "fleet-company-db supports Ubuntu 24.04 only (OS=$OS); skipping"
  return 0 2>/dev/null || exit 0
fi
require_sudo

SRC="$REPO_ROOT/fleet-company-db"
DIGEST="$(cd "$SRC" && find . -type f ! -name '*.pyc' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)"
DEST="/usr/local/lib/fleet-company-db/$DIGEST"
if [[ ! -d "$DEST" ]]; then
  info "installing payload $DIGEST"
  sudo install -d -m 0755 /usr/local/lib/fleet-company-db
  TMPD="$(sudo mktemp -d /usr/local/lib/fleet-company-db/.new.XXXXXX)"
  sudo cp -r "$SRC/." "$TMPD/"
  sudo find "$TMPD" -name '__pycache__' -prune -exec rm -rf {} +
  sudo chown -R root:root "$TMPD"; sudo chmod -R go-w "$TMPD"; sudo chmod 0755 "$TMPD" "$TMPD/bin/fleet-company-db"
  sudo mv "$TMPD" "$DEST"
fi
sudo ln -sfn "$DEST" /usr/local/lib/fleet-company-db/current.new
sudo mv -T /usr/local/lib/fleet-company-db/current.new /usr/local/lib/fleet-company-db/current
sudo ln -sfn /usr/local/lib/fleet-company-db/current/bin/fleet-company-db /usr/local/sbin/fleet-company-db

rc=0
sudo /usr/local/sbin/fleet-company-db install --desired "$DESIRED" || rc=$?
case "$rc" in
  0) ok "fleet-company-db converged ($FCDB_HOST, payload $DIGEST)" ;;
  3) warn "fleet-company-db HOLD on $FCDB_HOST: owner step pending (no cluster created/changed)" ;;
  *) err "fleet-company-db install failed on $FCDB_HOST (rc=$rc)"; exit "$rc" ;;
esac
