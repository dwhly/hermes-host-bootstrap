#!/usr/bin/env bash
# M7-desktop-switcher-carry: carry the Desktop gateway switcher (upstream PR #125267)
# on fleet Mac clients until upstream merges it.
#
# Installs (user-level, no sudo):
#   ~/.local/bin/hermes-desktop-carry-sync      (copied from scripts/, digest-checked)
#   ~/Library/LaunchAgents/com.hermes.desktop-carry.plist
#       runs the sync at load/login and every 3 h; launchd runs a missed interval on wake.
# The sync is GIT ONLY (see the script header): it parks ~/.hermes/hermes-agent on
# carry/desktop-switcher, merges the fork's fleet/desktop-switcher when needed and sets
# updates.parked_branch_strategy=update_in_place. The next normal update rebuilds Desktop.
#
# Scope (all must hold): macOS, role client, tier recommended+, not --skip'd, and the
# host is listed in config/desktop-switcher-carry.hosts (reviewed desired state; one host
# per line, activated host by host). A host removed from the list gets the agent removed;
# its checkout is left as is (rollback is manual and documented in the wiki).

set -euo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$MODULE_DIR/.." && pwd)}"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/common.sh"

step "Desktop switcher carry"

if [[ "$OS" != "macos" ]] || ! role_includes client || ! tier_allows R || is_skipped desktop-switcher-carry; then
  skip "desktop-switcher-carry needs a macOS client on the recommended tier"
  return 0 2>/dev/null || exit 0
fi

label="com.hermes.desktop-carry"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
bin_dir="$HOME/.local/bin"
target="$bin_dir/hermes-desktop-carry-sync"
source_script="$REPO_ROOT/scripts/hermes-desktop-carry-sync"
hosts_file="$REPO_ROOT/config/desktop-switcher-carry.hosts"
state_dir="${HERMES_HOME:-$HOME/.hermes}/desktop-carry"
host_short="${HERMES_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"
host_short="${host_short%.local}"

listed() {
  [[ -f "$hosts_file" ]] && sed -e 's/#.*//' -e 's/[[:space:]]//g' "$hosts_file" | grep -Fqx -- "$host_short"
}

if ! listed; then
  if [[ -f "$plist" ]]; then
    launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
    rm -f "$plist"
    ok "removed desktop carry agent from $host_short (not in config/desktop-switcher-carry.hosts)"
  else
    skip "desktop carry not enabled for $host_short (config/desktop-switcher-carry.hosts)"
  fi
  return 0 2>/dev/null || exit 0
fi

bash -n "$source_script"
mkdir -p "$bin_dir" "$state_dir" "$HOME/Library/LaunchAgents"
if ! cmp -s "$source_script" "$target"; then
  install -m 0755 "$source_script" "$target.tmp"
  mv -f "$target.tmp" "$target"
fi
cmp -s "$source_script" "$target" || { warn "installed sync script differs from source"; exit 1; }

cat >"$plist.tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$target</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>10800</integer>
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
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
fi
if ! launchctl print "$domain/$label" >/dev/null 2>&1; then
  launchctl bootstrap "$domain" "$plist"
  launchctl enable "$domain/$label"
fi
launchctl print "$domain/$label" >/dev/null
ok "desktop carry agent loaded on $host_short (sync at login and every 3 h; log $state_dir/sync.log)"
