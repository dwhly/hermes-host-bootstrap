#!/usr/bin/env bash
# M9-mac-config-pull: keep a Mac's ~/.hermes (hermes-config) current with the fleet.
#
# Before this module nothing scheduled the peer pull on Macs: 92-hermes-config pulls
# once at bootstrap, so a Mac silently froze at whatever commit it had (h-mini2 was
# 10,077 commits behind in 2026-11). This installs a per-user LaunchAgent that runs
# ~/.hermes/scripts/hermes-config-pull.sh --quiet at load and every 30 minutes.
# It uses StartCalendarInterval (not StartInterval): launchd runs a calendar slot
# missed during sleep once on wake, so sleeping laptops catch up.
#
# The agent never passes --adopt-fleet: a Mac with unharvested local commits is
# left in place and the pull tool logs "blocked" instead of dropping work. Local
# edits are handled by the pull tool itself (regenerable files reset, others
# stashed with a HARVEST NEEDED line, host overlay re-applied).
#
# Scope: macOS, client role, recommended tier, ~/.hermes git-tracked with the pull tool.
# Knobs (~/.hermes-bootstrap.conf or env):
#   HERMES_CONFIG_PULL_SCHEDULE=1|0     default 1; 0 removes the agent
#   HERMES_CONFIG_PULL_INTERVAL_MIN=30  minutes between pulls: 10, 15, 20, 30 or 60
# Skip key: config-pull-schedule (leaves any existing agent as is).

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Hermes config pull schedule (macOS)"

if [[ "$OS" != "macos" ]]; then
  skip "config-pull schedule is macOS-only"
  return 0 2>/dev/null || exit 0
fi
if is_skipped config-pull-schedule; then
  skip "config-pull schedule: opted out via --skip (agent left as is)"
  return 0 2>/dev/null || exit 0
fi

label="com.hermes.config-pull"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
hermes_home="${HERMES_HOME:-$HOME/.hermes}"
pull_script="$hermes_home/scripts/hermes-config-pull.sh"
log_dir="$hermes_home/logs"
host_short="${HERMES_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"
host_short="${host_short%.local}"
want="${HERMES_CONFIG_PULL_SCHEDULE:-1}"
interval_min="${HERMES_CONFIG_PULL_INTERVAL_MIN:-30}"

remove_agent() { # remove_agent <why>
  if [[ -f "$plist" ]]; then
    launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
    rm -f "$plist"
    ok "removed config-pull agent from $host_short ($1)"
  else
    skip "config-pull agent not installed on $host_short ($1)"
  fi
}

case "$want" in
  1) ;;
  0) remove_agent "opted out via HERMES_CONFIG_PULL_SCHEDULE=0"; return 0 2>/dev/null || exit 0 ;;
  *) warn "invalid HERMES_CONFIG_PULL_SCHEDULE=$want (use 1 or 0)"; return 1 2>/dev/null || exit 1 ;;
esac
case "$interval_min" in
  10|15|20|30|60) ;;
  *) warn "invalid HERMES_CONFIG_PULL_INTERVAL_MIN=$interval_min (use 10, 15, 20, 30 or 60)"; return 1 2>/dev/null || exit 1 ;;
esac

if ! role_includes client || ! tier_allows R; then
  remove_agent "needs a Mac client on the recommended tier"
  return 0 2>/dev/null || exit 0
fi
if [[ ! -d "$hermes_home/.git" ]]; then
  skip "config-pull: $hermes_home is not git-tracked (92-hermes-config clones it first)"
  return 0 2>/dev/null || exit 0
fi
if [[ ! -f "$pull_script" ]]; then
  warn "config-pull: $pull_script missing; run hermes-config pull once by hand"
  return 0 2>/dev/null || exit 0
fi

mkdir -p "$log_dir" "$HOME/Library/LaunchAgents"
# One calendar slot per interval within the hour, offset by 7 minutes.
slots=""
minute=7
while (( minute < 60 )); do
  slots+="    <dict><key>Minute</key><integer>$minute</integer></dict>"$'\n'
  minute=$(( minute + interval_min ))
done
agent_path="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# XML-escape every interpolated path (a HERMES_HOME may contain & < >).
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
x_script="$(xml "$pull_script")"; x_home="$(xml "$hermes_home")"
x_log="$(xml "$log_dir/config-pull.log")"; x_path="$(xml "$agent_path")"
cat >"$plist.tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$x_script</string><string>--quiet</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartCalendarInterval</key>
  <array>
$slots  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HERMES_HOME</key><string>$x_home</string>
    <key>PATH</key><string>$x_path</string>
  </dict>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>StandardOutPath</key><string>$x_log</string>
  <key>StandardErrorPath</key><string>$x_log</string>
</dict>
</plist>
PLIST
plutil -lint "$plist.tmp" >/dev/null
if cmp -s "$plist.tmp" "$plist"; then
  rm -f "$plist.tmp"
else
  mv -f "$plist.tmp" "$plist"
  if launchctl print "$domain/$label" >/dev/null 2>&1; then
    # Changed definition: reload. bootout is async; bootstrapping too early fails (EIO).
    launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      launchctl print "$domain/$label" >/dev/null 2>&1 || break
      sleep 0.5
    done
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
      warn "config-pull: old agent still loaded after bootout; new definition not active (rerun bootstrap)"
      return 1 2>/dev/null || exit 1
    fi
  fi
fi
if ! launchctl print "$domain/$label" >/dev/null 2>&1; then
  launchctl enable "$domain/$label"
  launchctl bootstrap "$domain" "$plist"
fi
launchctl print "$domain/$label" >/dev/null
ok "config-pull agent loaded on $host_short (at login and every ${interval_min} min; log $log_dir/config-pull.log)"
