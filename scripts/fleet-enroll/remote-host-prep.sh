#!/usr/bin/env bash
# remote-host-prep.sh <host> — runs ON the target as root. Idempotent host plumbing only:
#   * pin the fleet hostname so DigitalOcean cloud-init can't reset it on host restart
#   * make <host> resolve locally (/etc/hosts), so sudo/tools don't stall
#   * add a 2 GiB swapfile on small (<4 GiB) hosts with no swap, so a new process
#     (telemetry daemon, an hmw pane) can't OOM-kill the node's existing services
set -euo pipefail
host="$1"

if [[ "$(hostname -s)" != "$host" ]]; then
  hostnamectl set-hostname "$host"; echo "hostname set to $host"
else
  echo "hostname already $host"
fi

if [[ -d /etc/cloud/cloud.cfg.d ]]; then
  cfg=/etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg
  want=$'preserve_hostname: true\nmanage_etc_hosts: false'
  if [[ "$(cat "$cfg" 2>/dev/null)" != "$want" ]]; then
    printf '%s\n' "$want" >"$cfg"; echo "cloud-init hostname pin written ($cfg)"
  else
    echo "cloud-init hostname pin already present"
  fi
fi

if ! grep -qE "^127\.0\.1\.1[[:space:]].*\b${host}\b" /etc/hosts; then
  if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    # keep existing aliases (e.g. the droplet's original name); put the fleet name first
    sed -i -E "0,/^127\.0\.1\.1[[:space:]]/s/^127\.0\.1\.1[[:space:]]+/127.0.1.1 ${host} /" /etc/hosts
  else
    printf '127.0.1.1 %s\n' "$host" >>/etc/hosts
  fi
  echo "/etc/hosts: 127.0.1.1 $host"
fi

mem_mb="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
swap_mb="$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)"
if (( swap_mb == 0 && mem_mb < 4096 )); then
  if [[ ! -f /swapfile ]]; then
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null
  fi
  swapon /swapfile 2>/dev/null || true
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
  printf 'vm.swappiness=10\n' >/etc/sysctl.d/99-fleet-swap.conf && sysctl -q -p /etc/sysctl.d/99-fleet-swap.conf
  echo "swap: 2 GiB /swapfile enabled (RAM ${mem_mb} MB)"
else
  echo "swap: unchanged (RAM ${mem_mb} MB, swap ${swap_mb} MB)"
fi
