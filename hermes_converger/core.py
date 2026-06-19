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
import re
import secrets
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Callable


ALLOWLIST = {"chief", "hermes-node", "harness", "config", "remits", "theme"}
LIVE_PATCH = {"config", "remits", "theme"}
RESTART_REQUIRED = {"chief", "hermes-node", "harness"}
SUPERVISED_PROCESS_ALLOWLIST = {"chief-node.service", "chief-loop-watchdog.service", "chief-stack-core-1"}
ARTIFACT_PROCESS_MAP = {
    "chief": (("chief-stack-core-1",), ("chief-stack-core-1",)),
    "hermes-node": (("chief-node.service",), ("chief-node.service",)),
    "harness": (("chief-loop-watchdog.service",), ("chief-loop-watchdog.service",)),
    "config": (tuple(), ("chief-node.service",)),
    "remits": (tuple(), ("chief-node.service",)),
    "theme": (tuple(), ("chief-node.service",)),
}
GIT_REF_RE = re.compile(r"^[0-9a-f]{7,40}$")
DEFAULT_FRESHNESS_S = 600
MAX_FUTURE_S = 60
LEASE_TTL_S = 300
IDLE_LIMITS_S = {
    "directive": 30,
    "lease": 15,
    "heartbeat": 30,
    "subprocess": 10,
    "loop_lock": 10,
}


class ConvergerError(Exception):
    pass


class VerificationError(ConvergerError):
    pass


class Deferred(ConvergerError):
    def __init__(self, reason: str, snapshot: dict[str, Any] | None = None):
        super().__init__(reason)
        self.reason = reason
        self.snapshot = snapshot or {}


def utcnow() -> dt.datetime:
    return dt.datetime.now(dt.UTC)


def parse_time(value: str) -> dt.datetime:
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    parsed = dt.datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.UTC)
    return parsed.astimezone(dt.UTC)


def iso_now() -> str:
    return utcnow().replace(microsecond=0).isoformat().replace("+00:00", "Z")


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
                PlanStep("acquire_convergence_lease", {"ttl_s": LEASE_TTL_S, "lock": f"/run/chief/convergence/{plan.raw['node_id']}.lock"}, True),
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
        self.run_dir = self._path("/run/chief/convergence")

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

    def emit(self, event_type: str, payload: dict[str, Any]) -> None:
        url = f"{self.core}/v1/fleet/events"
        body = json.dumps({"type": event_type, **payload}).encode("utf-8")
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
        payload = {
            "node_id": plan.raw["node_id"],
            "artifact": plan.artifact,
            "desired_id": plan.raw["desired_id"],
            "target_ref": plan.raw["target_ref"],
            "convergence_id": plan.raw.get("convergence_id"),
            "at": iso_now(),
            **extra,
        }
        self.transport.emit(f"hermes.fleet.convergence.{event_name}", payload)

    def fetch(self, plan: VerifiedPlan) -> None:
        self.journal_before("fetch", {"artifact": plan.artifact, "target_ref": plan.raw["target_ref"]})
        # Local destinations are fixed by artifact; actual source sync is intentionally typed.
        path = self.artifact_path(plan.artifact)
        subprocess.run(["git", "fetch", "--all", "--prune"], cwd=path, check=True)
        if plan.artifact in RESTART_REQUIRED:
            target_ref = str(plan.raw["target_ref"])
            validate_git_ref(target_ref)
            subprocess.run(["git", "checkout", "--detach", target_ref], cwd=path, check=True)

    def artifact_path(self, artifact: str) -> str:
        mapping = {
            "chief": "/root/code/chief",
            "hermes-node": "/root/code/chief/hermes-node",
            "harness": "/root/code/chief/harness",
            "config": "/etc/chief/config",
            "remits": "/etc/chief/remits",
            "theme": "/etc/chief/theme",
        }
        return mapping[artifact]

    def install_restart_required(self, plan: VerifiedPlan) -> None:
        self.journal_before("install", {"artifact": plan.artifact})
        if plan.artifact == "hermes-node":
            subprocess.run(
                ["uv", "pip", "install", "--python", ".venv/bin/python", "-q", "-e", "../chief-spec/sdk/python", "-e", "."],
                cwd="/root/code/chief/hermes-node",
                check=True,
            )

    def restart_units(self, plan: VerifiedPlan) -> None:
        for unit in plan.restart_units:
            validate_supervised_process(unit, action="restart_unit")
            self.journal_before("restart", {"unit": unit})
            if unit.endswith(".service"):
                subprocess.run(["systemctl", "restart", unit], check=True)
            else:
                subprocess.run(["docker", "restart", unit], check=True)

    def record_reload_and_signal(self, plan: VerifiedPlan) -> str:
        for process in plan.affected_processes:
            validate_supervised_process(process, action="reload_target")
        reload_at = iso_now()
        path = self.state.state_dir / "reload-signal-times.json"
        times = self.state.read_json(path, {})
        for process in plan.affected_processes:
            times.setdefault(process, {})[plan.artifact] = reload_at
        self.journal_before("record_reload_signal_at", {"path": str(path), "reload_signal_at": reload_at})
        self.state.write_json_0640(path, times)
        for process in plan.affected_processes:
            self.journal_before("signal_reload", {"process": process})
            if process.endswith(".service"):
                subprocess.run(["systemctl", "kill", "-s", "HUP", process], check=True)
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
    roots = [pathlib.Path("/run/chief/runtime")]
    tmp = os.environ.get("TMPDIR")
    if tmp:
        roots.append(pathlib.Path(tmp) / "chief/runtime")
    min_time = parse_time(signal_at) if signal_at else None
    for root in roots:
        if not root.exists():
            continue
        for stamp in root.glob(f"*/{artifact}.json"):
            try:
                data = json.loads(stamp.read_text())
            except (OSError, json.JSONDecodeError):
                continue
            observed = data.get("observed_at") or data.get("written_at")
            if data.get("loaded_ref") != target_ref or data.get("health") not in {None, "healthy"}:
                continue
            if min_time and (not observed or parse_time(str(observed)) <= min_time):
                continue
            return {"method": "runtime_stamp", "source": str(stamp), "loaded_ref": target_ref, "observed_at": observed}
    return None


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
        subprocess.run(["git", "checkout", disk_ref], cwd=ops.artifact_path(plan.artifact), check=True)
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
