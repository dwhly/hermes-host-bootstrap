"""Read-only closure checks requiring the validated, isolated Python runtime."""
from __future__ import annotations

import fnmatch
import json
import os
import pathlib
import plistlib
import pwd
import re
import socket
import subprocess

from . import core, runtime, supervisor  # also prove all root entry imports
from .security import read_env, resolve_config

BASE = pathlib.Path(__file__).parent / "step0"


def check() -> int:
    failures = []

    def attempt(label, function):
        try:
            function()
        except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError) as exc:
            failures.append(label)
            print(f"chief Step 0 HOLD: {label}: {exc}", flush=True)

    # Projection files include REGISTRY_FQDN, so read their simple data directly.
    def projections():
        registry = json.loads((BASE / "host-contracts.json").read_text())
        for node, record in registry.items():
            expected = {"CHIEF_NODE_ID": node, "CHIEF_CORE_URL": record["CHIEF_CORE_URL"],
                        "CHIEF_RUNTIME_USER": record["runtime_user"], "REGISTRY_FQDN": record["fqdn"]}
            if "CHIEF_CODE_ROOT" in record:
                expected["CHIEF_CODE_ROOT"] = record["CHIEF_CODE_ROOT"]
            actual = dict(line.split("=", 1) for line in (BASE / "hosts" / (node + ".env")).read_text().splitlines())
            if actual != expected:
                raise ValueError("host_contract_projection_mismatch:" + node)

    def node_config():
        registry = json.loads((BASE / "host-contracts.json").read_text())
        path = pathlib.Path("/etc/chief/node.env")
        data = resolve_config(read_env(path) if path.exists() else None, socket.gethostname(), registry)
        runtime.configure(data, check_only=True)

    attempt("host-contracts", projections)
    attempt("node_config_invalid", node_config)
    if os.uname().sysname == "Darwin":
        for name in ("node-reconcile", "node-supervisor", "update-request", "update-login"):
            def plist(name=name):
                data = plistlib.loads((BASE / "launchd" / ("com.chief." + name + ".plist")).read_bytes())
                command = {"node-reconcile": "hermes-converger", "node-supervisor": "chief-node-supervisor",
                           "update-request": "hermes-converger", "update-login": "chief-update-request"}[name]
                expected = ["/opt/chief/bin/" + command]
                if data["Label"] != "com.chief." + name or data["ProgramArguments"] != expected:
                    raise ValueError("unexpected_job_definition")
            attempt("job_definition:" + name, plist)
    else:
        for path in sorted((BASE / "systemd").iterdir()):
            def unit(path=path):
                text = path.read_text()
                if path.suffix == ".service":
                    command = "chief-node-supervisor" if path.name == "chief-node-supervisor.service" else "hermes-converger"
                    if re.findall(r"^ExecStart=(.*)$", text, re.MULTILINE) != ["/opt/chief/bin/" + command]:
                        raise ValueError("unexpected_job_definition")
                if not re.search(r"^\[(Service|Timer|Path)\]$", text, re.MULTILINE):
                    raise ValueError("missing_job_section")
            attempt("job_definition:" + path.name, unit)

    registry = json.loads((BASE / "host-contracts.json").read_text())
    commands = [base + name for base in ("/opt/chief/bin/", "/usr/local/bin/")
                for name in ("hermes-converger", "chief-node-supervisor", "chief-update")]
    for user in sorted({r["runtime_user"] for r in registry.values()} - {"root"}):
        try:
            pwd.getpwnam(user)
        except KeyError:
            continue

        def policy(user=user):
            result = subprocess.run(["/usr/bin/sudo", "-ll", "-U", user], capture_output=True,
                                    text=True, check=True)
            free = in_commands = False
            for line in result.stdout.splitlines():
                if line.startswith("Sudoers entry:"):
                    free = in_commands = False
                if "Options:" in line:
                    free = "!authenticate" in line
                if "Commands:" in line:
                    in_commands = True
                    continue
                if not (free and in_commands and line.strip()):
                    continue
                pattern = line.strip().split()[0]
                # Exact retired paths (including expanded aliases) are removed
                # by sudoers.awk. Broad rules survive and require admin repair.
                if pattern.startswith("!") or pattern in commands[3:]:
                    continue
                if any(pattern == "ALL" or fnmatch.fnmatchcase(command, pattern) or
                       (pattern.endswith("/") and command.startswith(pattern)) for command in commands):
                    raise ValueError(f"remaining_passwordless_grant:{user}:{pattern}")
        attempt("effective_policy:" + user, policy)
    return int(bool(failures))
