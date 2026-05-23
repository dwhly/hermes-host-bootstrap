#!/usr/bin/env bash
# A0-remote-desktop: xrdp + XFCE on the SERVER side. Loopback-bound by default.
#
# After this runs:
#   - xrdp listens on 127.0.0.1:3389 (NOT exposed publicly)
#   - XFCE is the desktop xrdp logs you into
#   - To connect from your Mac, you tunnel 3389 over Tailscale or ssh:
#       ssh -L 3389:localhost:3389 you@vps
#     Then open Microsoft Remote Desktop, connect to: localhost:3389
#
# Set HERMES_RDP_PUBLIC=1 to bind xrdp to 0.0.0.0 (NOT recommended unless
# you also know what you're doing with ufw + fail2ban).

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Remote desktop (xrdp + XFCE)"

if is_skipped remote-desktop; then
  skip "--skip=remote-desktop passed"
  return 0 2>/dev/null || exit 0
fi

# Server role only — don't install a desktop on your Mac
if ! role_includes server; then
  skip "role=$ROLE — remote desktop only installs on server/both"
  return 0 2>/dev/null || exit 0
fi

# Linux only
if [[ "$OS" == "macos" ]]; then
  skip "macOS — has built-in Screen Sharing; nothing to install"
  return 0 2>/dev/null || exit 0
fi

# This is the one module that defaults to OFF — it adds ~250MB of desktop
# packages, which you don't want unless you explicitly asked for a GUI.
# Opt in via --tier=full OR --only=A0-remote-desktop OR HERMES_RDP=1.
if [[ "$TIER" != "full" ]] && [[ "${HERMES_RDP:-0}" != "1" ]]; then
  is_only=0
  for m in "${ONLY_MODS[@]:-}"; do
    [[ "$m" == "A0-remote-desktop" ]] && is_only=1
  done
  if [[ "$is_only" -eq 0 ]]; then
    skip "remote desktop is opt-in (use --tier=full, --only=A0-remote-desktop, or HERMES_RDP=1)"
    return 0 2>/dev/null || exit 0
  fi
fi

require_sudo
apt_refresh

# ── Install XFCE (lightweight, ~150MB) ──────────────────────────────
info "installing XFCE core (xfce4 + xfce4-goodies)"
apt_install xfce4 xfce4-goodies dbus-x11 x11-xserver-utils

# ── Install xrdp ────────────────────────────────────────────────────
info "installing xrdp"
apt_install xrdp

# Add xrdp user to ssl-cert group so it can read /etc/ssl/private/ssl-cert-snakeoil.key
sudo adduser xrdp ssl-cert >/dev/null 2>&1 || true

# ── Configure xrdp to start XFCE ────────────────────────────────────
target_user="${SUDO_USER:-$USER}"
target_home=$(eval echo "~$target_user")
xsession_file="$target_home/.xsession"

if [[ ! -f "$xsession_file" ]] || ! grep -q "startxfce4" "$xsession_file"; then
  echo "startxfce4" | sudo -u "$target_user" tee "$xsession_file" >/dev/null
  sudo -u "$target_user" chmod +x "$xsession_file"
  ok "wrote $xsession_file → startxfce4"
else
  skip "$xsession_file already configured"
fi

# ── Bind xrdp to loopback only (unless HERMES_RDP_PUBLIC=1) ─────────
xrdp_ini="/etc/xrdp/xrdp.ini"
if [[ -f "$xrdp_ini" ]]; then
  backup_once "$xrdp_ini"
  if [[ "${HERMES_RDP_PUBLIC:-0}" == "1" ]]; then
    sudo sed -ri 's/^address=.*/address=0.0.0.0/' "$xrdp_ini"
    if ! grep -q '^address=' "$xrdp_ini"; then
      sudo sed -ri '0,/^\[Globals\]/{s/^\[Globals\]/[Globals]\naddress=0.0.0.0/}' "$xrdp_ini"
    fi
    warn "xrdp bound to 0.0.0.0 (HERMES_RDP_PUBLIC=1) — make sure ufw + fail2ban are configured"
  else
    sudo sed -ri 's/^address=.*/address=127.0.0.1/' "$xrdp_ini"
    if ! grep -q '^address=' "$xrdp_ini"; then
      # No existing line — insert after [Globals]
      sudo sed -ri '0,/^\[Globals\]/{s/^\[Globals\]/[Globals]\naddress=127.0.0.1/}' "$xrdp_ini"
    fi
    ok "xrdp bound to 127.0.0.1 (reach it via ssh tunnel or Tailscale)"
  fi
fi

# ── Polkit rule so xrdp users don't get auth popups for NetworkManager etc.
polkit_rule="/etc/polkit-1/localauthority/50-local.d/45-allow-colord.pkla"
if [[ ! -f "$polkit_rule" ]]; then
  sudo mkdir -p "$(dirname "$polkit_rule")"
  sudo tee "$polkit_rule" >/dev/null <<'EOF'
[Allow Colord all Users]
Identity=unix-user:*
Action=org.freedesktop.color-manager.create-device;org.freedesktop.color-manager.create-profile;org.freedesktop.color-manager.delete-device;org.freedesktop.color-manager.delete-profile;org.freedesktop.color-manager.modify-device;org.freedesktop.color-manager.modify-profile
ResultAny=no
ResultInactive=no
ResultActive=yes
EOF
  ok "added polkit rule to suppress colord auth popups"
fi

# ── Enable + start xrdp ─────────────────────────────────────────────
sudo systemctl enable --now xrdp >/dev/null 2>&1 || true
sudo systemctl enable --now xrdp-sesman >/dev/null 2>&1 || true

# Show status
if sudo systemctl is-active --quiet xrdp; then
  ok "xrdp service is running"
else
  warn "xrdp service is not active — check: sudo systemctl status xrdp"
fi

# ── Print connection instructions ──────────────────────────────────
echo ""
info "Remote desktop ready. To connect from your Mac:"
echo "    1. Install Microsoft Remote Desktop (free, App Store)"
if [[ "${HERMES_RDP_PUBLIC:-0}" == "1" ]]; then
  echo "    2. Connect to:  $(hostname -I 2>/dev/null | awk '{print $1}'):3389"
else
  echo "    2. Tunnel the port:  ssh -L 3389:localhost:3389 $target_user@$(hostname)"
  echo "       (or use Tailscale: tailscale serve --tcp=3389 tcp://localhost:3389)"
  echo "    3. In Remote Desktop, connect to:  localhost:3389"
fi
echo "    4. Log in with your Linux username + password"
echo "       (xrdp uses PAM — same creds as ssh password auth would use)"
echo ""

ok "Remote desktop setup complete"
