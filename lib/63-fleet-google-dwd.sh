#!/usr/bin/env bash
# 63-fleet-google-dwd: the shared Google Workspace domain-wide-delegation connector (one code path for every
# company, configured per company). Installs:
#   /usr/local/lib/fleet-google-dwd/<sha256-prefix>/  (fleet_google_dwd.py, the `dwd` shim, bin/), `current` swapped
#   /etc/fleet-google-dwd/<company>.yaml + host-company  (root:root 0644, from config/fleet-google-dwd/)
#   /usr/local/bin/fleet-google-dwd-check               (read-only smoke test, via the host's PYTHON)
# It writes NO secret, no token file and nothing in any home directory: the 1Password service-account token is an
# owner step (see the company yaml's op_token_file), and the module creates its audit log on first use as run_as.
#
# OPT-IN PER HOST: runs only where config/fleet-google-dwd/hosts/<host>.env exists and says ROLLOUT=go. Today that
# file exists for h-btp and h-af, both held. Both are preserved hosts: they get this module only by an explicit,
# owner-approved single-module run (skill fleet-preserved-hosts), never a full bootstrap.
#
# Skip key: fleet-google-dwd.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

step "Fleet Google DWD connector"

if is_skipped fleet-google-dwd; then
  skip "fleet-google-dwd skipped (--skip)"; return 0 2>/dev/null || exit 0
fi
FGD_HOST="${FLEET_HOST_ID:-$(hostname -s)}"
FGD_CONFIG_DIR="${FGD_CONFIG_DIR:-$REPO_ROOT/config/fleet-google-dwd}"
DESIRED="$FGD_CONFIG_DIR/hosts/$FGD_HOST.env"
if [[ ! -f "$DESIRED" ]]; then
  skip "no desired state for $FGD_HOST ($DESIRED): not a Google DWD node"
  return 0 2>/dev/null || exit 0
fi
if ! grep -qx 'ROLLOUT=go' "$DESIRED"; then
  skip "fleet-google-dwd on $FGD_HOST: ROLLOUT is not go (held for the owner's roll-out)"
  return 0 2>/dev/null || exit 0
fi
if [[ "$(uname -s)" != "Linux" ]]; then
  warn "fleet-google-dwd supports Linux company nodes only; skipping"
  return 0 2>/dev/null || exit 0
fi

# Read (never source) the two keys we need, each exactly once.
fgd_key() {
  local n
  n="$(grep -c "^$1=" "$DESIRED" || true)"
  [[ "$n" == 1 ]] || { err "$DESIRED: $1 must appear exactly once"; exit 1; }
  grep "^$1=" "$DESIRED" | cut -d= -f2-
}
COMPANY="$(fgd_key COMPANY)"
PY="$(fgd_key PYTHON)"
RUN_AS="$(fgd_key RUN_AS)"
[[ "$COMPANY" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { err "COMPANY '$COMPANY' is not a valid name"; exit 1; }
[[ "$PY" =~ ^/[A-Za-z0-9._/-]+$ && "$PY" != *..* ]] || { err "PYTHON must be an absolute path"; exit 1; }
[[ "$RUN_AS" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { err "RUN_AS '$RUN_AS' is not a valid user name"; exit 1; }
CFG="$FGD_CONFIG_DIR/companies/$COMPANY.yaml"
[[ -f "$CFG" ]] || { err "no company config $CFG"; exit 1; }
# The host file's RUN_AS must be the company yaml's run_as.user (the module enforces the same at runtime).
[[ "$(grep -A2 -x 'run_as:' "$CFG" | grep -cx "  user: $RUN_AS")" == 1 ]] \
  || { err "RUN_AS=$RUN_AS does not match run_as.user in $CFG"; exit 1; }
id -u "$RUN_AS" >/dev/null 2>&1 || { err "user $RUN_AS does not exist on $FGD_HOST"; exit 1; }
[[ -x "$PY" ]] || { err "PYTHON $PY is not executable on $FGD_HOST"; exit 1; }
require_sudo

# The interpreter only ever runs as the company's run_as user: a venv that user can write (site-packages, .pth)
# must never execute as root just because the python binary itself is root-owned.
if [[ "$RUN_AS" == root ]]; then
  sudo "$PY" -c 'import yaml, cryptography' </dev/null || { err "$PY lacks PyYAML/cryptography"; exit 1; }
else
  sudo runuser -u "$RUN_AS" -- "$PY" -c 'import yaml, cryptography' </dev/null \
    || { err "$PY lacks PyYAML/cryptography"; exit 1; }
fi

SRC="$REPO_ROOT/fleet-google-dwd"
DIGEST="$(cd "$SRC" && find . -type f ! -name '*.pyc' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)"
DEST="/usr/local/lib/fleet-google-dwd/$DIGEST"
if [[ ! -d "$DEST" ]]; then
  info "installing payload $DIGEST"
  sudo install -d -m 0755 -o root -g root /usr/local/lib/fleet-google-dwd
  TMPD="$(sudo mktemp -d /usr/local/lib/fleet-google-dwd/.new.XXXXXX)"
  sudo cp -r "$SRC/." "$TMPD/"
  sudo find "$TMPD" -name '__pycache__' -prune -exec rm -rf {} +
  sudo chown -R root:root "$TMPD"; sudo chmod -R go-w "$TMPD"; sudo chmod 0755 "$TMPD" "$TMPD/bin/fleet-google-dwd-check"
  sudo mv "$TMPD" "$DEST"
fi
sudo ln -sfn "$DEST" /usr/local/lib/fleet-google-dwd/current.new
sudo mv -T /usr/local/lib/fleet-google-dwd/current.new /usr/local/lib/fleet-google-dwd/current

sudo install -d -m 0755 -o root -g root /etc/fleet-google-dwd
sudo install -m 0644 -o root -g root "$CFG" "/etc/fleet-google-dwd/$COMPANY.yaml"
printf '%s\n' "$COMPANY" | sudo tee /etc/fleet-google-dwd/host-company.new >/dev/null
sudo chown root:root /etc/fleet-google-dwd/host-company.new
sudo chmod 0644 /etc/fleet-google-dwd/host-company.new
sudo mv -T /etc/fleet-google-dwd/host-company.new /etc/fleet-google-dwd/host-company

WRAP="$(mktemp)"
cat > "$WRAP" <<EOF
#!/bin/sh
# Installed by hermes-host-bootstrap lib/63-fleet-google-dwd.sh. Runs ONLY as $RUN_AS (never root-runs a user venv).
if [ "\$(id -un)" != '$RUN_AS' ]; then
  echo "fleet-google-dwd-check: run it as $RUN_AS (e.g. runuser -u $RUN_AS -- fleet-google-dwd-check)" >&2; exit 2
fi
exec '$PY' /usr/local/lib/fleet-google-dwd/current/bin/fleet-google-dwd-check "\$@"
EOF
sudo install -m 0755 -o root -g root "$WRAP" /usr/local/bin/fleet-google-dwd-check
rm -f "$WRAP"
ok "fleet-google-dwd installed ($FGD_HOST, company $COMPANY, payload $DIGEST); smoke: fleet-google-dwd-check"
