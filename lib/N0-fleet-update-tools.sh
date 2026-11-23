#!/usr/bin/env bash
# Interim tier 2 updater approved by Dan 2026-11-23. Retire at lock cutover.
# N0 owns both the helper symlink and its schedule; no module 99 rerun needed.
set -euo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$MODULE_DIR/.." && pwd)}"
original_path="$PATH"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/common.sh"
# common.sh adds Homebrew first; preserve caller shims for this module.
export PATH="$original_path:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

python=python3
if [[ "$OS" == macos ]]; then
  if [[ -x /opt/homebrew/bin/python3 ]]; then python=/opt/homebrew/bin/python3
  elif [[ -x /usr/local/bin/python3 ]]; then python=/usr/local/bin/python3
  elif [[ "$(command -v python3)" == /usr/bin/python3 ]] && ! xcode-select -p >/dev/null 2>&1; then
    warn "fleet-update-tools requires Python 3; install Homebrew Python"
    exit 0
  fi
fi

step "Fleet coding CLI updater"
if ! tier_allows E; then
  skip "fleet-update-tools: unsupported tier"
  exit 0
fi
if is_skipped fleet-update-tools; then
  skip "fleet-update-tools: opted out via --skip (left as is)"
  exit 0
fi
if [[ "$OS" == macos ]]; then
  # All Mac roles use the user LaunchAgent.
  if ! role_includes client && ! role_includes server; then
    skip "fleet-update-tools: unsupported role"
    exit 0
  fi
else
  if ! role_includes server; then
    skip "fleet-update-tools: Linux requires role server"
    exit 0
  fi
  if [[ "$(uname -s)" != Linux ]] || ! have systemctl; then
    skip "fleet-update-tools: Linux systemd required"
    exit 0
  fi
fi

script="$REPO_ROOT/scripts/fleet-update-tools"
bash -n "$script"
# Linux: root may install the job for the user who owns the CLIs (h-btp: hermes, which has no sudo).
tools_user="$(id -un)"
tools_home="$HOME"
if [[ "$OS" != macos && -n "${FLEET_TOOLS_USER:-}" && "$FLEET_TOOLS_USER" != "$tools_user" ]]; then
  if [[ "$(id -u)" != 0 ]]; then
    warn "fleet-update-tools: FLEET_TOOLS_USER requires root; skipping"
    exit 0
  fi
  tools_home="$(getent passwd "$FLEET_TOOLS_USER" | cut -d: -f6)"
  if [[ -z "$tools_home" || ! -d "$tools_home" ]]; then
    warn "fleet-update-tools: user $FLEET_TOOLS_USER has no home; skipping"
    exit 0
  fi
  tools_user="$FLEET_TOOLS_USER"
fi
for dir in "$tools_home/.local" "$tools_home/.local/bin" "$tools_home/.local/state" "$tools_home/.local/state/fleet-update-tools"; do
  [[ -d "$dir" ]] || install -d -m 0755 "$dir"
  [[ "$tools_user" == "$(id -un)" ]] || chown "$tools_user:" "$dir"
done
target="$tools_home/.local/bin/fleet-update-tools"
if [[ ! -L "$target" || "$(readlink "$target")" != "$script" ]]; then
  rm -f "$target"
  ln -s "$script" "$target"
  [[ "$tools_user" == "$(id -un)" ]] || chown -h "$tools_user:" "$target"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if [[ "$OS" == macos ]]; then
  label=com.hermes.fleet-update-tools
  domain="gui/$(id -u)"
  mkdir -p "$HOME/Library/LaunchAgents"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  "$python" - "$tmp/agent.plist" "$script" "$HOME" "$label" <<'PY'
import plistlib
import sys
path, script, home, label = sys.argv[1:]
with open(path, "wb") as stream:
    plistlib.dump({"Label": label, "ProgramArguments": ["/bin/bash", script],
                   "StartCalendarInterval": {"Hour": 3, "Minute": 41},
                   "EnvironmentVariables": {"HOME": home},
                   "StandardOutPath": home + "/.local/state/fleet-update-tools/launchd.stdout.log",
                   "StandardErrorPath": home + "/.local/state/fleet-update-tools/launchd.stderr.log",
                   "ProcessType": "Background", "LowPriorityIO": True, "ExitTimeOut": 1200}, stream)
