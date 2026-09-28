"""Step 0 trust checks. No environment-selected roots, interpreters or code."""
from __future__ import annotations

import json
import os
import pathlib
import re
import stat
import socket
import subprocess
import sys
import urllib.parse


class TrustError(RuntimeError):
    pass


def trusted_path(path: pathlib.Path, *, tree: bool = False, _depth: int = 0,
                 _walked: set[str] | None = None) -> None:
    if _depth >= 64:
        raise TrustError("trust_path_cycle")
    path = path.absolute()
    for item in (*reversed(path.parents), path):
        info = item.lstat()
        if info.st_uid != 0 or (not stat.S_ISLNK(info.st_mode) and info.st_mode & 0o022):
            raise TrustError(f"untrusted_path:{item}")
        if sys.platform == "darwin":
            listing = subprocess.run(["/bin/ls", "-lde", str(item)], capture_output=True, text=True, check=True).stdout
            if "+" in listing.split()[0] or re.search(r"^\s*[0-9]+:", listing, re.MULTILINE):
                raise TrustError(f"untrusted_acl:{item}")
        if item.is_symlink():
            target = pathlib.Path(os.readlink(item))
            if not target.is_absolute():
                target = item.parent / target
            # Do not collapse away an untrusted intermediate symlink parent.
            trusted_path(target, _depth=_depth + 1)
    if tree and path.is_dir():
        walked = _walked if _walked is not None else set()
        real = str(path.resolve(strict=True))
        if real in walked:
            return
        walked.add(real)
        for item in path.rglob("*"):
            trusted_path(item, tree=item.is_symlink() and item.is_dir(),
                         _depth=_depth + 1, _walked=walked)


def read_env(path: pathlib.Path) -> dict[str, str]:
    result = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep or key in result or not re.fullmatch(r"CHIEF_[A-Z_]+", key):
            raise TrustError("invalid_node_env")
        result[key] = value
    return result


def validate_config(data: dict[str, str]) -> dict[str, str]:
    allowed = {"CHIEF_NODE_ID", "CHIEF_CORE_URL", "CHIEF_NODE_PLAN_KEY", "CHIEF_NODE_AUTH_TOKEN", "CHIEF_RUNTIME_USER", "CHIEF_CODE_ROOT"}
    if data.keys() - allowed:
        raise TrustError("unexpected_node_config_key")
    for key, fixed in (("CHIEF_NODE_PLAN_KEY", "/etc/chief/node-plan.key"), ("CHIEF_NODE_AUTH_TOKEN", "/etc/chief/node-auth.token")):
        if key in data and data[key] != fixed:
            raise TrustError("unexpected_secret_path")
    node = data.get("CHIEF_NODE_ID", "")
    url = urllib.parse.urlsplit(data.get("CHIEF_CORE_URL", ""))
    if not re.fullmatch(r"h-[a-z0-9]+", node) or url.scheme not in {"http", "https"} or not url.hostname:
        raise TrustError("missing_or_invalid_node_config")
    if url.username or url.password or url.query or url.fragment or url.path not in {"", "/"}:
        raise TrustError("invalid_core_url")
    if url.hostname in {"localhost", "127.0.0.1", "::1"} and node != "h-do1":
        raise TrustError("loopback_core_on_remote_node")
    result = {"CHIEF_NODE_ID": node, "CHIEF_CORE_URL": data["CHIEF_CORE_URL"].rstrip("/"),
              "CHIEF_NODE_PLAN_KEY": "/etc/chief/node-plan.key",
              "CHIEF_NODE_AUTH_TOKEN": "/etc/chief/node-auth.token"}
    if "CHIEF_CODE_ROOT" in data:
        if (data["CHIEF_CODE_ROOT"] != "/opt/chief/deploy" or sys.platform != "linux"
                or data.get("CHIEF_RUNTIME_USER") != "root"):
            raise TrustError("invalid_code_root")
        result["CHIEF_CODE_ROOT"] = data["CHIEF_CODE_ROOT"]
    return result


def resolve_config(existing: dict[str, str] | None, hostname: str, registry: dict) -> dict[str, str]:
    """Registry snapshot shipped as reviewed code; existing root config is checked."""
    matches = [v for k, v in registry.items() if hostname.split(".")[0] in (k, v["fqdn"].split(".")[0])]
    if not matches and existing and existing.get("CHIEF_NODE_ID") in registry:
        matches = [registry[existing["CHIEF_NODE_ID"]]]
    if len(matches) != 1:
        raise TrustError(f"host_not_in_trusted_registry:{hostname}")
    record = matches[0]
    expected = validate_config({**{k: v for k, v in record.items() if k.startswith("CHIEF_")},
                                "CHIEF_RUNTIME_USER": record["runtime_user"]})
    if existing:
        actual = validate_config({"CHIEF_RUNTIME_USER": record["runtime_user"], **existing})
        if "CHIEF_CODE_ROOT" in actual and actual["CHIEF_CODE_ROOT"] != expected.get("CHIEF_CODE_ROOT"):
            raise TrustError("invalid_code_root")
        if actual["CHIEF_NODE_ID"] != expected["CHIEF_NODE_ID"]:
            raise TrustError("node_identity_conflicts_with_registry")
        # A deliberate root-owned endpoint is allowed, including hub loopback.
        expected = actual
    expected["CHIEF_RUNTIME_USER"] = record["runtime_user"]
    return expected


def load_config(path: pathlib.Path = pathlib.Path("/etc/chief/node.env")) -> dict[str, str]:
    if not path.exists():
        raise TrustError("missing_node_env:/etc/chief/node.env")
    trusted_path(path)
    data = read_env(path)
    registry_path = pathlib.Path(__file__).parent / "step0/host-contracts.json"
    trusted_path(registry_path)
    return resolve_config(data, socket.gethostname(), json.loads(registry_path.read_text()))
