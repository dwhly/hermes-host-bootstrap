from __future__ import annotations

import argparse
import base64
import contextlib
import dataclasses
import datetime as dt
import fcntl
import hashlib
import hmac
import json
import os
import pathlib
import pwd
import re
import secrets
import signal
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Callable

try:
    from chief_spec import emit as chief_spec_emit
    from chief_spec.validation import validate_event as chief_spec_validate_event
except ImportError:  # pragma: no cover - exercised only on hosts without chief-spec installed.
    chief_spec_emit = None
    chief_spec_validate_event = None


ALLOWLIST = {"chief", "hermes-node", "harness", "config", "remits", "theme"}
LIVE_PATCH = {"config", "remits", "theme"}
RESTART_REQUIRED = {"chief", "hermes-node", "harness"}
IS_MACOS = sys.platform == "darwin"
SUPERVISED_PROCESS_ALLOWLIST = {"chief-node", "chief-loop-watchdog", "chief-core"}
LINUX_UNIT_MAP = {
    "chief-node": "chief-node.service",
    "chief-loop-watchdog": "chief-loop-watchdog.service",
    "chief-core": "chief-stack-core-1",
}
MACOS_UNIT_MAP = {
    "chief-node": "com.chief.node",
    "chief-loop-watchdog": "com.chief.loop-watchdog",
    "chief-core": "chief-stack-core-1",
}
DOCKER_TOKENS = {"chief-core"}
MACOS_USER_AGENT_TOKENS = {"chief-node"}
MACOS_RUNTIME_STAMP_DIR = pathlib.Path("/var/run/chief/runtime")
# Volatile run dir base differs by OS: macOS has /var/run (no /run); Linux uses /run.
# Keep ALL volatile convergence paths (lease lock, runtime stamp fallback) consistent.
RUN_BASE = "/var/run" if IS_MACOS else "/run"
ARTIFACT_PROCESS_MAP = {
    "chief": (("chief-core",), ("chief-core",)),
    "hermes-node": (("chief-node",), ("chief-node",)),
    "harness": (("chief-loop-watchdog",), ("chief-loop-watchdog",)),
    "config": (tuple(), ("chief-node",)),
    "remits": (tuple(), ("chief-node",)),
    "theme": (tuple(), ("chief-node",)),
}
GIT_REF_RE = re.compile(r"^[0-9a-f]{7,40}$")
DEFAULT_FRESHNESS_S = 600
MAX_FUTURE_S = 60
LEASE_TTL_S = 300
CONVERGER_VERSION = "0.1.0"
CONVERGENCE_EVENT_TYPES = {
    "started": "hermes.fleet.convergence.started",
    "deferred": "hermes.fleet.convergence.deferred",
    "fetched": "hermes.fleet.convergence.fetched",
    "applied": "hermes.fleet.convergence.applied",
    "failed": "hermes.fleet.convergence.failed",
    "rolled_back": "hermes.fleet.convergence.rolled_back",
}
IDLE_LIMITS_S = {
    "directive": 30,
    "lease": 15,
    "heartbeat": 30,
    "subprocess": 10,
    "loop_lock": 10,
}
TOOL_FALLBACK_DIRS = (
    "/root/.local/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/opt/homebrew/bin",
    os.path.expanduser("~/.local/bin"),
)
TOOL_SUBPROCESS_PATH_PREFIX = ":".join((*TOOL_FALLBACK_DIRS, "/bin"))


class ConvergerError(Exception):
    pass


class VerificationError(ConvergerError):
    pass


class Deferred(ConvergerError):
    def __init__(self, reason: str, snapshot: dict[str, Any] | None = None):
        super().__init__(reason)
        self.reason = reason
        self.snapshot = snapshot or {}


