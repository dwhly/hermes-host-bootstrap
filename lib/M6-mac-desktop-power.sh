#!/usr/bin/env bash
# M6-mac-desktop-power: always-on power policy for DESKTOP-class Macs
# (Mac mini / Mac Studio / iMac / Mac Pro — anything without an internal
# battery), which the fleet typically runs headless. Laptops are never touched.
#
# Two layers, both idempotent:
#   1. Per-user launchd `caffeinate -i` assertion (com.hermes.keepawake).
#      No sudo. Blocks idle system sleep while the user session exists.
#   2. System pmset policy on AC power: sleep 0, womp 1, autorestart 1,
#      displaysleep N. Needs root, so it is applied only when passwordless
#      sudo is already available (never prompts); otherwise bootstrap prints
#      the exact one-time command. This layer keeps the Mac awake even with
#      no user session and brings it back after a power loss.
#
# Scope is decided by hardware, not hostname: any Mac with an internal
# battery is a laptop and is excluded (its keepawake agent is removed).
#
# Knobs (~/.hermes-bootstrap.conf or env):
#   HERMES_MAC_DESKTOP_ALWAYS_ON=auto|1|0   default auto (= on for desktops)
#     0 on a desktop opts out and removes the keepawake agent.
#     1 on a laptop is IGNORED (laptops never get the always-on policy).
#   HERMES_MAC_DISPLAY_SLEEP_MINUTES=30     displays may still sleep.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "macOS desktop power policy"

if [[ "$OS" != "macos" ]]; then
  skip "desktop power policy is macOS-only"
  return 0 2>/dev/null || exit 0
fi

label="com.hermes.keepawake"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
host_short="${HERMES_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"
want="${HERMES_MAC_DESKTOP_ALWAYS_ON:-auto}"

mac_has_internal_battery() {
  pmset -g batt 2>/dev/null | grep -q 'InternalBattery'
}

remove_keepawake() {
  local why="$1"
  if [[ -f "$plist" ]]; then
    launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
    rm -f "$plist"
    ok "removed keepawake policy from $host_short ($why)"
  else
    skip "keepawake policy not applied on $host_short ($why)"
  fi
}

# ── Scope gate: hardware class, then explicit opt-out ────────────────
if mac_has_internal_battery; then
  if [[ "$want" == "1" ]]; then
    warn "HERMES_MAC_DESKTOP_ALWAYS_ON=1 ignored: $host_short has a battery (laptop)"
  fi
  remove_keepawake "laptop"
  return 0 2>/dev/null || exit 0
fi

case "$want" in
  auto|1) ;;
  0)
    remove_keepawake "opted out via HERMES_MAC_DESKTOP_ALWAYS_ON=0"
    return 0 2>/dev/null || exit 0
    ;;
  *)
    warn "invalid HERMES_MAC_DESKTOP_ALWAYS_ON=$want (use auto, 1, or 0)"
    return 1 2>/dev/null || exit 1
    ;;
esac

display_minutes="${HERMES_MAC_DISPLAY_SLEEP_MINUTES:-30}"
case "$display_minutes" in
  ''|*[!0-9]*) warn "invalid HERMES_MAC_DISPLAY_SLEEP_MINUTES=$display_minutes"; return 1 2>/dev/null || exit 1 ;;
esac

# ── Layer 1: user-level caffeinate assertion (no sudo) ───────────────
mkdir -p "$HOME/Library/LaunchAgents"
cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/caffeinate</string><string>-i</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST
plutil -lint "$plist" >/dev/null

if launchctl print "$domain/$label" >/dev/null 2>&1; then
  launchctl kickstart -k "$domain/$label"
else
  launchctl bootstrap "$domain" "$plist"
  launchctl enable "$domain/$label"
  launchctl kickstart -k "$domain/$label"
fi
launchctl print "$domain/$label" >/dev/null
ok "keepawake agent running on $host_short (caffeinate -i blocks idle system sleep)"

# ── Layer 2: system pmset policy on AC power (root) ──────────────────
desired=("sleep 0" "womp 1" "autorestart 1" "displaysleep $display_minutes")
ac_section="$(pmset -g custom 2>/dev/null | awk '/^AC Power:/{f=1; next} /^[A-Za-z].*:$/{f=0} f')"
missing=()
for kv in "${desired[@]}"; do
  key="${kv%% *}"
  val="${kv#* }"
  if ! printf '%s\n' "$ac_section" | grep -qE "^[[:space:]]*${key}[[:space:]]+${val}$"; then
    missing+=("$key" "$val")
  fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
  ok "pmset AC policy in place (sleep 0, womp 1, autorestart 1, displaysleep $display_minutes)"
elif sudo -n true >/dev/null 2>&1; then
  sudo -n pmset -c "${missing[@]}"
  ok "applied pmset AC policy: ${missing[*]}"
else
  warn "pmset AC policy incomplete on $host_short; run once locally:"
  warn "  sudo pmset -c ${missing[*]}"
fi
