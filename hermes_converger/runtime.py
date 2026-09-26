"""Fixed root entry points; all CLI flexibility remains an unprivileged API."""
from __future__ import annotations

import fcntl
import grp
import json
import os
import pathlib
import signal
import subprocess
import re
import stat
import time

from .security import load_config, trusted_path, TrustError

STATE = pathlib.Path("/var/lib/chief/currency-step0")
HINTS = pathlib.Path("/var/lib/chief/requests")


def configure():
    config = load_config()
    user = config["CHIEF_RUNTIME_USER"]
    allow = pathlib.Path("/etc/chief/supervisor-allowlist.json")
    node = config["CHIEF_NODE_ID"]
    if node in {"h-af", "h-btp"}:
        # Validate only; their owner allowlist and group memberships are retained.
        if allow.exists():
            trusted_path(allow)
        return
    legacy = ["chief-node.service", "chief-loop-watchdog.service", "chief-stack-core-1"]
    repair = False
    if allow.exists():
        trusted_path(allow)
        data = json.loads(allow.read_text())
        repair = os.uname().sysname == "Darwin" and (data == legacy or data == {"units": legacy})
    if not allow.exists() or repair:
        node = config["CHIEF_NODE_ID"]
        units = ["chief-node", "chief-loop-watchdog", "chief-core"] if node == "h-do1" else ["chief-node"]
        temp = allow.with_suffix(".step0-new")
        temp.write_text(json.dumps({"units": units}) + "\n")
        os.chown(temp, 0, grp.getgrnam("chief").gr_gid)
        temp.chmod(0o640)
        temp.replace(allow)
        print(json.dumps({"repair": "supervisor_allowlist", "units": units}), flush=True)
    trusted_path(allow)
    # Add only the trusted registry runtime user, never SUDO_USER/caller input.
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


def wake_identity() -> str:
    if os.uname().sysname != "Darwin":
        return "linux"
    result = subprocess.run(["/usr/sbin/sysctl", "-n", "kern.waketime"], capture_output=True,
                            text=True, timeout=5, check=False)
    return result.stdout.strip() if result.returncode == 0 else "unknown"


def full_wake(qualified: bool = False) -> bool:
    if os.uname().sysname != "Darwin":
        return True
    if not qualified:
        return False
    # IOPMrootDomain graphics capability is independent of display power and
    # permits headless classification. Unknown output fails closed. Q6 must qualify
    # this candidate on each hardware class before signing wake_qualified.
    result = subprocess.run(["/usr/sbin/ioreg", "-r", "-n", "IOPMrootDomain", "-d", "1"],
                            capture_output=True, text=True, timeout=5, check=False)
    match = re.search(r'"SystemPowerStateCapabilities"\s*=\s*(\d+)', result.stdout)
    return result.returncode == 0 and match is not None and int(match[1]) & 3 == 3


def qualified_plan(plan) -> bool:
    # Field is within the plan digest, verified before this is called.
    return plan.get("wake_qualified") is True


def supervisor_admission(config) -> bool:
    if os.uname().sysname != "Darwin":
        return True
    from . import core
    try:
        state = core.LocalState(pathlib.Path("/"))
        plan = core.load_cached_plan(state)
        core.verify_plan(plan, node_id=config["CHIEF_NODE_ID"],
                         key_lookup=core.default_key_lookup(config["CHIEF_NODE_ID"], pathlib.Path(config["CHIEF_NODE_PLAN_KEY"])),
                         watermarks=state.load_watermarks())
        return full_wake(qualified_plan(plan))
    except (core.ConvergerError, OSError, ValueError, KeyError):
        return False


def run(mode: str) -> int:
    # SIGALRM is independent of blocked file/network reads. BaseException avoids
    # legacy broad Exception handlers swallowing the overall deadline.
    def deadline(signum, frame):
        raise SystemExit("step0_runtime_deadline")
    previous = signal.signal(signal.SIGALRM, deadline)
    signal.alarm(1800 if mode == "converge" else 50)
    try:
        return _run(mode)
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)


def _run(mode: str) -> int:
    initial_wake = wake_identity()
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
            from . import supervisor
            allow = pathlib.Path("/etc/chief/supervisor-allowlist.json")
            if allow.exists():
                trusted_path(allow)
            supervisor.mutation_allowed = lambda: initial_wake != "unknown" and wake_identity() == initial_wake and supervisor_admission(config)
            result = supervisor.main(["--targets-file", str(STATE / "supervisor-targets")])
            temp = STATE / "last-health.new"
            temp.write_text(str(int(time.time())) + "\n")
            temp.replace(STATE / "last-health")
            return result
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
        args.step0 = True
        args.step0_wake_id = initial_wake
        return core.reconcile(args)
    finally:
        os.close(fd)