def _resolve_tool(name: str) -> str:
    found = shutil.which(name)
    if found:
        return found
    for directory in _tool_fallback_dirs():
        candidate = os.path.join(directory, name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise ConvergerError(f"tool_not_found:{name}")


def _login_user_home() -> str | None:
    sudo_user = os.environ.get("SUDO_USER")
    if sudo_user and sudo_user != "root":
        try:
            return pwd.getpwnam(sudo_user).pw_dir
        except KeyError:
            return None
    return None


def _tool_fallback_dirs() -> tuple[str, ...]:
    dirs = list(TOOL_FALLBACK_DIRS)
    login_home = _login_user_home()
    if login_home:
        dirs.append(os.path.join(login_home, ".local/bin"))
    return tuple(dict.fromkeys(dirs))


def _tool_subprocess_env() -> dict[str, str]:
    prefix = ":".join((*_tool_fallback_dirs(), "/bin"))
    return {**os.environ, "PATH": f"{prefix}:{os.environ.get('PATH', '')}"}


# Root-owned github credential file (written by lib/94 install_root_git_cred) so the
# converger — running as root, whose HOME has no lib/45 user git config — can fetch
# the private chief repos from origin. Same read-only fleet PAT, scoped to github.com.
ROOT_GIT_CRED = "/etc/chief/.git-fleet-credentials"


def _git_fetch_env() -> dict[str, str]:
    env = _tool_subprocess_env()
    env["GIT_TERMINAL_PROMPT"] = "0"
    # Inject git config via env (no on-disk config needed). The converger runs as
    # ROOT on macOS but the repo is owned by the login user → git's dubious-ownership
    # guard would abort rev-parse/fetch/checkout; safe.directory=* permits it. The
    # credential helper (when the root cred file exists) lets root fetch from origin.
    keys: list[tuple[str, str]] = [("safe.directory", "*")]
    if os.path.isfile(ROOT_GIT_CRED):
        keys.append(("credential.https://github.com.helper", f"store --file={ROOT_GIT_CRED}"))
    env["GIT_CONFIG_COUNT"] = str(len(keys))
    for i, (k, v) in enumerate(keys):
        env[f"GIT_CONFIG_KEY_{i}"] = k
        env[f"GIT_CONFIG_VALUE_{i}"] = v
    return env


def unit_for(token: str) -> str:
    validate_supervised_process(token, action="unit")
    mapping = MACOS_UNIT_MAP if IS_MACOS else LINUX_UNIT_MAP
    return mapping[token]


def utcnow() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def parse_time(value: str) -> dt.datetime:
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    parsed = dt.datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def iso_now() -> str:
    return utcnow().replace(microsecond=0).isoformat().replace("+00:00", "Z")


def iso_from_timestamp(value: float) -> str:
    return dt.datetime.fromtimestamp(value, dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def iso_after(seconds: int) -> str:
    return (utcnow() + dt.timedelta(seconds=seconds)).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def canonical_json(data: Any) -> bytes:
    return json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def plan_digest_payload(plan: dict[str, Any]) -> dict[str, Any]:
    payload = dict(plan)
    payload.pop("auth", None)
    payload.pop("signature", None)
    payload.pop("plan_digest", None)
    return payload


def sha256_digest(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def b64url_decode(value: str) -> bytes:
    padded = value + ("=" * ((4 - len(value) % 4) % 4))
    return base64.urlsafe_b64decode(padded.encode("ascii"))


def b64url_encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def new_ulid() -> str:
    # Crockford base32 ULID: 48-bit millisecond timestamp + 80 bits of randomness.
    alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    value = (int(time.time() * 1000) << 80) | secrets.randbits(80)
    chars = []
    for _ in range(26):
        chars.append(alphabet[value & 0x1F])
        value >>= 5
    return "".join(reversed(chars))


def sign_plan_fields(plan: dict[str, Any], key: bytes) -> str:
    msg = "\n".join(
        [
            str(plan["desired_id"]),
            str(plan["target_ref"]),
            str(plan["plan_digest"]),
            str(plan["issued_at"]),
            str(plan["node_id"]),
        ]
    ).encode("utf-8")
    return b64url_encode(hmac.new(key, msg, hashlib.sha256).digest())


def select_desired_row(plan: dict[str, Any], target_artifact: str | None = None) -> dict[str, Any]:
    desired = plan.get("desired")
    if not isinstance(desired, list) or not desired:
        raise VerificationError("desired_missing")
    rows = [row for row in desired if isinstance(row, dict)]
    if len(rows) != len(desired):
        raise VerificationError("desired_malformed")
    if target_artifact:
        matches = [row for row in rows if str(row.get("artifact", "")) == target_artifact]
        if not matches:
            raise VerificationError(f"desired_artifact_not_found:{target_artifact}")
        if len(matches) > 1:
            raise VerificationError(f"desired_artifact_ambiguous:{target_artifact}")
        return matches[0]
    if len(rows) != 1:
        raise VerificationError("artifact_required_for_multi_desired_plan")
    return rows[0]


def auth_for_desired(plan: dict[str, Any], desired_id: str) -> dict[str, Any]:
    auth = plan.get("auth")
    if not isinstance(auth, list):
        raise VerificationError("auth_missing")
    matches = [entry for entry in auth if isinstance(entry, dict) and str(entry.get("desired_id", "")) == desired_id]
    if not matches:
        raise VerificationError(f"auth_missing_for_desired:{desired_id}")
    if len(matches) > 1:
        raise VerificationError(f"auth_ambiguous_for_desired:{desired_id}")
    return matches[0]


def fixed_artifact_processes(artifact: str) -> tuple[tuple[str, ...], tuple[str, ...]]:
    try:
        restart_units, affected = ARTIFACT_PROCESS_MAP[artifact]
    except KeyError as exc:
        raise VerificationError(f"artifact_not_allowlisted:{artifact}") from exc
    for unit in restart_units:
        validate_supervised_process(unit, action="restart_unit")
    for process in affected:
        validate_supervised_process(process, action="reload_target")
    return restart_units, affected


@dataclasses.dataclass(frozen=True)
class VerifiedPlan:
    raw: dict[str, Any]
    artifact: str
    apply_mode: str
    affected_processes: tuple[str, ...]
    restart_units: tuple[str, ...]


def verify_plan(
    plan: dict[str, Any],
    *,
    node_id: str,
    key_lookup: Callable[[str], bytes | None],
    watermarks: dict[str, Any] | None = None,
    now: dt.datetime | None = None,
    target_artifact: str | None = None,
) -> VerifiedPlan:
    now = now or utcnow()
    desired = select_desired_row(plan, target_artifact)
    artifact = str(desired.get("artifact", ""))
    if artifact not in ALLOWLIST:
        raise VerificationError(f"artifact_not_allowlisted:{artifact}")
    if str(plan.get("node_id", "")) != node_id:
        raise VerificationError("node_id_mismatch")
    if str(desired.get("node_id", "")) != node_id:
        raise VerificationError("node_id_mismatch")
    if str(desired.get("allowed_executor_action", "")) != "converge":
        raise VerificationError("executor_action_mismatch")

    apply_mode = str(desired.get("apply_mode", ""))
    if artifact in LIVE_PATCH and apply_mode != "live_patch":
        raise VerificationError("apply_mode_mismatch")
    if artifact in RESTART_REQUIRED and apply_mode != "restart_required":
        raise VerificationError("apply_mode_mismatch")

    expected_digest = sha256_digest(canonical_json(plan_digest_payload(plan)))
    if plan.get("plan_digest") != expected_digest:
        raise VerificationError("plan_digest_mismatch")

    desired_id = str(desired.get("desired_id", ""))
    auth = auth_for_desired(plan, desired_id)
    if str(auth.get("target_ref", "")) != str(desired.get("target_ref", "")):
        raise VerificationError("auth_target_ref_mismatch")
    if str(auth.get("node_id", "")) != node_id:
        raise VerificationError("auth_node_id_mismatch")
    if str(auth.get("plan_digest", "")) != expected_digest:
        raise VerificationError("auth_plan_digest_mismatch")

    sig = auth.get("signature") or {}
    if sig.get("alg") != "HMAC-SHA256":
        raise VerificationError("signature_alg_mismatch")
    key_id = str(sig.get("key_id", ""))
    key = key_lookup(key_id)
    if key is None:
        raise VerificationError("unknown_key_id")
    expected_key_id = f"node:{node_id}:plan-v1"
    if key_id != expected_key_id:
        raise VerificationError("unknown_key_id")
    auth_fields = {
        "desired_id": desired_id,
        "target_ref": str(auth.get("target_ref", "")),
        "plan_digest": str(auth.get("plan_digest", "")),
        "issued_at": str(auth.get("issued_at", "")),
        "node_id": str(auth.get("node_id", "")),
    }
    expected_sig = sign_plan_fields(auth_fields, key)
    try:
        actual_sig = b64url_decode(str(sig.get("value", "")))
        expected_sig_bytes = b64url_decode(expected_sig)
    except Exception as exc:
        raise VerificationError("bad_signature") from exc
    if not hmac.compare_digest(actual_sig, expected_sig_bytes):
        raise VerificationError("bad_signature")

    issued_at = parse_time(str(auth["issued_at"]))
    age = (now - issued_at).total_seconds()
    future = (issued_at - now).total_seconds()
    if age >= DEFAULT_FRESHNESS_S:
        raise VerificationError("stale_plan")
    if future > MAX_FUTURE_S:
        raise VerificationError("future_plan")

    mark = (watermarks or {}).get(node_id, {}).get(artifact)
    if mark:
        mark_time = parse_time(str(mark["issued_at"]))
        identical_current = (
            desired_id == mark.get("desired_id")
            and desired.get("target_ref") == mark.get("target_ref")
            and auth.get("plan_digest") == mark.get("plan_digest")
        )
        if issued_at <= mark_time and not identical_current:
            raise VerificationError("replay_below_watermark")

    restart_units, affected = fixed_artifact_processes(artifact)
    raw = dict(desired)
    raw["issued_at"] = str(auth["issued_at"])
    raw["plan_digest"] = str(auth["plan_digest"])
    raw["node_id"] = node_id
    return VerifiedPlan(raw, artifact, apply_mode, affected, restart_units)


def validate_supervised_process(target: str, *, action: str) -> None:
    if target not in SUPERVISED_PROCESS_ALLOWLIST:
        raise ConvergerError(f"{action}_not_allowlisted:{target}")


def _sudo_uid() -> int | None:
    value = os.environ.get("SUDO_UID")
    if not value:
        return None
    try:
        uid = int(value)
    except ValueError:
        return None
    return uid if uid > 0 else None


def _console_uid() -> int | None:
    try:
        result = subprocess.run([_resolve_tool("stat"), "-f", "%u", "/dev/console"], check=True, capture_output=True, text=True)
        uid = int(result.stdout.strip())
    except (ConvergerError, OSError, subprocess.CalledProcessError, ValueError):
        return None
    return uid if uid > 0 else None


def _launch_agent_plist_owner_uid(label: str) -> int | None:
    homes: list[str] = []
    login_home = _login_user_home()
    if login_home:
        homes.append(login_home)
    for user_home in pathlib.Path("/Users").glob("*/Library/LaunchAgents"):
        homes.append(str(user_home.parent.parent))
    for home in dict.fromkeys(homes):
        plist = pathlib.Path(home) / "Library" / "LaunchAgents" / f"{label}.plist"
        try:
            uid = plist.stat().st_uid
        except OSError:
            continue
        if uid > 0:
            return uid
    return None


def _launchd_target(token: str, label: str) -> str:
    if token in MACOS_USER_AGENT_TOKENS:
        # The converger normally runs as root via sudo, while the node is a login
        # user's LaunchAgent. Prefer SUDO_UID from sudo's preserved context, then
        # the plist owner, then the active console uid.
        uid = _sudo_uid() or _launch_agent_plist_owner_uid(label) or _console_uid()
        if uid is None:
            raise ConvergerError(f"launchd_user_uid_not_found:{label}")
        return f"gui/{uid}/{label}"
    return f"system/{label}"


def validate_git_ref(target_ref: str) -> None:
    if not GIT_REF_RE.fullmatch(target_ref):
        raise ConvergerError(f"target_ref_not_git_sha:{target_ref}")


@dataclasses.dataclass
class IdleSnapshot:
    idle: bool
    reason: str | None
    probes: dict[str, Any]


def evaluate_idle(snapshot: dict[str, Any] | None, *, now: dt.datetime | None = None) -> IdleSnapshot:
    now = now or utcnow()
    if not snapshot or not snapshot.get("query_ok"):
        return IdleSnapshot(False, "coordination_probe_untrusted", snapshot or {})

    if snapshot.get("accepted_work_after_idle_check"):
        return IdleSnapshot(False, "accepted_work_after_idle_check", snapshot)
    if snapshot.get("active_directives"):
        return IdleSnapshot(False, "active_directive", snapshot)
    if snapshot.get("held_leases"):
        return IdleSnapshot(False, "held_process_lease", snapshot)
    if snapshot.get("running_work"):
        return IdleSnapshot(False, "running_work_subprocess", snapshot)
    if snapshot.get("loop_lock_active"):
        return IdleSnapshot(False, "local_loop_lock", snapshot)

    checks = (
        ("directive_observed_at", "directive"),
        ("lease_observed_at", "lease"),
        ("heartbeat_age_s", "heartbeat"),
        ("subprocess_observed_at", "subprocess"),
        ("loop_lock_observed_at", "loop_lock"),
    )
    for field, kind in checks:
        if field not in snapshot:
            return IdleSnapshot(False, f"{kind}_probe_missing", snapshot)
        if field == "heartbeat_age_s":
            age = float(snapshot[field])
        else:
            age = (now - parse_time(str(snapshot[field]))).total_seconds()
        if age >= IDLE_LIMITS_S[kind]:
            return IdleSnapshot(False, f"{kind}_probe_stale_or_busy", snapshot)
    return IdleSnapshot(True, None, snapshot)


@dataclasses.dataclass
class PlanStep:
    action: str
    detail: dict[str, Any]
    writes: bool


def build_execution_plan(plan: VerifiedPlan, idle: IdleSnapshot | None) -> list[PlanStep]:
    target = plan.raw["target_ref"]
    steps = [
        PlanStep("verify_plan", {"artifact": plan.artifact, "target_ref": target}, False),
    ]
    if plan.apply_mode == "live_patch":
        steps.extend(
            [
                PlanStep("fetch", {"artifact": plan.artifact, "target_ref": target, "destination": "fixed_staging_path"}, True),
                PlanStep("validate", {"artifact": plan.artifact}, False),
                PlanStep("atomic_install", {"artifact": plan.artifact, "destination": "fixed_local_config_path"}, True),
                PlanStep("record_reload_signal_at", {"path": "/var/lib/chief/converger/reload-signal-times.json"}, True),
                PlanStep("signal_reload", {"processes": list(plan.affected_processes)}, True),
                PlanStep("poll_runtime_ack", {"timeout_s": 30, "interval_s": 2, "target_ref": target}, False),
            ]
        )
    else:
        steps.append(PlanStep("evaluate_idle", dataclasses.asdict(idle) if idle else {"idle": "unknown"}, False))
        steps.extend(
            [
                PlanStep("acquire_convergence_lease", {"ttl_s": LEASE_TTL_S, "lock": f"{RUN_BASE}/chief/convergence/{plan.raw['node_id']}.lock"}, True),
                PlanStep("reevaluate_idle_inside_lease", {"abort_reason": "accepted_work_after_idle_check"}, False),
                PlanStep("fetch", {"artifact": plan.artifact, "target_ref": target, "destination": "fixed_repo_path"}, True),
                PlanStep("emit_fetched", {"event": "hermes.fleet.convergence.fetched"}, True),
                PlanStep("install", {"command": "uv pip install --python .venv/bin/python -q -e ../chief-spec/sdk/python -e ."}, True),
                PlanStep("restart", {"units": list(plan.restart_units)}, True),
                PlanStep("wait_steady_health", {"requires": ["up", "restart_count_flat", "fresh_runtime_ref"]}, False),
                PlanStep("rollback_once_on_failure", {"requires_runtime_proof": True}, True),
            ]
        )
    return steps


class LocalState:
    def __init__(self, root: pathlib.Path = pathlib.Path("/")):
        self.root = root
        self.state_dir = self._path("/var/lib/chief/converger")
        self.run_dir = self._path(f"{RUN_BASE}/chief/convergence")

    def _path(self, absolute: str) -> pathlib.Path:
        return self.root / absolute.lstrip("/")

    def read_json(self, path: pathlib.Path, default: Any) -> Any:
        try:
            return json.loads(path.read_text())
        except FileNotFoundError:
            return default

    def write_json_0640(self, path: pathlib.Path, data: Any) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps(data, sort_keys=True, indent=2) + "\n")
        os.chmod(tmp, 0o640)
        os.replace(tmp, path)

    def load_watermarks(self) -> dict[str, Any]:
        return self.read_json(self.state_dir / "desired-watermarks.json", {})

    def update_watermark(self, plan: VerifiedPlan) -> None:
        marks = self.load_watermarks()
        marks.setdefault(plan.raw["node_id"], {})[plan.artifact] = {
            "desired_id": plan.raw["desired_id"],
            "target_ref": plan.raw["target_ref"],
            "issued_at": plan.raw["issued_at"],
            "plan_digest": plan.raw["plan_digest"],
        }
        self.write_json_0640(self.state_dir / "desired-watermarks.json", marks)

    def journal(self, record: dict[str, Any]) -> None:
        path = self.state_dir / "journal.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"at": iso_now(), **record}, sort_keys=True) + "\n")

    @contextlib.contextmanager
    def convergence_lease(self, node_id: str, convergence_id: str, artifact: str, affected: tuple[str, ...]):
        self.run_dir.mkdir(parents=True, exist_ok=True)
        path = self.run_dir / f"{node_id}.lock"
        with path.open("a+") as fh:
            try:
                fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as exc:
                raise Deferred("convergence_lease_held") from exc
            lease = {
                "lease_id": "cnvlease_" + secrets.token_hex(8),
                "node_id": node_id,
                "convergence_id": convergence_id,
                "artifact": artifact,
                "affected_processes": list(affected),
                "holder": "hermes-converger",
                "acquired_at": iso_now(),
                "expires_at": (utcnow() + dt.timedelta(seconds=LEASE_TTL_S)).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
                "state": "held",
            }
            fh.seek(0)
            fh.truncate()
            fh.write(json.dumps(lease, sort_keys=True) + "\n")
            fh.flush()
            try:
                yield lease
            finally:
                fh.seek(0)
                fh.truncate()
                fh.write(json.dumps({**lease, "state": "released", "released_at": iso_now()}, sort_keys=True) + "\n")
                fh.flush()
                fcntl.flock(fh.fileno(), fcntl.LOCK_UN)


def ensure_convergence_id(plan: VerifiedPlan) -> str:
    convergence_id = plan.raw.get("convergence_id")
    if not convergence_id:
        convergence_id = "cnv_" + secrets.token_hex(8)
        plan.raw["convergence_id"] = convergence_id
    return str(convergence_id)


def _nonempty(value: Any, default: str = "unknown") -> str:
    text = str(value) if value is not None else ""
    return text if text else default


def _apply_mode(value: Any) -> str:
    text = str(value) if value is not None else ""
    return text if text in {"live_patch", "restart_required", "manual_only"} else "manual_only"


def _current_ref(plan: VerifiedPlan, field: str) -> str | None:
    current_fold = plan.raw.get("current_fold")
    if not isinstance(current_fold, dict):
        return None
    value = current_fold.get(field)
    if not isinstance(value, dict):
        return None
    ref = value.get("ref")
    return str(ref) if ref else None


def _executor(node_id: str, convergence_id: str) -> dict[str, str]:
    return {
        "kind": "hermes-converger",
        "version": CONVERGER_VERSION,
        "instance": f"{node_id}/{convergence_id}/systemd",
    }


def _shared_convergence_data(plan: VerifiedPlan, observed_at: str) -> dict[str, Any]:
    node_id = _nonempty(plan.raw.get("node_id"))
    convergence_id = ensure_convergence_id(plan)
    return {
        "convergence_id": convergence_id,
        "desired_id": _nonempty(plan.raw.get("desired_id")),
        "node_id": node_id,
        "artifact": _nonempty(plan.artifact),
        "target_ref": _nonempty(plan.raw.get("target_ref")),
        "apply_mode": _apply_mode(plan.apply_mode),
        "executor": _executor(node_id, convergence_id),
        "force": bool(plan.raw.get("force", False)),
        "observed_at": observed_at,
    }


def convergence_event_data(event_name: str, plan: VerifiedPlan, extra: dict[str, Any], observed_at: str) -> dict[str, Any]:
    data = _shared_convergence_data(plan, observed_at)
    if event_name == "started":
        data.update({"trigger": str(extra.get("trigger") or "operator"), "plan_digest": _nonempty(plan.raw.get("plan_digest"))})
    elif event_name == "deferred":
        data.update(
            {
                "reason": _nonempty(extra.get("reason")),
                "idle_snapshot": extra.get("idle_snapshot") if isinstance(extra.get("idle_snapshot"), dict) else {},
                "next_check_after": str(extra.get("next_check_after") or iso_after(60)),
            }
        )
    elif event_name == "fetched":
        data.update(
            {
                "previous_disk_ref": extra.get("previous_disk_ref", _current_ref(plan, "fetched")),
                "fetched_ref": str(extra.get("fetched_ref") or plan.raw.get("target_ref")),
                "fetch_method": str(extra.get("fetch_method") or "git_fetch_checkout"),
                "ground_truth": extra.get("ground_truth") if isinstance(extra.get("ground_truth"), dict) else {},
            }
        )
    elif event_name == "applied":
        verification = extra.get("verification")
        if not isinstance(verification, dict):
            raise ConvergerError("applied_requires_verification")
        data.update(
            {
                "previous_running_ref": extra.get("previous_running_ref", _current_ref(plan, "running")),
                "running_ref": str(extra.get("running_ref") or verification.get("stamp_freshness_evidence", {}).get("loaded_ref") or plan.raw.get("target_ref")),
                "health": str(extra.get("health") or "healthy"),
                "verification": verification,
            }
        )
    elif event_name == "failed":
        data.update(
            {
                "stage": str(extra.get("stage") or "converge"),
                "reason": _nonempty(extra.get("reason")),
                "recoverable": bool(extra.get("recoverable", True)),
                "health": str(extra.get("health") or "unknown"),
                "logs_ref": str(extra.get("logs_ref") or f"journalctl://hermes-converger/{data['convergence_id']}"),
            }
        )
    elif event_name == "rolled_back":
        verification = extra.get("verification")
        if not isinstance(verification, dict):
            raise ConvergerError("rolled_back_requires_verification")
        data.update(
            {
                "from_ref": str(extra.get("from_ref") or plan.raw.get("target_ref")),
                "to_ref": str(extra.get("to_ref") or extra.get("rollback_ref") or verification.get("stamp_freshness_evidence", {}).get("loaded_ref")),
                "reason": str(extra.get("reason") or "rollback_verified"),
                "health_after": str(extra.get("health_after") or "healthy"),
                "verification": verification,
            }
        )
    else:
        raise ConvergerError(f"unknown_convergence_event:{event_name}")
    return data


def _event_payload(event: Any) -> dict[str, Any]:
    if hasattr(event, "model_dump"):
        return {k: v for k, v in event.model_dump().items() if v is not None}
    return {k: v for k, v in dict(event).items() if v is not None}


def build_convergence_envelope(event_name: str, plan: VerifiedPlan, **extra: Any) -> dict[str, Any]:
    try:
        event_type = CONVERGENCE_EVENT_TYPES[event_name]
    except KeyError as exc:
        raise ConvergerError(f"unknown_convergence_event:{event_name}") from exc
    observed_at = str(extra.get("observed_at") or iso_now())
    data = convergence_event_data(event_name, plan, extra, observed_at)
    node_id = data["node_id"]
    convergence_id = data["convergence_id"]
    source = f"hermes-converger://{node_id}"
    entityid = f"ent_node_{node_id}"
    actorid = f"act_node_{node_id}"
    sourceref = f"converger://{node_id}/{convergence_id}/{event_name}"

    # Prefer chief_spec.emit when it is importable; production installs may only carry
    # hermes_converger, so the fallback builds the same CloudEvents envelope by hand.
    if chief_spec_emit is not None:
        return _event_payload(
            chief_spec_emit(
                type=event_type,
                source=source,
                contextid="ctx_fleet",
                entityid=entityid,
                actorid=actorid,
                sourceref=sourceref,
                data=data,
                time=observed_at,
                correlationid=convergence_id,
            )
        )
    return {
        "specversion": "1.0",
        "id": new_ulid(),
        "source": source,
        "type": event_type,
        "time": observed_at,
        "datacontenttype": "application/json",
        "contextid": "ctx_fleet",
        "entityid": entityid,
        "actorid": actorid,
        "confidence": 1.0,
        "sensitivity": "internal",
        "sourceref": sourceref,
        "schemaversion": 1,
        "correlationid": convergence_id,
        "data": data,
    }


def validate_envelope(envelope: dict[str, Any]) -> None:
    if chief_spec_validate_event is not None:
        chief_spec_validate_event(envelope)
        return
    required = {"specversion", "id", "source", "type", "time", "contextid", "entityid", "actorid", "confidence", "data"}
    missing = sorted(required - set(envelope))
    if missing:
        raise ConvergerError(f"event_envelope_missing:{','.join(missing)}")


class Transport:
    def __init__(self, core: str, node_id: str, token_path: pathlib.Path | None = None, timeout: float = 10):
        self.core = core.rstrip("/")
        self.node_id = node_id
        self.token_path = token_path or pathlib.Path("/etc/chief/node-auth.token")
        self.timeout = timeout

    def _headers(self) -> dict[str, str]:
        # Bearer transport is assumed to be localhost, Tailscale tailnet, or TLS protected.
        headers = {"Content-Type": "application/json", "X-Chief-Node-ID": self.node_id}
        try:
            token = self.token_path.read_text().strip()
        except FileNotFoundError:
            token = ""
        if token:
            headers["Authorization"] = f"Bearer {token}"
        return headers

    def get_plan(self) -> dict[str, Any]:
        url = f"{self.core}/v1/fleet/nodes/{self.node_id}/convergence-plan"
        req = urllib.request.Request(url, headers=self._headers(), method="GET")
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def emit(self, envelope: dict[str, Any]) -> None:
        validate_envelope(envelope)
        url = f"{self.core}/v1/observations"
        body = json.dumps(envelope).encode("utf-8")
        req = urllib.request.Request(url, data=body, headers=self._headers(), method="POST")
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            resp.read()


class HostOps:
    def __init__(self, state: LocalState, transport: Transport, *, dry_run: bool = False):
        self.state = state
        self.transport = transport
        self.dry_run = dry_run

    def journal_before(self, action: str, detail: dict[str, Any]) -> None:
        if self.dry_run:
            raise AssertionError("plan-only attempted to journal")
        self.state.journal({"before_write": action, "detail": detail})

    def emit(self, event_name: str, plan: VerifiedPlan, **extra: Any) -> None:
        if self.dry_run:
            raise AssertionError("plan-only attempted to emit")
        self.transport.emit(build_convergence_envelope(event_name, plan, **extra))

    def fetch(self, plan: VerifiedPlan) -> None:
        self.journal_before("fetch", {"artifact": plan.artifact, "target_ref": plan.raw["target_ref"]})
        # Local destinations are fixed by artifact; actual source sync is intentionally typed.
        path = self.artifact_path(plan.artifact)
        git = _resolve_tool("git")
        env = _git_fetch_env()
        # Fetch from origin (best-effort): if the target ref is already present locally
        # the checkout still succeeds, so a fetch failure (e.g. transient network) is
        # only fatal when we then can't resolve the target. Don't hard-abort here.
        fetch = subprocess.run([git, "fetch", "--all", "--prune"], cwd=path, env=env,
                               capture_output=True, text=True)
        if fetch is not None and getattr(fetch, "returncode", 0) != 0:
            self.journal_before("fetch_warning", {"artifact": plan.artifact, "stderr": (getattr(fetch, "stderr", "") or "")[-500:]})
        if plan.artifact in RESTART_REQUIRED:
            target_ref = str(plan.raw["target_ref"])
            validate_git_ref(target_ref)
            # Verify the target is resolvable locally before checkout (fail loud if not,
            # e.g. fetch failed AND ref absent). Skipped when subprocess is mocked (None).
            resolve = subprocess.run([git, "rev-parse", "--verify", "--quiet", f"{target_ref}^{{commit}}"],
                                     cwd=path, env=env, capture_output=True, text=True)
            if resolve is not None and getattr(resolve, "returncode", 0) != 0:
                raise ConvergerError(f"target_ref_not_resolvable:{target_ref}")
            subprocess.run([git, "checkout", "--detach", target_ref], cwd=path, env=env, check=True)

    def _chief_code_root(self) -> str:
        # Where the chief git working copies live. Linux/h-do1: /root/code/chief.
        # macOS: the login user's ~/code/chief (the converger runs as root, so derive
        # the login user from SUDO_USER, not root's HOME). Overridable for tests/odd
        # layouts via CHIEF_CODE_ROOT.
        env = os.environ.get("CHIEF_CODE_ROOT")
        if env:
            return env.rstrip("/")
        if IS_MACOS:
            user = os.environ.get("SUDO_USER") or os.environ.get("USER") or ""
            if user:
                return f"/Users/{user}/code/chief"
        return "/root/code/chief"

    def artifact_path(self, artifact: str) -> str:
        root = self._chief_code_root()
        mapping = {
            "chief": root,
            "hermes-node": f"{root}/hermes-node",
            "harness": f"{root}/harness",
            "config": "/etc/chief/config",
            "remits": "/etc/chief/remits",
            "theme": "/etc/chief/theme",
        }
        return mapping[artifact]

    def _login_user(self) -> str | None:
        # The user that owns the macOS venv / LaunchAgent (converger runs as root).
        return os.environ.get("SUDO_USER") or (os.environ.get("USER") if os.getuid() != 0 else None)

    def install_restart_required(self, plan: VerifiedPlan) -> None:
        self.journal_before("install", {"artifact": plan.artifact})
        if plan.artifact == "hermes-node":
            cwd = f"{self._chief_code_root()}/hermes-node"
            cmd = [_resolve_tool("uv"), "pip", "install", "--python", ".venv/bin/python", "-q", "-e", "../chief-spec/sdk/python", "-e", "."]
            # On macOS the venv is owned by the LOGIN user, not root. The converger runs
            # as root (via the scoped sudoers), so a plain `uv pip install` would create
            # root-owned files inside the user's venv and break the user's own deploys.
            # Drop to the login user for the install (root->user needs no password).
            user = self._login_user()
            if IS_MACOS and user and user != "root":
                cmd = ["/usr/bin/sudo", "-n", "-u", user, *cmd]
            subprocess.run(cmd, cwd=cwd, env=_tool_subprocess_env(), check=True)

    def restart_units(self, plan: VerifiedPlan) -> None:
        for token in plan.restart_units:
            validate_supervised_process(token, action="restart_unit")
            unit = unit_for(token)
            self.journal_before("restart", {"unit": unit, "token": token})
            if IS_MACOS and token not in DOCKER_TOKENS:
                subprocess.run([_resolve_tool("launchctl"), "kickstart", "-k", _launchd_target(token, unit)], check=True)
            elif unit.endswith(".service"):
                subprocess.run([_resolve_tool("systemctl"), "restart", unit], check=True)
            else:
                subprocess.run([_resolve_tool("docker"), "restart", unit], check=True)

    def record_reload_and_signal(self, plan: VerifiedPlan) -> str:
        for token in plan.affected_processes:
            validate_supervised_process(token, action="reload_target")
        reload_at = iso_now()
        path = self.state.state_dir / "reload-signal-times.json"
        times = self.state.read_json(path, {})
        for token in plan.affected_processes:
            times.setdefault(token, {})[plan.artifact] = reload_at
        self.journal_before("record_reload_signal_at", {"path": str(path), "reload_signal_at": reload_at})
        self.state.write_json_0640(path, times)
        for token in plan.affected_processes:
            unit = unit_for(token)
            self.journal_before("signal_reload", {"process": unit, "token": token})
            if IS_MACOS and token not in DOCKER_TOKENS:
                subprocess.run([_resolve_tool("launchctl"), "kickstart", "-k", _launchd_target(token, unit)], check=True)
            elif unit.endswith(".service"):
                subprocess.run([_resolve_tool("systemctl"), "kill", "-s", "HUP", unit], check=True)
        return reload_at

    def poll_runtime_ack(self, plan: VerifiedPlan, signal_at: str, timeout_s: int = 30) -> dict[str, Any] | None:
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            proof = read_runtime_proof(plan.artifact, plan.raw["target_ref"], signal_at)
            if proof:
                return proof
            time.sleep(2)
        return None


def read_runtime_proof(artifact: str, target_ref: str, signal_at: str | None = None) -> dict[str, Any] | None:
    roots = runtime_stamp_roots()
    min_time = parse_time(signal_at) if signal_at else None
    for root in roots:
        if not root.exists():
            continue
        for stamp in root.glob(f"*/{artifact}.json"):
            try:
                data = json.loads(stamp.read_text())
                stat = stamp.stat()
            except (OSError, json.JSONDecodeError):
                continue
            observed = data.get("observed_at") or data.get("written_at")
            if data.get("loaded_ref") != target_ref or data.get("health") not in {None, "healthy"}:
                continue
            if min_time and (not observed or parse_time(str(observed)) <= min_time):
                continue
            if min_time and dt.datetime.fromtimestamp(stat.st_mtime, dt.timezone.utc) <= min_time:
                continue
            try:
                pid = int(data["pid"])
                monotonic_nonce = int(data["monotonic_nonce"])
                process_start_time = str(data["process_start_time"])
            except (KeyError, TypeError, ValueError):
                continue
            return {
                "method": "runtime_stamp",
                "runtime_source": {"kind": "file", "path": str(stamp), "source": "runtime-stamp"},
                "observed_at": str(observed),
                "stamp_freshness_evidence": {
                    "reload_signal_at": str(signal_at or observed),
                    "stamp_mtime": iso_from_timestamp(stat.st_mtime),
                    "pid": pid,
                    "process_start_time": process_start_time,
                    "monotonic_nonce": monotonic_nonce,
                    "loaded_ref": target_ref,
                },
            }
    return None


def runtime_stamp_roots() -> list[pathlib.Path]:
    override = os.environ.get("HERMES_RUNTIME_STAMP_DIR")
    if override:
        return [pathlib.Path(override)]
    if IS_MACOS:
        # The macOS node's default tempfile directory may be per-user, while the
        # converger runs as root. The node LaunchAgent must set this same path.
        return [MACOS_RUNTIME_STAMP_DIR]
    roots = [pathlib.Path("/run/chief/runtime")]
    tmp = os.environ.get("TMPDIR")
    if tmp:
        roots.append(pathlib.Path(tmp) / "chief/runtime")
    return roots


def plan_only_output(plan: VerifiedPlan, idle: IdleSnapshot | None) -> str:
    result = {
        "mode": "plan-only",
        "writes": "none",
        "emits": "none",
        "artifact": plan.artifact,
        "apply_mode": plan.apply_mode,
        "desired_id": plan.raw["desired_id"],
        "target_ref": plan.raw["target_ref"],
        "idle_decision": dataclasses.asdict(idle) if idle else None,
        "steps": [dataclasses.asdict(step) for step in build_execution_plan(plan, idle)],
    }
    return json.dumps(result, sort_keys=True, indent=2)


def execute_plan(
    plan: VerifiedPlan,
    ops: HostOps,
    idle_snapshot: dict[str, Any] | None = None,
    idle_snapshot_reader: Callable[[], dict[str, Any] | None] | None = None,
) -> str:
    def current_idle_snapshot() -> dict[str, Any] | None:
        if idle_snapshot_reader:
            return idle_snapshot_reader()
        return idle_snapshot

    def mark_success() -> None:
        ops.state.update_watermark(plan)

    ops.emit("started", plan)
    if plan.apply_mode == "live_patch":
        try:
            ops.fetch(plan)
            signal_at = ops.record_reload_and_signal(plan)
            proof = ops.poll_runtime_ack(plan, signal_at)
            if not proof:
                ops.emit("failed", plan, reason="runtime_ack_timeout", verification=None)
                return "failed"
            ops.emit("applied", plan, verification=proof)
            mark_success()
            return "applied"
        except Exception as exc:
            ops.emit("failed", plan, reason=type(exc).__name__, verification=None)
            return "failed"

    idle = evaluate_idle(current_idle_snapshot())
    if not idle.idle:
        ops.emit("deferred", plan, reason=idle.reason, idle_snapshot=idle.probes)
        return "deferred"
    try:
        with ops.state.convergence_lease(plan.raw["node_id"], str(plan.raw.get("convergence_id") or secrets.token_hex(8)), plan.artifact, plan.affected_processes):
            inside = evaluate_idle(current_idle_snapshot())
            if not inside.idle:
                ops.emit("deferred", plan, reason="accepted_work_after_idle_check", idle_snapshot=inside.probes)
                return "deferred"
            ops.fetch(plan)
            ops.emit("fetched", plan)
            ops.install_restart_required(plan)
            ops.restart_units(plan)
            proof = ops.poll_runtime_ack(plan, iso_now())
            if proof:
                ops.emit("applied", plan, verification=proof)
                mark_success()
                return "applied"
            ops.emit("failed", plan, reason="steady_health_timeout", verification=None)
            rolled = attempt_rollback_once(plan, ops)
            if rolled:
                mark_success()
            return "rolled_back" if rolled else "failed"
    except Deferred as exc:
        ops.emit("deferred", plan, reason=exc.reason, idle_snapshot=exc.snapshot)
        return "deferred"
    except Exception as exc:
        ops.emit("failed", plan, reason=type(exc).__name__, verification=None)
        rolled = attempt_rollback_once(plan, ops)
        if rolled:
            mark_success()
        return "rolled_back" if rolled else "failed"


def attempt_rollback_once(plan: VerifiedPlan, ops: HostOps) -> bool:
    lkg_path = ops.state.state_dir / "last-known-good.json"
    lkg = ops.state.read_json(lkg_path, {}).get(plan.artifact)
    if not lkg or lkg.get("restore_method") not in {"git_checkout+uv_install+systemd_restart"}:
        return False
    ops.journal_before("rollback", {"artifact": plan.artifact, "running_ref": lkg.get("running_ref")})
    try:
        disk_ref = str(lkg["disk_ref"])
        validate_git_ref(disk_ref)
        subprocess.run([_resolve_tool("git"), "checkout", disk_ref], cwd=ops.artifact_path(plan.artifact), check=True)
        ops.install_restart_required(plan)
        ops.restart_units(plan)
        proof = ops.poll_runtime_ack(dataclasses.replace(plan, raw={**plan.raw, "target_ref": lkg["running_ref"]}), iso_now())
        if proof:
            ops.emit("rolled_back", plan, rollback_ref=lkg["running_ref"], verification=proof)
            return True
        ops.emit("failed", plan, reason="rollback_unverified", verification=None)
        return False
    except Exception as exc:
        ops.emit("failed", plan, reason=f"rollback_{type(exc).__name__}", verification=None)
        return False


def default_key_lookup(node_id: str, key_path: pathlib.Path) -> Callable[[str], bytes | None]:
    def lookup(key_id: str) -> bytes | None:
        if key_id != f"node:{node_id}:plan-v1":
            return None
        try:
            return key_path.read_bytes().strip()
        except FileNotFoundError:
            return None

    return lookup


def load_cached_plan(state: LocalState) -> dict[str, Any]:
    return state.read_json(state.state_dir / "cached-plan.json", {})


def reconcile(args: argparse.Namespace) -> int:
    state = LocalState(pathlib.Path(args.state_root))
    lock_path = state._path("/var/run/chief/reconcile.lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+") as fh:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if args.plan_only:
                print(json.dumps({"mode": "plan-only", "deferred": "reconcile_already_running"}, indent=2))
                return 0
            transport = Transport(args.core, args.node_id)
            vp = VerifiedPlan({"node_id": args.node_id, "desired_id": None, "target_ref": None}, "unknown", "unknown", tuple(), tuple())
            HostOps(state, transport).emit("deferred", vp, reason="reconcile_already_running")
            return 0
        runs = state.read_json(state.state_dir / "reconcile-runs.json", {})
        runs[secrets.token_hex(8)] = {"trigger": args.trigger, "started_at": iso_now()}
        if not args.plan_only:
            state.write_json_0640(state.state_dir / "reconcile-runs.json", runs)
        return converge(args, reconcile_mode=True)


def converge(args: argparse.Namespace, reconcile_mode: bool = False) -> int:
    state = LocalState(pathlib.Path(args.state_root))
    transport = Transport(args.core, args.node_id, pathlib.Path(args.auth_token_path))
    if args.plan_file:
        plan = json.loads(pathlib.Path(args.plan_file).read_text())
    else:
        try:
            plan = transport.get_plan()
            if not args.plan_only:
                state.write_json_0640(state.state_dir / "cached-plan.json", plan)
        except (urllib.error.URLError, TimeoutError):
            if not reconcile_mode:
                raise
            plan = load_cached_plan(state)
            if not plan:
                raise
    def read_idle_snapshot() -> dict[str, Any] | None:
        return json.loads(pathlib.Path(args.idle_snapshot).read_text()) if args.idle_snapshot else None

    idle_snapshot = read_idle_snapshot()
    verified = verify_plan(
        plan,
        node_id=args.node_id,
        key_lookup=default_key_lookup(args.node_id, pathlib.Path(args.plan_key_path)),
        watermarks=state.load_watermarks(),
        target_artifact=getattr(args, "target_artifact", None),
    )
    idle = evaluate_idle(idle_snapshot) if verified.apply_mode == "restart_required" else None
    if args.plan_only:
        print(plan_only_output(verified, idle))
        return 0
    result = execute_plan(verified, HostOps(state, transport), idle_snapshot, read_idle_snapshot)
    return 0 if result in {"applied", "deferred", "rolled_back"} else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="hermes-converger")
    parser.add_argument("--node-id", default=os.environ.get("CHIEF_NODE_ID") or os.uname().nodename.split(".")[0])
    parser.add_argument("--core", default=os.environ.get("CHIEF_CORE_URL", "http://127.0.0.1:8088"))
    parser.add_argument("--plan-key-path", default=os.environ.get("CHIEF_NODE_PLAN_KEY", "/etc/chief/node-plan.key"))
    parser.add_argument("--auth-token-path", default=os.environ.get("CHIEF_NODE_AUTH_TOKEN", "/etc/chief/node-auth.token"))
    parser.add_argument("--state-root", default="/")
    parser.add_argument("--plan-only", "--dry-run", action="store_true")
    parser.add_argument("--plan-file")
    parser.add_argument("--idle-snapshot")
    parser.add_argument("--artifact", dest="target_artifact")
    sub = parser.add_subparsers(dest="command")
    conv = sub.add_parser("converge")
    conv.add_argument("--artifact", dest="target_artifact", default=argparse.SUPPRESS)
    rec = sub.add_parser("reconcile")
    rec.add_argument("--trigger", choices=["boot", "daemon-start"], required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "reconcile":
        return reconcile(args)
    if args.command in {None, "converge"}:
        return converge(args)
    parser.error("unknown command")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
