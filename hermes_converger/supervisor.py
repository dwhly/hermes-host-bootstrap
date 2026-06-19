from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import time
import urllib.request
from typing import Any

from .core import _resolve_tool, iso_now


DEFAULT_ALLOWLIST = ["chief-node.service", "chief-loop-watchdog.service", "chief-stack-core-1"]
WINDOW_S = 600
MAX_RESTARTS = 5
EXPECTED_INTERVAL_S = 15


class SupervisorTransport:
    def __init__(self, core: str, node_id: str, token_path: pathlib.Path):
        self.core = core.rstrip("/")
        self.node_id = node_id
        self.token_path = token_path

    def emit_health(self, payload: dict[str, Any]) -> None:
        headers = {"Content-Type": "application/json", "X-Chief-Node-ID": self.node_id}
        try:
            token = self.token_path.read_text().strip()
        except FileNotFoundError:
            token = ""
        if token:
            headers["Authorization"] = f"Bearer {token}"
        body = json.dumps({"type": "hermes.fleet.process.health", **payload}).encode("utf-8")
        req = urllib.request.Request(f"{self.core}/v1/fleet/events", data=body, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()


def load_allowlist(path: pathlib.Path) -> list[str]:
    try:
        data = json.loads(path.read_text())
        units = data.get("units", data if isinstance(data, list) else [])
        return [str(u) for u in units if u]
    except FileNotFoundError:
        return DEFAULT_ALLOWLIST


def systemd_status(unit: str) -> dict[str, Any]:
    props = [
        "ActiveState",
        "SubState",
        "NRestarts",
        "ExecMainStatus",
        "ExecMainCode",
        "InactiveEnterTimestampMonotonic",
        "ActiveEnterTimestampMonotonic",
    ]
    cmd = [_resolve_tool("systemctl"), "show", unit]
    for prop in props:
        cmd.extend(["--property", prop])
    out = subprocess.run(cmd, text=True, capture_output=True, check=False)
    data: dict[str, Any] = {"unit": unit, "manager": "systemd", "exists": out.returncode == 0}
    for line in out.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            data[k] = v
    data["restart_count"] = int(data.get("NRestarts") or 0)
    data["active"] = data.get("ActiveState") == "active"
    return data


def launchd_status(label: str) -> dict[str, Any]:
    out = subprocess.run([_resolve_tool("launchctl"), "print", f"system/{label}"], text=True, capture_output=True, check=False)
    return {"unit": label, "manager": "launchd", "exists": out.returncode == 0, "active": "state = running" in out.stdout, "restart_count": 0}


def docker_status(container: str) -> dict[str, Any]:
    out = subprocess.run([_resolve_tool("docker"), "inspect", container], text=True, capture_output=True, check=False)
    data: dict[str, Any] = {"unit": container, "manager": "docker", "exists": out.returncode == 0, "active": False, "restart_count": 0}
    if out.returncode != 0:
        return data
    try:
        inspected = json.loads(out.stdout)[0]
    except (IndexError, json.JSONDecodeError):
        return data
    state = inspected.get("State") or {}
    data["active"] = bool(state.get("Running"))
    data["restart_count"] = int(inspected.get("RestartCount") or 0)
    data["Status"] = state.get("Status")
    return data


class RestartLimiter:
    def __init__(self, path: pathlib.Path):
        self.path = path
        self.state = self._load()

    def _load(self) -> dict[str, list[float]]:
        try:
            return json.loads(self.path.read_text())
        except FileNotFoundError:
            return {}

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.state, sort_keys=True, indent=2) + "\n")
        os.chmod(tmp, 0o640)
        os.replace(tmp, self.path)

    def count(self, unit: str, now: float | None = None) -> int:
        now = now or time.time()
        recent = [t for t in self.state.get(unit, []) if now - t < WINDOW_S]
        self.state[unit] = recent
        return len(recent)

    def record(self, unit: str) -> None:
        self.count(unit)
        self.state.setdefault(unit, []).append(time.time())
        self.save()

    def allowed(self, unit: str) -> bool:
        return self.count(unit) < MAX_RESTARTS


def enter_crash_looping(unit: str, manager: str) -> None:
    if manager == "systemd":
        subprocess.run([_resolve_tool("systemctl"), "mask", "--runtime", unit], check=False)
    elif manager == "launchd":
        subprocess.run([_resolve_tool("launchctl"), "disable", f"system/{unit}"], check=False)
        subprocess.run([_resolve_tool("launchctl"), "bootout", f"system/{unit}"], check=False)
    elif manager == "docker":
        subprocess.run([_resolve_tool("docker"), "stop", unit], check=False)


def restart(unit: str, manager: str) -> None:
    if manager == "systemd":
        subprocess.run([_resolve_tool("systemctl"), "restart", unit], check=False)
    elif manager == "launchd":
        subprocess.run([_resolve_tool("launchctl"), "kickstart", "-k", f"system/{unit}"], check=False)
    elif manager == "docker":
        subprocess.run([_resolve_tool("docker"), "restart", unit], check=False)


def process_status(unit: str) -> dict[str, Any]:
    if sys_platform() == "darwin":
        return launchd_status(unit)
    if unit.endswith(".service"):
        return systemd_status(unit)
    return docker_status(unit)


def supervise_once(args: argparse.Namespace) -> int:
    allowlist = load_allowlist(pathlib.Path(args.allowlist))
    limiter = RestartLimiter(pathlib.Path(args.state_dir) / "supervisor-restarts.json")
    tx = SupervisorTransport(args.core, args.node_id, pathlib.Path(args.auth_token_path))
    for unit in allowlist:
        status = process_status(unit)
        status_value = "healthy" if status.get("active") else "dead"
        restart_count = limiter.count(unit)
        if restart_count >= MAX_RESTARTS:
            status_value = "crash_looping"
            enter_crash_looping(unit, status["manager"])
        elif not status.get("active"):
            if limiter.allowed(unit):
                restart(unit, status["manager"])
                limiter.record(unit)
                status_value = "restarting"
            else:
                status_value = "crash_looping"
                enter_crash_looping(unit, status["manager"])
        payload = {
            "node_id": args.node_id,
            "process_id": unit,
            "manager": status["manager"],
            "status": status_value,
            "restart_count_10m": limiter.count(unit),
            "manager_restart_count": status.get("restart_count", 0),
            "expected_interval_s": EXPECTED_INTERVAL_S,
            "observed_at": iso_now(),
            "raw": {k: v for k, v in status.items() if k in {"ActiveState", "SubState", "ExecMainStatus", "ExecMainCode", "Status"}},
        }
        try:
            tx.emit_health(payload)
        except Exception:
            pass
    limiter.save()
    return 0


def sys_platform() -> str:
    import sys

    return sys.platform


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="chief-node-supervisor")
    parser.add_argument("--node-id", default=os.environ.get("CHIEF_NODE_ID") or os.uname().nodename.split(".")[0])
    parser.add_argument("--core", default=os.environ.get("CHIEF_CORE_URL", "http://127.0.0.1:8088"))
    parser.add_argument("--auth-token-path", default=os.environ.get("CHIEF_NODE_AUTH_TOKEN", "/etc/chief/node-auth.token"))
    parser.add_argument("--allowlist", default="/etc/chief/supervisor-allowlist.json")
    parser.add_argument("--state-dir", default="/var/lib/chief/converger")
    parser.add_argument("--loop", action="store_true")
    parser.add_argument("--interval", type=int, default=15)
    args = parser.parse_args(argv)
    if not args.loop:
        return supervise_once(args)
    while True:
        supervise_once(args)
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
