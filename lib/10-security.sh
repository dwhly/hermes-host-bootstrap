#!/usr/bin/env bash
# 10-security: ssh hardening, ufw, fail2ban, unattended-upgrades.
# Skipped entirely on macOS (different model).

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Security & hardening"

if [[ "$OS" == "macos" ]]; then
  skip "macOS — security hardening (ufw/fail2ban) does not apply"
  return 0 2>/dev/null || exit 0
fi

require_sudo
apt_refresh

# Essentials
if tier_allows E; then
  is_skipped openssh    || apt_install openssh-server openssh-client
  is_skipped ufw        || apt_install ufw
  is_skipped fail2ban   || apt_install fail2ban
  is_skipped unattended || apt_install unattended-upgrades
fi

# SSH hardening — only if HERMES_SSH_HARDEN=1 (default: prompt-safe, no auto changes)
if [[ "${HERMES_SSH_HARDEN:-0}" == "1" ]] && ! is_skipped ssh-harden; then
  info "hardening sshd_config (PasswordAuthentication=no, PermitRootLogin=prohibit-password)"
  backup_once /etc/ssh/sshd_config
  sudo sed -ri \
    -e 's/^#?PasswordAuthentication\s+.*/PasswordAuthentication no/' \
    -e 's/^#?PermitRootLogin\s+.*/PermitRootLogin prohibit-password/' \
    -e 's/^#?ChallengeResponseAuthentication\s+.*/ChallengeResponseAuthentication no/' \
    /etc/ssh/sshd_config
  if sudo sshd -t; then
    sudo systemctl reload ssh || sudo systemctl reload sshd
    ok "sshd reloaded with hardened config"
  else
    err "sshd config test failed — backup at /etc/ssh/sshd_config.bak.*; not reloading"
  fi
fi

# UFW — open ssh, deny rest. Won't enable unless HERMES_UFW_ENABLE=1.
if have ufw && ! is_skipped ufw; then
  sudo ufw allow ssh >/dev/null
  if [[ "${HERMES_UFW_ENABLE:-0}" == "1" ]]; then
    if sudo ufw status | grep -q "Status: active"; then
      skip "ufw already active"
    else
      sudo ufw --force default deny incoming >/dev/null
      sudo ufw --force default allow outgoing >/dev/null
      sudo ufw --force enable >/dev/null
      ok "ufw enabled (ssh allowed, rest denied)"
    fi
  else
    skip "ufw installed but not enabled (set HERMES_UFW_ENABLE=1 to enable)"
  fi
fi

# fail2ban — enable + start (defaults are sensible)
if have fail2ban-client && ! is_skipped fail2ban; then
  sudo systemctl enable --now fail2ban >/dev/null 2>&1 || true
  ok "fail2ban enabled (default ssh jail)"
fi

# unattended-upgrades — enable
if [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]] && ! is_skipped unattended; then
  sudo dpkg-reconfigure --priority=low -fnoninteractive unattended-upgrades >/dev/null 2>&1 || true
  ok "unattended-upgrades configured"
fi

ok "Security pass complete"