PY
  plutil -lint "$tmp/agent.plist" >/dev/null
  if ! launchctl print "$domain" >/dev/null 2>&1; then
    install -m 0644 "$tmp/agent.plist" "$plist"
    warn "$domain unavailable; LaunchAgent saved and will load at the next GUI login"
    exit 0
  fi
  # Hold the same open-file-description lock as the updater throughout reload.
  # An unchanged, loaded agent needs no reload and must not wait on a busy run.
  if ! cmp -s "$tmp/agent.plist" "$plist" || ! launchctl print "$domain/$label" >/dev/null 2>&1; then
    mkdir -p "$HOME/.local/state/fleet-update-tools"
    exec 8>>"$HOME/.local/state/fleet-update-tools/lock"
    if ! perl -MFcntl=:flock -e 'open(my $f, ">>&=", 8) or exit 2; $SIG{ALRM} = sub { exit 1 }; alarm 300; flock($f, LOCK_EX) or exit 2; alarm 0;'; then
      warn "$label updater lock unavailable after waiting up to 300 s; skipping reload"
      exit 0
    fi
  fi
  if ! cmp -s "$tmp/agent.plist" "$plist"; then
    if launchctl print "$domain/$label" >/dev/null 2>&1; then
      launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        launchctl print "$domain/$label" >/dev/null 2>&1 || break
        sleep 0.5
      done
      if launchctl print "$domain/$label" >/dev/null 2>&1; then
        err "$label still loaded after bootout; refusing bootstrap"
        exit 1
      fi
    fi
    install -m 0644 "$tmp/agent.plist" "$plist"
  fi
  # Close the lock descriptor before loading; launchd must not inherit it.
  exec 8>&-
  if ! launchctl print "$domain/$label" >/dev/null 2>&1; then
    launchctl enable "$domain/$label"
    launchctl bootstrap "$domain" "$plist"
  fi
  launchctl print "$domain/$label" >/dev/null
  ok "$label loaded (daily at 03:41, with wake catch-up)"
else
  SUDO="${SUDO-sudo}"
  [[ "$(id -u)" == 0 ]] && SUDO=""
  systemd_dir="${HERMES_SYSTEMD_DIR:-/etc/systemd/system}"
  unit=hermes-fleet-update-tools
  # Escape systemd specifiers and quoted ExecStart paths.
  "$python" - "$tmp/$unit.service" "$script" "$tools_home" "$tools_user" <<'PY'
import sys

def quote(value):
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%").replace("\n", "\\n")

script, home, user = map(quote, sys.argv[2:])
script = script.replace("$", "$$")
with open(sys.argv[1], "w") as stream:
    stream.write('[Unit]\nDescription=Update installed fleet coding CLIs\n'
                 'Wants=network-online.target\nAfter=network-online.target\n\n'
                 '[Service]\nType=oneshot\nUser=' + user + '\nEnvironment="HOME=' + home + '"\n'
                 'ExecStart=/bin/bash "' + script + '"\nTimeoutStartSec=2h\nTimeoutStopSec=20min\nKillMode=mixed\nNice=10\n')
PY
  cat >"$tmp/$unit.timer" <<'UNIT'
[Unit]
Description=Update installed fleet coding CLIs daily

[Timer]
OnCalendar=*-*-* 03:41:00 America/Los_Angeles
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  changed=0
  for kind in service timer; do
    if ! cmp -s "$tmp/$unit.$kind" "$systemd_dir/$unit.$kind"; then
      changed=1
    fi
  done
  if [[ "$changed" == 1 ]]; then
    exec 8>>"$tools_home/.local/state/fleet-update-tools/lock"
    if ! perl -MFcntl=:flock -e 'open(my $f, ">>&=", 8) or exit 2; $SIG{ALRM} = sub { exit 1 }; alarm 300; flock($f, LOCK_EX) or exit 2; alarm 0;'; then
      warn "$unit updater lock unavailable after waiting up to 300 s; skipping reload"
      exit 0
    fi
    $SUDO install -d -m 0755 "$systemd_dir"
    for kind in service timer; do
      $SUDO install -m 0644 "$tmp/$unit.$kind" "$systemd_dir/$unit.$kind"
    done
    $SUDO systemctl daemon-reload
    exec 8>&-
  fi
  # Start the timer, never the service.
  $SUDO systemctl enable "$unit.timer"
  $SUDO systemctl start "$unit.timer"
  ok "$unit.timer enabled and started (daily at 03:41, persistent)"
fi
