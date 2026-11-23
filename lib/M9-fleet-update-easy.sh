#!/usr/bin/env bash
# Interim tier 1 updater approved by Dan 2026-11-21. Retire at lock cutover.
# M9 owns both the helper symlink and its schedule; no module 99 rerun needed.
set -euo pipefail
MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$MODULE_DIR/.." && pwd)}"
original_path="$PATH"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/common.sh"
# common.sh adds Homebrew first; preserve caller shims for this module.
export PATH="$original_path:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

step "Fleet easy repo updater"
if ! tier_allows E; then
  skip "fleet-update-easy: unsupported tier"
  exit 0
fi
if is_skipped fleet-update-easy; then
  skip "fleet-update-easy: opted out via --skip (left as is)"
  exit 0
fi
if [[ "$OS" == macos ]]; then
  # All Mac roles use the user LaunchAgent.
  if ! role_includes client && ! role_includes server; then
    skip "fleet-update-easy: unsupported role"
    exit 0
  fi
else
  if ! role_includes server; then
    skip "fleet-update-easy: Linux requires role server"
    exit 0
  fi
  if [[ "$(uname -s)" != Linux ]] || ! have systemctl; then
    skip "fleet-update-easy: Linux systemd required"
    exit 0
  fi
  host_short="${HERMES_HOSTNAME:-$(hostname -s)}"
  if [[ "${host_short%.local}" != h-do1 ]]; then
    skip "fleet-update-easy: Linux schedule is scoped to h-do1"
    exit 0
  fi
fi

script="$REPO_ROOT/scripts/fleet-update-easy"
bash -n "$script"
mkdir -p "$HOME/.local/bin" "$HOME/.local/state/fleet-update-easy"
target="$HOME/.local/bin/fleet-update-easy"
if [[ ! -L "$target" || "$(readlink "$target")" != "$script" ]]; then
  rm -f "$target"
  ln -s "$script" "$target"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if [[ "$OS" == macos ]]; then
  label=com.hermes.fleet-update-easy
  domain="gui/$(id -u)"
  mkdir -p "$HOME/Library/LaunchAgents"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  python3 - "$tmp/agent.plist" "$script" "$HOME" "$label" <<'PY'
import plistlib
import sys
path, script, home, label = sys.argv[1:]
with open(path, "wb") as stream:
    plistlib.dump({"Label": label, "ProgramArguments": ["/bin/bash", script],
                   "RunAtLoad": True,
                   "StartCalendarInterval": [{"Hour": h, "Minute": 17} for h in range(0, 24, 2)],
                   "EnvironmentVariables": {"HOME": home},
                   "StandardOutPath": home + "/.local/state/fleet-update-easy/launchd.stdout.log",
                   "StandardErrorPath": home + "/.local/state/fleet-update-easy/launchd.stderr.log",
                   "ProcessType": "Background", "LowPriorityIO": True}, stream)
PY
  plutil -lint "$tmp/agent.plist" >/dev/null
  # Hold the same open-file-description lock as the updater throughout reload.
  # An unchanged, loaded agent needs no reload and must not wait on a busy run.
  if ! cmp -s "$tmp/agent.plist" "$plist" || ! launchctl print "$domain/$label" >/dev/null 2>&1; then
    mkdir -p "$HOME/.local/state/fleet-update-easy"
    exec 8>>"$HOME/.local/state/fleet-update-easy/lock"
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
  # Release the updater lock before (re)loading, so the RunAtLoad run is not "busy" and no child inherits fd 8.
  exec 8>&-
  if ! launchctl print "$domain/$label" >/dev/null 2>&1; then
    launchctl enable "$domain/$label"
    launchctl bootstrap "$domain" "$plist"
  fi
  launchctl print "$domain/$label" >/dev/null
  ok "$label loaded (every 2 h at :17, plus login and wake catch-up)"
else
  SUDO="${SUDO-sudo}"
  [[ "$(id -u)" == 0 ]] && SUDO=""
  systemd_dir="${HERMES_SYSTEMD_DIR:-/etc/systemd/system}"
  unit=hermes-fleet-update-easy
  # Escape systemd specifiers and quoted ExecStart paths.
  python3 - "$tmp/$unit.service" "$script" <<'PY'
import sys
script = sys.argv[2].replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%").replace("$", "$$")
with open(sys.argv[1], "w") as stream:
    stream.write('[Unit]\nDescription=Fast-forward fleet easy repos\n'
                 'Wants=network-online.target\nAfter=network-online.target\n\n'
                 '[Service]\nType=oneshot\nUser=root\nEnvironment=HOME=/root\n'
                 'ExecStart=/bin/bash "' + script + '"\nTimeoutStartSec=15min\nNice=10\n')
PY
  cat >"$tmp/$unit.timer" <<'UNIT'
[Unit]
Description=Fast-forward fleet easy repos every two hours

[Timer]
OnCalendar=*-*-* 00/2:17:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  $SUDO install -d -m 0755 "$systemd_dir"
  changed=0
  for kind in service timer; do
    if ! cmp -s "$tmp/$unit.$kind" "$systemd_dir/$unit.$kind"; then
      $SUDO install -m 0644 "$tmp/$unit.$kind" "$systemd_dir/$unit.$kind"
      changed=1
    fi
  done
  if [[ "$changed" == 1 ]]; then
    $SUDO systemctl daemon-reload
  fi
  $SUDO systemctl enable --now "$unit.timer"
  if [[ "$changed" == 1 ]]; then
    $SUDO systemctl restart "$unit.timer"
  fi
  ok "$unit.timer enabled (every 2 h at :17, persistent)"
fi
