"""Step 0 trust checks. No environment-selected roots, interpreters or code."""
from __future__ import annotations

import json
import os
import pathlib
import re
import stat
import urllib.parse


class TrustError(RuntimeError):
    pass


def trusted_path(path: pathlib.Path, *, tree: bool = False) -> None:
    path = path.absolute()
    for item in (*reversed(path.parents), path):
        info = item.lstat()
        if info.st_uid != 0 or (not stat.S_ISLNK(info.st_mode) and info.st_mode & 0o022):
            raise TrustError(f"untrusted_path:{item}")
        if item.is_symlink():
            trusted_path(item.resolve(strict=True))
    if tree and path.is_dir():
        for item in path.rglob("*"):
            trusted_path(item)


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
    node = data.get("CHIEF_NODE_ID", "")
    url = urllib.parse.urlsplit(data.get("CHIEF_CORE_URL", ""))
    if not re.fullmatch(r"h-[a-z0-9]+", node) or url.scheme not in {"http", "https"} or not url.hostname:
        raise TrustError("missing_or_invalid_node_config")
    if url.username or url.password or url.query or url.fragment or url.path not in {"", "/"}:
        raise TrustError("invalid_core_url")
    if url.hostname in {"localhost", "127.0.0.1", "::1"} and node != "h-do1":
        raise TrustError("loopback_core_on_remote_node")
    return {"CHIEF_NODE_ID": node, "CHIEF_CORE_URL": data["CHIEF_CORE_URL"].rstrip("/"),
            "CHIEF_NODE_PLAN_KEY": "/etc/chief/node-plan.key",
            "CHIEF_NODE_AUTH_TOKEN": "/etc/chief/node-auth.token"}


def resolve_config(existing: dict[str, str] | None, hostname: str, registry: dict) -> dict[str, str]:
    """Registry snapshot shipped as reviewed code; existing root config is checked."""
    matches = [v for k, v in registry.items() if hostname in (k, v["fqdn"], v["fqdn"].split(".")[0])]
    if len(matches) != 1:
        raise TrustError(f"host_not_in_trusted_registry:{hostname}")
    record = matches[0]
    expected = validate_config(record)
    if existing:
        actual = validate_config(existing)
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
    valid = validate_config(data)
    user = data.get("CHIEF_RUNTIME_USER", "")
    if not re.fullmatch(r"[a-z_][a-z0-9_-]*", user):
        raise TrustError("missing_trusted_runtime_user")
    valid["CHIEF_RUNTIME_USER"] = user
    return valid


def install_config(hostname: str, registry_path: pathlib.Path, destination: pathlib.Path, gid: int) -> None:
    trusted_path(registry_path)
    trusted_path(destination.parent)
    existing = None
    if destination.exists() or destination.is_symlink():
        trusted_path(destination)
        existing = read_env(destination)
    data = resolve_config(existing, hostname, json.loads(registry_path.read_text()))
    # The parent is root-only writable; replace never follows a destination link.
    temp = destination.with_suffix(".env.step0")
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o640)
    try:
        os.fchown(fd, 0, gid)
        with os.fdopen(fd, "w") as stream:
            stream.write("".join(f"{k}={v}\n" for k, v in data.items()))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, destination)
    finally:
        temp.unlink(missing_ok=True)
