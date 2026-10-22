#!/usr/bin/env bash
# M8-desktop-switcher-maintainer: the control-plane half of the Desktop switcher carry
# (M7 is the per-Mac half). On the one listed server host (h-do1) it installs a systemd
# timer that keeps the fork's fleet/desktop-switcher merged with upstream main, tests each
# merge on the test Mac before the fleet sees it, and messages Dan (hermes send ->
# Telegram) on conflicts, failed checks, or a Mac holding for over a day.
#
# Installs (root):
#   /usr/local/bin/hermes-desktop-carry-maintain
#   /usr/local/lib/hermes-desktop-carry/hermes-desktop-carry-check   (piped to the test Mac)
#   /etc/hermes-desktop-carry/{hosts,targets}  (from config/desktop-switcher-carry.*)
#   hermes-desktop-carry-maintain.{service,timer}  (every 3h, Persistent=true)
# State: /var/lib/hermes-desktop-carry/ (bare repo, status, alert dedupe).
#
# Scope (all must hold): Linux + systemd, role server, not --skip'd, and the host is
# listed in config/desktop-switcher-maintainer.host. A host removed from that list gets
# the timer disabled (state kept). --skip leaves it untouched.

set -euo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$MODULE_DIR/.." && pwd)}"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/common.sh"

step "Desktop switcher maintainer (control plane)"

if is_skipped desktop-switcher-maintainer; then
  skip "desktop-switcher-maintainer: opted out via --skip (left as is)"
  return 0 2>/dev/null || exit 0
fi
if [[ "$OS" == "macos" ]]; then
  skip "desktop-switcher-maintainer runs on the Linux control-plane host only"
  return 0 2>/dev/null || exit 0
fi

unit=hermes-desktop-carry-maintain
host_file="$REPO_ROOT/config/desktop-switcher-maintainer.host"
host_short="${HERMES_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"
SUDO="${SUDO-sudo}"
[[ "$(id -u)" == 0 ]] && SUDO=""
SYSTEMD_DIR="${HERMES_SYSTEMD_DIR:-/etc/systemd/system}"
BIN_DIR="${HERMES_CARRY_BIN_DIR:-/usr/local/bin}"
LIB_DIR="${HERMES_CARRY_LIB_DIR:-/usr/local/lib/hermes-desktop-carry}"
CONF_DIR="${HERMES_CARRY_CONF:-/etc/hermes-desktop-carry}"

listed() {
  [[ -f "$host_file" ]] && sed -e 's/#.*//' -e 's/[[:space:]]//g' "$host_file" | grep -Fqx -- "$host_short"
}

if ! role_includes server || ! listed; then
  if [[ -f "$SYSTEMD_DIR/$unit.timer" ]]; then
    $SUDO systemctl disable --now "$unit.timer" >/dev/null 2>&1 || true
    ok "disabled $unit.timer on $host_short (no longer in scope; state kept)"
  else
    skip "desktop-switcher-maintainer: $host_short not the listed control-plane host"
  fi
  return 0 2>/dev/null || exit 0
fi
if ! have systemctl; then
  warn "systemctl not present — cannot install $unit"
  return 0 2>/dev/null || exit 0
fi

$SUDO install -d -m 0755 "$BIN_DIR" "$LIB_DIR" "$CONF_DIR"
$SUDO install -m 0755 "$REPO_ROOT/scripts/hermes-desktop-carry-maintain" "$BIN_DIR/hermes-desktop-carry-maintain"
$SUDO install -m 0644 "$REPO_ROOT/scripts/hermes-desktop-carry-check" "$LIB_DIR/hermes-desktop-carry-check"
$SUDO install -m 0644 "$REPO_ROOT/config/desktop-switcher-carry.hosts" "$CONF_DIR/hosts"
$SUDO install -m 0644 "$REPO_ROOT/config/desktop-switcher-carry.targets" "$CONF_DIR/targets"

tmp="$(mktemp)"
cat >"$tmp.service" <<EOF
[Unit]
Description=Keep fleet/desktop-switcher merged with upstream (Desktop switcher carry)
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
Environment=HOME=/root
ExecStart=$BIN_DIR/hermes-desktop-carry-maintain
Nice=10
TimeoutStartSec=2h
EOF
cat >"$tmp.timer" <<EOF
[Unit]
Description=Run $unit every 3 hours

[Timer]
OnCalendar=*-*-* 01,04,07,10,13,16,19,22:30:00
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF
changed=0
for kind in service timer; do
  if ! cmp -s "$tmp.$kind" "$SYSTEMD_DIR/$unit.$kind" 2>/dev/null; then
    $SUDO install -m 0644 "$tmp.$kind" "$SYSTEMD_DIR/$unit.$kind"; changed=1
  fi
done
rm -f "$tmp" "$tmp.service" "$tmp.timer"
[[ "$changed" == 1 ]] && $SUDO systemctl daemon-reload
$SUDO systemctl enable --now "$unit.timer" >/dev/null 2>&1 || warn "could not enable $unit.timer"
if systemctl is-active --quiet "$unit.timer"; then
  ok "$unit.timer active on $host_short (every 3h; status: /var/lib/hermes-desktop-carry/status)"
else
  warn "$unit.timer not active — check: systemctl status $unit.timer"
fi
