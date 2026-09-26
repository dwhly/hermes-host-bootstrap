from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import time
from typing import Any

from .security import TrustError
from .core import DOCKER_TOKENS, LINUX_UNIT_MAP, _launchd_target, _resolve_tool, iso_now, unit_for, ConvergerError, Transport, new_ulid


DEFAULT_ALLOWLIST = ["chief-node", "chief-loop-watchdog", "chief-core"]
WINDOW_S = 600
MAX_RESTARTS = 5
EXPECTED_INTERVAL_S = 300


def mutation_allowed() -> bool:
    return True


class SupervisorTransport(Transport):
    def emit_health(self, payload: dict[str, Any]) -> None:
        token = next((t for t, legacy in LINUX_UNIT_MAP.items() if payload["process_id"] == legacy), payload["process_id"])
        status = payload["status"]
        data = {
            "node_id": self.node_id, "process_id": payload["process_id"],
            "manager": "supervisor:" + payload["manager"],
            "artifact": {"chief-node": "hermes-node", "chief-core": "chief", "chief-loop-watchdog": "harness"}.get(token, "unknown"),
            "loaded_ref": "unknown",  # A service-manager observation is not runtime-ref proof.
            "status": "unhealthy" if status in {"dead", "restarting"} else status,
            "steady_for_s": 0, "restart_count": payload["manager_restart_count"],
            "heartbeat_age_s": 0, "crash_loop": status == "crash_looping",
            "last_exit": None, "observed_at": payload["observed_at"],
        }
        self.emit({
            "specversion": "1.0", "id": new_ulid(), "type": "hermes.fleet.process.health",
            "source": f"chief-supervisor://{self.node_id}", "time": payload["observed_at"],
            "contextid": "ctx_fleet", "entityid": f"ent_node_{self.node_id}",
            "actorid": f"act_node_{self.node_id}", "confidence": 1.0,
            "sensitivity": "internal", "sourceref": f"supervisor://{self.node_id}/{token}",
            "schemaversion": 1, "data": data,
        })


def load_allowlist(path: pathlib.Path) -> list[str]:
    try:
        data = json.loads(path.read_text())
        units = data if isinstance(data, list) else data.get("units", [])
        return [str(u) for u in units if u]
    except FileNotFoundError:
        return DEFAULT_ALLOWLIST if os.environ.get("CHIEF_NODE_ID") == "h-do1" else ["chief-node"]


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
    out = subprocess.run([_resolve_tool("launchctl"), "print", label], text=True, capture_output=True, check=False)
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
        subprocess.run([_resolve_tool("launchctl"), "disable", unit], check=False)
        subprocess.run([_resolve_tool("launchctl"), "bootout", unit], check=False)
    elif manager == "docker":
        subprocess.run([_resolve_tool("docker"), "stop", unit], check=False)


def restart(unit: str, manager: str) -> None:
    if manager == "systemd":
        subprocess.run([_resolve_tool("systemctl"), "restart", unit], check=False)
    elif manager == "launchd":
        subprocess.run([_resolve_tool("launchctl"), "kickstart", "-k", unit], check=False)
    elif manager == "docker":
        subprocess.run([_resolve_tool("docker"), "restart", unit], check=False)


def process_status(unit: str) -> dict[str, Any]:
    token = next((t for t, legacy in LINUX_UNIT_MAP.items() if unit == legacy), unit)
    target = unit_for(token)
    if token in DOCKER_TOKENS:
        status = docker_status(target)
    elif sys_platform() == "darwin":
        target = _launchd_target(token, target)
        # No GUI session means defer, never kickstart/disable an absent domain.
        domain = target.rsplit("/", 1)[0]
        gui = subprocess.run([_resolve_tool("launchctl"), "print", domain],
                             text=True, capture_output=True, check=False) if domain.startswith("gui/") else None
        if gui is not None and gui.returncode:
            return {"target": target, "manager": "launchd", "deferred": "gui_unavailable"}
        status = launchd_status(target)
    else:
        status = systemd_status(target)
    return {**status, "target": target}


def supervise_once(args: argparse.Namespace) -> int:
    allowlist = load_allowlist(pathlib.Path(args.allowlist))
    limiter = RestartLimiter(pathlib.Path(args.state_dir) / "supervisor-restarts.json")
    tx = SupervisorTransport(args.core, args.node_id, pathlib.Path(args.auth_token_path))
    targets = []
    for unit in allowlist:
        try:
            status = process_status(unit)
            target = status["target"]
            if not status.get("deferred"):
                targets.append(f"{status['manager']} {target}\n")
            limiter_id = f"{status['manager']}:{target}" if sys_platform() == "darwin" else LINUX_UNIT_MAP.get(unit, unit)
            status_value = "healthy" if status.get("active") else "dead"
            restart_count = limiter.count(limiter_id)
            if status.get("deferred"):
                status_value = "unknown"
            elif not mutation_allowed():
                status["deferred"] = "dark_unknown_or_unqualified_wake"
            elif not status.get("active") and restart_count >= MAX_RESTARTS:
                status_value = "crash_looping"
                enter_crash_looping(target, status["manager"])
            elif not status.get("active"):
                if limiter.allowed(limiter_id):
                    restart(target, status["manager"])
                    limiter.record(limiter_id)
                    status_value = "restarting"
                else:
                    status_value = "crash_looping"
                    enter_crash_looping(target, status["manager"])
        except (ConvergerError, TrustError, OSError, ValueError, subprocess.SubprocessError) as exc:
            status = {"target": unit, "manager": "unknown", "deferred": str(exc)}
            limiter_id = unit
            status_value = "unknown"
        payload = {
            "node_id": args.node_id,
            "process_id": unit,
            "manager": status["manager"],
            "status": status_value,
            "restart_count_10m": limiter.count(limiter_id),
            "manager_restart_count": status.get("restart_count", 0),
            "expected_interval_s": EXPECTED_INTERVAL_S,
            "observed_at": iso_now(),
            "raw": {k: v for k, v in status.items() if k in {"ActiveState", "SubState", "ExecMainStatus", "ExecMainCode", "Status", "deferred"}},
        }
        try:
            tx.emit_health(payload)
        except Exception as exc:
            print(f"chief health emit failed: {unit}: {exc}", flush=True)
    limiter.save()
    if getattr(args, "targets_file", None):
        path = pathlib.Path(args.targets_file)
        temp = path.with_suffix(".new")
        temp.write_text("".join(targets))
        temp.replace(path)
    return 0


def sys_platform() -> str:
    import sys

    return sys.platform


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="chief-node-supervisor")
    parser.add_argument("--node-id", default=os.environ.get("CHIEF_NODE_ID"))
    parser.add_argument("--core", default=os.environ.get("CHIEF_CORE_URL"))
    parser.add_argument("--auth-token-path", default=os.environ.get("CHIEF_NODE_AUTH_TOKEN", "/etc/chief/node-auth.token"))
    parser.add_argument("--allowlist", default="/etc/chief/supervisor-allowlist.json")
    parser.add_argument("--state-dir", default="/var/lib/chief/converger")
    parser.add_argument("--targets-file")
    parser.add_argument("--loop", action="store_true")
    parser.add_argument("--interval", type=int, default=60)
    args = parser.parse_args(argv)
    if not args.node_id or not args.core:
        parser.error("missing_node_config: CHIEF_NODE_ID and CHIEF_CORE_URL required")
    if not args.loop:
        return supervise_once(args)
    while True:
        supervise_once(args)
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
