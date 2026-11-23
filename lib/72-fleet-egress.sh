#!/usr/bin/env bash
# 72-fleet-egress: residential egress for bot-walled sites (YouTube transcripts first), as a fleet service.
#
# WHY: YouTube (and other sites) block cloud/datacenter IPs by source address, so a transcript fetch that
# works on a home Mac fails on every DigitalOcean host. The fix is egress routing, done ONCE for the fleet:
#   * every host  -> the client commands `fleet-yt-transcript` and `fleet-egress` (symlinked from this checkout)
#   * the boss    -> the gateway: an allowlisting HTTP CONNECT proxy on <tailnet-ip>:3128 whose upstream
#                    route order is a rotating residential pool (Webshare, paid) FIRST and Dan's home IP
#                    (ssh -D tunnels to the Minis) as a capped LAST-RESORT reserve only (owner policy).
# Design, vendor ranking and benchmark: fleet-egress/README.md, fleet-egress/RANKING.md;
# wiki capabilities/fleet-egress.md; skill media/youtube-transcripts.
#
# Secrets: the pool credential is rebuilt from 1Password (vault hermes, item Webshare, fields
# proxy_username / proxy_password) into /etc/fleet-egress/secrets.env (0600). If 1Password can't be read
# the existing file is kept untouched; values are never printed.
# Skip key: fleet-egress.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONTROL_PLANE_IP="100.122.202.37"

step "fleet-egress (residential egress gateway + transcript client)"

if ! tier_allows R; then
  skip "fleet-egress skipped (tier below R)"
  return 0 2>/dev/null || exit 0
fi
if is_skipped fleet-egress; then
  skip "fleet-egress skipped (HERMES_SKIP includes fleet-egress)"
  return 0 2>/dev/null || exit 0
fi

# ── 1) client commands, every host ─────────────────────────────────────
mkdir -p "$HOME/.local/bin"
for c in fleet-yt-transcript fleet-egress; do
  src="$REPO_ROOT/scripts/$c"
  [[ -f "$src" ]] || { warn "missing $src"; continue; }
  chmod 0755 "$src"
  ln -sfn "$src" "$HOME/.local/bin/$c"
  ok "$c → $HOME/.local/bin/$c"
done
if ! have uv && [[ ! -x "$HOME/.local/bin/uv" ]]; then
  warn "uv not found — fleet-yt-transcript is a uv script; install uv (lib/50-languages.sh) for it to run"
fi

# ── 2) gateway, boss only ──────────────────────────────────────────────
if [[ "$OS" == "macos" ]] || ! have systemctl; then
  skip "gateway: not a systemd host — client only"
  return 0 2>/dev/null || exit 0
fi
if ! ip -4 addr show 2>/dev/null | grep -q "inet ${CONTROL_PLANE_IP}/"; then
  skip "gateway: this host does not own ${CONTROL_PLANE_IP} (not the boss) — client only"
  return 0 2>/dev/null || exit 0
fi

SRC_DIR="$REPO_ROOT/fleet-egress"
ETC=/etc/fleet-egress
changed=0
inst() {  # inst <mode> <src> <dst>: install only when content differs; sets changed=1
  if ! sudo cmp -s "$2" "$3" 2>/dev/null; then
    sudo install -D -m "$1" "$2" "$3"; changed=1; info "installed $3"
  fi
}
sudo install -d -m 0755 /opt/fleet-egress "$ETC"
inst 0644 "$SRC_DIR/fleet_egress_gateway.py" /opt/fleet-egress/fleet_egress_gateway.py
inst 0644 "$SRC_DIR/config.json" "$ETC/config.json"
inst 0644 "$SRC_DIR/systemd/fleet-egress-gateway.service" /etc/systemd/system/fleet-egress-gateway.service
inst 0644 "$SRC_DIR/systemd/fleet-egress-tunnel@.service" /etc/systemd/system/fleet-egress-tunnel@.service

# Home-IP reserve tunnels (non-secret: ssh target + local SOCKS port), one per tunnels/<host>.env.
tunnels=(); tchanged=()
for t in "$SRC_DIR"/tunnels/*.env; do
  [[ -f "$t" ]] || continue
  name="$(basename "$t" .env)"; tunnels+=("$name")
  before="$changed"; changed=0
  inst 0644 "$t" "$ETC/tunnel-$name.env"
  [[ "$changed" == 1 ]] && tchanged+=("$name")
  changed=$(( before | changed ))
done

# Pool credential from 1Password → secrets.env (kept as-is when op is unavailable).
render_secrets() {
  if [[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" && -f "$HOME/.hermes-bootstrap.conf" ]]; then
    # shellcheck disable=SC1091
    . "$HOME/.hermes-bootstrap.conf" || true
  fi
  have op || { warn "op not installed — keeping existing $ETC/secrets.env"; return 0; }
  local u p tmp
  if ! u="$(op read 'op://hermes/Webshare/proxy_username' 2>/dev/null)" \
     || ! p="$(op read 'op://hermes/Webshare/proxy_password' 2>/dev/null)" || [[ -z "$u" || -z "$p" ]]; then
    warn "could not read op://hermes/Webshare/proxy_{username,password} — keeping existing $ETC/secrets.env (paid route stays as it was)"
    return 0
  fi
  tmp="$(umask 077; mktemp)"
  # Webshare rotating endpoint: <username>-rotate @ p.webshare.io:80. Values go via stdin, never argv.
  printf '%s\n%s\n' "$u" "$p" | python3 -c '
import sys, urllib.parse as q
u, p = sys.stdin.read().split("\n")[:2]
print("FLEET_EGRESS_PAID_PROXY_URL=http://%s:%s@p.webshare.io:80" % (q.quote(u + "-rotate", safe=""), q.quote(p, safe="")))
' >"$tmp"
  unset u p
  if ! sudo cmp -s "$tmp" "$ETC/secrets.env" 2>/dev/null; then
    sudo install -m 0600 -o root -g root "$tmp" "$ETC/secrets.env"; changed=1; info "secrets.env refreshed from 1Password"
  fi
  rm -f "$tmp"
}
render_secrets

sudo systemctl daemon-reload
sudo systemctl enable fleet-egress-gateway.service >/dev/null 2>&1 || true
for name in "${tunnels[@]}"; do
  sudo systemctl enable "fleet-egress-tunnel@$name.service" >/dev/null 2>&1 || true
  if [[ " ${tchanged[*]:-} " == *" $name "* ]] || ! systemctl is-active --quiet "fleet-egress-tunnel@$name.service"; then
    sudo systemctl restart "fleet-egress-tunnel@$name.service"
  fi
done
if [[ "$changed" == 1 ]] || ! systemctl is-active --quiet fleet-egress-gateway.service; then
  sudo systemctl restart fleet-egress-gateway.service
fi

sleep 2
if st="$(curl -s -m5 "http://127.0.0.1:3128/status")" && [[ -n "$st" ]]; then
  routes="$(printf '%s' "$st" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["routes"]))' 2>/dev/null || echo '?')"
  ok "fleet-egress gateway active — http://${CONTROL_PLANE_IP}:3128 (routes: $routes)"
  [[ "$routes" == *paid-residential* ]] || warn "paid-residential route inactive (no secrets.env) — YouTube falls back to the capped home reserve"
else
  warn "fleet-egress gateway not answering — check: systemctl status fleet-egress-gateway"
fi
