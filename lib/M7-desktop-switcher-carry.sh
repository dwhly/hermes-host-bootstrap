#!/usr/bin/env bash
# M7-desktop-switcher-carry: carry the Desktop gateway switcher (upstream PR #125267)
# on fleet Mac clients until upstream merges it.
#
# Installs (user-level, no sudo):
#   ~/.local/bin/hermes-desktop-carry-sync      (copied from scripts/, digest-checked)
#   ~/Library/LaunchAgents/com.hermes.desktop-carry.plist
#       runs the sync at load/login and at 00,03,...,21 h; StartCalendarInterval events
#       missed while asleep are run once on wake.
# The sync is GIT ONLY (see the script header): it parks ~/.hermes/hermes-agent on
# carry/desktop-switcher, merges the fork's fleet/desktop-switcher when needed and sets
# updates.parked_branch_strategy=update_in_place. The next normal update rebuilds Desktop.
#
# Scope (all must hold): macOS, role client, tier recommended+, not --skip'd, and the
# host is listed in config/desktop-switcher-carry.hosts (reviewed desired state; one host
# per line, activated host by host). A host removed from the list gets the agent removed;
# its checkout is left as is (rollback is manual and documented in the wiki). A Mac that
# leaves scope by role or tier also gets the agent removed; --skip leaves it untouched.

set -euo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$MODULE_DIR/.." && pwd)}"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/common.sh"

step "Desktop switcher carry"

if [[ "$OS" != "macos" ]]; then
  skip "desktop-switcher-carry is macOS-only"
  return 0 2>/dev/null || exit 0
fi
if is_skipped desktop-switcher-carry; then
  skip "desktop-switcher-carry: opted out via --skip (agent left as is)"
  return 0 2>/dev/null || exit 0
fi

label="com.hermes.desktop-carry"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
bin_dir="$HOME/.local/bin"
target="$bin_dir/hermes-desktop-carry-sync"
source_script="$REPO_ROOT/scripts/hermes-desktop-carry-sync"
hosts_file="$REPO_ROOT/config/desktop-switcher-carry.hosts"
hermes_home="${HERMES_HOME:-$HOME/.hermes}"
state_dir="$hermes_home/desktop-carry"
host_short="${HERMES_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"
host_short="${host_short%.local}"

listed() {
  [[ -f "$hosts_file" ]] && sed -e 's/#.*//' -e 's/[[:space:]]//g' "$hosts_file" | grep -Fqx -- "$host_short"
}

remove_agent() { # remove_agent <why>
  if [[ -f "$plist" ]]; then
    launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
    rm -f "$plist"
    ok "removed desktop carry agent from $host_short ($1)"
  else
    skip "desktop carry not enabled for $host_short ($1)"
  fi
}

if ! role_includes client || ! tier_allows R; then
  remove_agent "needs a Mac client on the recommended tier"
  return 0 2>/dev/null || exit 0
fi
if ! listed; then
  remove_agent "not in config/desktop-switcher-carry.hosts"
  return 0 2>/dev/null || exit 0
fi

bash -n "$source_script"
mkdir -p "$bin_dir" "$state_dir" "$HOME/Library/LaunchAgents"
if ! cmp -s "$source_script" "$target"; then
  install -m 0755 "$source_script" "$target.tmp"
  mv -f "$target.tmp" "$target"
fi
if ! cmp -s "$source_script" "$target"; then
  warn "installed sync script differs from source"
  return 1 2>/dev/null || exit 1
fi

cat >"$plist.tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$target</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartCalendarInterval</key>
  <array>
    <dict><key>Hour</key><integer>0</integer><key>Minute</key><integer>17</integer></dict>
    <dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>17</integer></dict>
    <dict><key>Hour</key><integer>6</integer><key>Minute</key><integer>17</integer></dict>
    <dict><key>Hour</key><integer>9</integer><key>Minute</key><integer>17</integer></dict>
    <dict><key>Hour</key><integer>12</integer><key>Minute</key><integer>17</integer></dict>
    <dict><key>Hour</key><integer>15</integer><key>Minute</key><integer>17</integer></dict>
    <dict><key>Hour</key><integer>18</integer><key>Minute</key><integer>17</integer></dict>
    <dict><key>Hour</key><integer>21</integer><key>Minute</key><integer>17</integer></dict>
  </array>
  <key>EnvironmentVariables</key>
  <dict><key>HERMES_HOME</key><string>$hermes_home</string></dict>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>StandardOutPath</key><string>$state_dir/agent.out</string>
  <key>StandardErrorPath</key><string>$state_dir/agent.out</string>
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
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      launchctl print "$domain/$label" >/dev/null 2>&1 || break
      sleep 0.5
    done
  fi
fi
if ! launchctl print "$domain/$label" >/dev/null 2>&1; then
  launchctl bootstrap "$domain" "$plist"
  launchctl enable "$domain/$label"
fi
launchctl print "$domain/$label" >/dev/null
ok "desktop carry agent loaded on $host_short (sync at login and every 3 h, catching up after sleep; log $state_dir/sync.log)"
