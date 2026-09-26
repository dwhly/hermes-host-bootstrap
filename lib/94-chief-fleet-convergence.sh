#!/usr/bin/env bash
# Administrator installation only. Step 0 removes every historical sudo grant.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/common.sh"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
step "Chief fleet convergence containment"
if is_skipped chief-convergence; then
  skip "Chief fleet convergence skipped"
  exit 0
fi
require_sudo
# The source must be a reviewed ROOT-OWNED checkout. Do not execute a login-user
# checkout as root, and do not provision credentials/keys from a login HOME.
# A remote Mac with only today's grants uses chief-update then hermes-converger.
sudo /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/empty /bin/sh -s -- "$REPO_ROOT" <<'INSTALL'
set -eu
src=$1
# The administrator explicitly selected this reviewed source; require trust of
# the entire source chain before any installed root reader will use it.
# shellcheck source=hermes_converger/step0/trust.sh
. "$src/hermes_converger/step0/trust.sh"
trusted_tree "$src"
trusted_path /
for dir in /opt /opt/chief /opt/chief/bin /opt/chief/lib /opt/chief/lib/hermes-host-bootstrap; do
    [ ! -e "$dir" ] || trusted_path "$dir"
    /usr/bin/install -d -o root -m 0755 "$dir"
done
/bin/rm -rf /opt/chief/lib/hermes-host-bootstrap/hermes_converger
/bin/cp -R "$src/hermes_converger" /opt/chief/lib/hermes-host-bootstrap/
/bin/rm -f /var/lib/chief/currency-step0/prepared /var/lib/chief/currency-step0/grants-removed
exec /bin/sh /opt/chief/lib/hermes-host-bootstrap/hermes_converger/step0/close.sh
INSTALL
ok "Step 0 closure completed; inspect closure-status and visudo evidence"
