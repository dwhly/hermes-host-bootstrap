#!/usr/bin/env bash
# 00-preflight: hostname, timezone, apt upgrade, swap, sudo user sanity.
# Pure system hygiene — no app installs.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Preflight"

if [[ "$OS" == "macos" ]]; then
  skip "macOS — preflight (apt/swap/hostname) does not apply"
  return 0 2>/dev/null || exit 0
fi

require_sudo
apt_refresh

# 1. apt upgrade
if tier_allows E && ! is_skipped apt-upgrade; then
  info "upgrading installed packages"
  DEBIAN_FRONTEND=noninteractive sudo -E apt-get -y -q upgrade
  ok "apt upgrade complete"
fi

# 2. hostname (only if user passed HERMES_HOSTNAME)
if [[ -n "${HERMES_HOSTNAME:-}" ]]; then
  current="$(hostnamectl --static 2>/dev/null || hostname)"
  if [[ "$current" != "$HERMES_HOSTNAME" ]]; then
    sudo hostnamectl set-hostname "$HERMES_HOSTNAME"
    ok "hostname set: $current → $HERMES_HOSTNAME"
  else
    skip "hostname already $HERMES_HOSTNAME"
  fi
fi

# 3. timezone (default UTC unless HERMES_TZ set)
target_tz="${HERMES_TZ:-UTC}"
if have timedatectl; then
  current_tz="$(timedatectl show -p Timezone --value 2>/dev/null || echo unknown)"
  if [[ "$current_tz" != "$target_tz" ]]; then
    sudo timedatectl set-timezone "$target_tz" && ok "timezone: $current_tz → $target_tz"
  else
    skip "timezone already $target_tz"
  fi
fi

# 4. swap file (only if RAM < 4 GB AND no existing swap)
if tier_allows R && ! is_skipped swap; then
  ram_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
  ram_gb=$(( ram_kb / 1024 / 1024 ))
  swap_kb="$(awk '/SwapTotal/ {print $2}' /proc/meminfo)"
  if (( ram_gb < 4 )) && (( swap_kb == 0 )); then
    info "RAM is ${ram_gb}GB, no swap detected — creating /swapfile (2GB)"
    sudo fallocate -l 2G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile >/dev/null
    sudo swapon /swapfile
    ensure_line "/swapfile none swap sw 0 0" /etc/fstab
    ok "swap activated"
  else
    skip "swap: RAM=${ram_gb}GB swap=$(( swap_kb / 1024 ))MB — no change needed"
  fi
fi

# 5. enable-linger (so `hermes gateway` systemd-user service survives ssh logout)
# documented gotcha in the hermes-agent skill
if tier_allows E && ! is_skipped linger && have loginctl && [[ -n "${SUDO_USER:-$USER}" ]]; then
  target_user="${SUDO_USER:-$USER}"
  if ! loginctl show-user "$target_user" 2>/dev/null | grep -q "Linger=yes"; then
    sudo loginctl enable-linger "$target_user"
    ok "enable-linger for $target_user (hermes gateway will survive logout)"
  else
    skip "linger already enabled for $target_user"
  fi
fi

ok "Preflight complete"
