#!/usr/bin/env python3
"""Converge FluidVoice onto every registered macOS fleet host.

Runs from the fleet boss. Unreachable sleeping Macs stay pending and are retried
on the next invocation. Stdout changes only when fleet state changes, making the
script suitable for a quiet recurring Hermes cron job.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile

import yaml

HERMES_HOME = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes"))
HOSTS_DIR = HERMES_HOME / "hosts"
STATE_PATH = HERMES_HOME / "runtime" / "fluidvoice-rollout-state.json"

REMOTE_SCRIPT = r'''set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH
if test -d "$HOME/code/hermes-host-bootstrap/.git"; then
  BD="$HOME/code/hermes-host-bootstrap"
elif test -d "$HOME/projects/hermes-host-bootstrap/.git"; then
  BD="$HOME/projects/hermes-host-bootstrap"
else
  printf 'FLUIDVOICE_ERROR bootstrap-repo-missing\n'
  exit 2
fi
cd "$BD"
git pull --ff-only origin main >/dev/null
nohup caffeinate -dimsu -t 1200 >/dev/null 2>&1 &
bash bootstrap.sh --tier=recommended --role=client --only=43-fluidvoice >/tmp/fluidvoice-install.log 2>&1
bash bootstrap.sh --tier=recommended --role=client --only=99-register-host >/tmp/fluidvoice-register.log 2>&1
version="$(defaults read /Applications/FluidVoice.app/Contents/Info CFBundleShortVersionString)"
bundle_id="$(defaults read /Applications/FluidVoice.app/Contents/Info CFBundleIdentifier)"
login_path="$(osascript -e 'tell application "System Events" to if exists login item "FluidVoice" then get path of login item "FluidVoice"')"
show_window="$(defaults read "$bundle_id" ShowMainWindowAtLoginLaunch)"
registry_version="$(awk -F': ' '/^  fluidvoice:/ {gsub(/"/, "", $2); print $2; exit}' "$HOME/.hermes/hosts/$(scutil --get LocalHostName).yaml")"
test "$login_path" = /Applications/FluidVoice.app
test "$show_window" = 0
test "$registry_version" = "$version"
printf 'FLUIDVOICE_OK %s\n' "$version"
'''


def load_hosts() -> list[dict[str, str]]:
    hosts: list[dict[str, str]] = []
    for path in sorted(HOSTS_DIR.glob("*.yaml")):
        if path.name.endswith(".live.yaml"):
            continue
        try:
            data = yaml.safe_load(path.read_text()) or {}
        except Exception:
            continue
        os_data = data.get("os") or {}
        if os_data.get("kind") != "macos":
            continue
        name = str(data.get("hostname") or path.stem)
        user = str(data.get("ssh_user") or data.get("default_user") or "")
        address = str(data.get("tailscale_ip") or data.get("ssh_host") or "")
        if user and address:
            hosts.append({"name": name, "target": f"{user}@{address}"})
    return hosts


def converge(host: dict[str, str]) -> dict[str, str]:
    cmd = [
        "ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
        host["target"], "/bin/bash", "--noprofile", "--norc", "-s",
    ]
    try:
        result = subprocess.run(
            cmd,
            input=REMOTE_SCRIPT,
            text=True,
            capture_output=True,
            timeout=420,
        )
    except (subprocess.TimeoutExpired, OSError):
        return {"status": "pending", "detail": "sleeping-or-unreachable"}
    if result.returncode == 255:
        return {"status": "pending", "detail": "sleeping-or-unreachable"}
    for line in result.stdout.splitlines():
        if line.startswith("FLUIDVOICE_OK "):
            return {"status": "installed", "detail": line.split(maxsplit=1)[1]}
        if line.startswith("FLUIDVOICE_ERROR "):
            return {"status": "error", "detail": line.split(maxsplit=1)[1]}
    detail = (result.stderr or result.stdout).strip().splitlines()
    return {"status": "error", "detail": (detail[-1] if detail else f"exit-{result.returncode}")[:160]}


def write_state(state: dict[str, object]) -> None:
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=STATE_PATH.parent, delete=False) as handle:
        json.dump(state, handle, sort_keys=True, indent=2)
        handle.write("\n")
        tmp = Path(handle.name)
    tmp.replace(STATE_PATH)


def main() -> int:
    previous: dict[str, object] = {}
    if STATE_PATH.exists():
        try:
            previous = json.loads(STATE_PATH.read_text())
        except Exception:
            previous = {}

    hosts = load_hosts()
    current = {host["name"]: converge(host) for host in hosts}
    state: dict[str, object] = {"hosts": current}
    write_state(state)

    if state != previous:
        installed = [f"{h} {v['detail']}" for h, v in current.items() if v["status"] == "installed"]
        pending = [h for h, v in current.items() if v["status"] == "pending"]
        errors = [f"{h}: {v['detail']}" for h, v in current.items() if v["status"] == "error"]
        parts = []
        if installed:
            parts.append("installed=" + ", ".join(installed))
        if pending:
            parts.append("pending=" + ", ".join(pending))
        if errors:
            parts.append("errors=" + "; ".join(errors))
        print("FluidVoice fleet rollout: " + " | ".join(parts))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
