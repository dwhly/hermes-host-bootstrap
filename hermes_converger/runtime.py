"""Fixed root entry points; all CLI flexibility remains an unprivileged API."""
from __future__ import annotations

import fcntl
import grp
import json
import os
import pathlib
import socket
import stat
import time

from .security import install_config, load_config, trusted_path, TrustError

BASE = pathlib.Path("/usr/local/lib/hermes-host-bootstrap")
STATE = pathlib.Path("/var/lib/chief/currency-step0")
HINTS = pathlib.Path("/var/lib/chief/requests")


def configure():
    install_config(socket.gethostname(), BASE / "hermes_converger/step0/host-contracts.json",
                   pathlib.Path("/etc/chief/node.env"), grp.getgrnam("chief").gr_gid)
    user = load_config()["CHIEF_RUNTIME_USER"]
    allow = pathlib.Path("/etc/chief/supervisor-allowlist.json")
    if not allow.exists():
        node = load_config()["CHIEF_NODE_ID"]
        units = ["chief-node", "chief-loop-watchdog", "chief-core"] if node == "h-do1" else ["chief-node"]
        allow.write_text(json.dumps({"units": units}) + "\n")
        os.chown(allow, 0, grp.getgrnam("chief").gr_gid)
        allow.chmod(0o640)
    trusted_path(allow)
    # Add only the trusted registry runtime user, never SUDO_USER/caller input.
    import subprocess
    if os.uname().sysname == "Darwin":
        subprocess.run(["/usr/sbin/dseditgroup", "-o", "edit", "-a", user, "-t", "user", "chief"], check=True)
    elif user != "root":
        subprocess.run(["/usr/sbin/usermod", "-a", "-G", "chief", user], check=True)


def consume_hints(directory: pathlib.Path = HINTS) -> list[str]:
    trusted_path(directory)
    hints = []
    for name in ("login", "wake", "network", "request"):
        fd = os.open(directory / name, os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != 0:
                raise TrustError("unsafe_hint_slot")
            value = os.read(fd, 257)
            if value and len(value) <= 256 and value.strip() == name.encode():
                hints.append(name)
            elif value:
                print(json.dumps({"reason": "invalid_or_oversize_hint", "slot": name}), flush=True)
            os.ftruncate(fd, 0)
        finally:
            os.close(fd)
    return hints


def full_wake() -> bool:
    if os.uname().sysname != "Darwin":
        return True
    marker = pathlib.Path("/etc/chief/wake-qualified")
    if not marker.exists():
        return False
    trusted_path(marker)
    import re
    import subprocess
    result = subprocess.run(["/usr/sbin/ioreg", "-r", "-n", "IODisplayWrangler", "-d", "1"],
                            capture_output=True, text=True, timeout=5, check=False)
    return result.returncode == 0 and bool(re.search(r'"CurrentPowerState"\s*=\s*4', result.stdout))


def run(mode: str) -> int:
    config = load_config()
    os.environ.update(config)
    trusted_path(STATE)
    trusted_path(pathlib.Path("/var/lib/chief/converger"), tree=True)
    for secret in ("node-plan.key", "node-auth.token"):
        path = pathlib.Path("/etc/chief") / secret
        if path.exists():
            trusted_path(path)
    # One lock covers all privileged convergence and supervisor service control.
    fd = os.open(STATE / "run.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('{"deferred":"step0_already_running","pending":"retained"}')
            return 0
        if mode == "supervisor":
            if not full_wake():
                print('{"deferred":"dark_or_unknown_wake","component":"supervisor"}')
                return 0
            from . import supervisor
            allow = pathlib.Path("/etc/chief/supervisor-allowlist.json")
            trusted_path(allow)
            return supervisor.main([])
        if mode != "converge":
            raise TrustError("unknown_root_entry")
        hints = consume_hints()
        print(json.dumps({"reason": "step0_check", "hints": hints, "started_at": int(time.time())}), flush=True)
        for name, value in {"last-check": str(int(time.time())),
                            "wake": os.environ.get("CHIEF_PULSE_WAKE", "unknown"),
                            "boot": os.environ.get("CHIEF_PULSE_BOOT", "unknown"),
                            "full": os.environ.get("CHIEF_PULSE_FULL", "no")}.items():
            path = STATE / name
            temp = STATE / (name + ".new")
            with temp.open("w") as stream:
                stream.write(value + "\n")
            temp.replace(path)
        from . import core
        args = core.build_parser().parse_args(["reconcile", "--trigger", os.environ.get("CHIEF_PULSE_TRIGGER", "periodic")])
        args.report_only = not full_wake()
        # Admission is rechecked immediately before every root mutation too.
        core.mutation_allowed = full_wake
        return core.reconcile(args)
    finally:
        os.close(fd)
