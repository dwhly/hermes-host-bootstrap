#!/usr/bin/env bash
# M6-mac-desktop-power: keep a desktop-role Mac awake while allowing its
# displays to sleep. Uses a per-user launchd caffeinate assertion so no sudo is
# needed and macOS battery policy remains untouched on non-opted-in laptops.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "macOS desktop power policy"

if [[ "$OS" != "macos" ]]; then
  skip "desktop power policy is macOS-only"
  return 0 2>/dev/null || exit 0
fi
if [[ "${HERMES_MAC_DESKTOP_ALWAYS_ON:-0}" != "1" ]]; then
  skip "desktop power policy not requested"
  return 0 2>/dev/null || exit 0
fi

display_minutes="${HERMES_MAC_DISPLAY_SLEEP_MINUTES:-30}"
case "$display_minutes" in
  ''|*[!0-9]*) warn "invalid HERMES_MAC_DISPLAY_SLEEP_MINUTES=$display_minutes"; return 1 2>/dev/null || exit 1 ;;
esac

effective="$(pmset -g custom)"
if ! printf '%s\n' "$effective" | grep -qE "^[[:space:]]*displaysleep[[:space:]]+$display_minutes$"; then
  warn "display sleep is not $display_minutes minutes"
  warn "set it once locally: sudo pmset -c displaysleep $display_minutes"
fi

label="com.hermes.keepawake"
plist="$HOME/Library/LaunchAgents/$label.plist"
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

domain="gui/$(id -u)"
if launchctl print "$domain/$label" >/dev/null 2>&1; then
  launchctl kickstart -k "$domain/$label"
else
  launchctl bootstrap "$domain" "$plist"
  launchctl enable "$domain/$label"
  launchctl kickstart -k "$domain/$label"
fi
launchctl print "$domain/$label" >/dev/null
ok "displays may sleep after $display_minutes minutes; caffeinate prevents idle system sleep"