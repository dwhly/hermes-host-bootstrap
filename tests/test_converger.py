from __future__ import annotations

import datetime as dt
import json
import pathlib

import pytest

from hermes_converger import core


KEY = b"test-plan-key"
NODE = "h-do1"
NOW = dt.datetime(2026, 6, 19, 0, 0, 0, tzinfo=dt.UTC)


def make_plan(**overrides):
    plan = {
        "desired_id": "des_01",
        "node_id": NODE,
        "artifact": "hermes-node",
        "apply_mode": "restart_required",
        "target_ref": "abc1234",
        "issued_at": (NOW - dt.timedelta(seconds=10)).isoformat().replace("+00:00", "Z"),
        "affected_processes": ["chief-node.service"],
        "restart_units": ["chief-node.service"],
        "convergence_id": "cnv_01",
    }
    plan.update(overrides)
    plan["plan_digest"] = core.sha256_digest(core.canonical_json(core.plan_digest_payload(plan)))
    plan["signature"] = {
        "alg": "HMAC-SHA256",
        "key_id": f"node:{NODE}:plan-v1",
        "value": core.sign_plan_fields(plan, KEY),
    }
    return plan


def lookup(key_id):
    return KEY if key_id == f"node:{NODE}:plan-v1" else None


def verify(plan, watermarks=None):
    return core.verify_plan(plan, node_id=NODE, key_lookup=lookup, watermarks=watermarks or {}, now=NOW)


def valid_idle_snapshot(**overrides):
    base = {
        "query_ok": True,
        "directive_observed_at": (NOW - dt.timedelta(seconds=1)).isoformat().replace("+00:00", "Z"),
        "lease_observed_at": (NOW - dt.timedelta(seconds=1)).isoformat().replace("+00:00", "Z"),
        "heartbeat_age_s": 1,
        "subprocess_observed_at": (NOW - dt.timedelta(seconds=1)).isoformat().replace("+00:00", "Z"),
        "loop_lock_observed_at": (NOW - dt.timedelta(seconds=1)).isoformat().replace("+00:00", "Z"),
        "active_directives": [],
        "held_leases": [],
        "running_work": False,
        "loop_lock_active": False,
    }
    base.update(overrides)
    return base


def fresh_idle_snapshot(**overrides):
    now = core.utcnow()
    base = {
        "query_ok": True,
        "directive_observed_at": (now - dt.timedelta(seconds=1)).isoformat().replace("+00:00", "Z"),
        "lease_observed_at": (now - dt.timedelta(seconds=1)).isoformat().replace("+00:00", "Z"),
        "heartbeat_age_s": 1,
        "subprocess_observed_at": (now - dt.timedelta(seconds=1)).isoformat().replace("+00:00", "Z"),
        "loop_lock_observed_at": (now - dt.timedelta(seconds=1)).isoformat().replace("+00:00", "Z"),
        "active_directives": [],
        "held_leases": [],
        "running_work": False,
        "loop_lock_active": False,
    }
    base.update(overrides)
    return base


@pytest.mark.parametrize(
    "mutate,reason",
    [
        (lambda p: p["signature"].update(value="AAAA"), "bad_signature"),
        (lambda p: p.update(issued_at=(NOW - dt.timedelta(seconds=600)).isoformat().replace("+00:00", "Z")), "stale_plan"),
        (lambda p: p.update(issued_at=(NOW + dt.timedelta(seconds=61)).isoformat().replace("+00:00", "Z")), "future_plan"),
        (lambda p: p.update(target_ref="changed-after-digest"), "plan_digest_mismatch"),
        (lambda p: p["signature"].update(key_id="node:h-do1:plan-v2"), "unknown_key_id"),
        (lambda p: p.update(artifact="unknown"), "artifact_not_allowlisted:unknown"),
    ],
)
def test_plan_verification_rejects_failure_modes(mutate, reason):
    plan = make_plan()
    mutate(plan)
    if reason not in {"bad_signature", "plan_digest_mismatch", "unknown_key_id"}:
        plan["plan_digest"] = core.sha256_digest(core.canonical_json(core.plan_digest_payload(plan)))
        plan["signature"]["value"] = core.sign_plan_fields(plan, KEY)
    with pytest.raises(core.VerificationError, match=reason):
        verify(plan)


def test_replay_below_watermark_rejected_unless_identical_current():
    current = make_plan()
    mark = {
        NODE: {
            "hermes-node": {
                "desired_id": "newer",
                "target_ref": "newer-ref",
                "issued_at": (NOW - dt.timedelta(seconds=5)).isoformat().replace("+00:00", "Z"),
                "plan_digest": "sha256:newer",
            }
        }
    }
    with pytest.raises(core.VerificationError, match="replay_below_watermark"):
        verify(current, mark)

    identical_mark = {
        NODE: {
            "hermes-node": {
                "desired_id": current["desired_id"],
                "target_ref": current["target_ref"],
                "issued_at": current["issued_at"],
                "plan_digest": current["plan_digest"],
            }
        }
    }
    assert verify(current, identical_mark).raw["target_ref"] == current["target_ref"]


@pytest.mark.parametrize(
    "snapshot,reason",
    [
        ({}, "coordination_probe_untrusted"),
        (valid_idle_snapshot(query_ok=False), "coordination_probe_untrusted"),
        (valid_idle_snapshot(active_directives=["dir"]), "active_directive"),
        (valid_idle_snapshot(heartbeat_age_s=30), "heartbeat_probe_stale_or_busy"),
        (valid_idle_snapshot(lease_observed_at=(NOW - dt.timedelta(seconds=15)).isoformat().replace("+00:00", "Z")), "lease_probe_stale_or_busy"),
    ],
)
def test_idle_fails_closed(snapshot, reason):
    result = core.evaluate_idle(snapshot, now=NOW)
    assert not result.idle
    assert result.reason == reason


class ExplodingOps:
    def emit(self, *args, **kwargs):
        raise AssertionError("emit called")

    def journal_before(self, *args, **kwargs):
        raise AssertionError("journal called")


def test_plan_only_prints_full_plan_and_writes_nothing():
    verified = verify(make_plan())
    idle = core.evaluate_idle(valid_idle_snapshot(), now=NOW)
    output = core.plan_only_output(verified, idle)
    data = json.loads(output)
    assert data["writes"] == "none"
    assert data["emits"] == "none"
    assert data["artifact"] == "hermes-node"
    assert any(step["action"] == "restart" for step in data["steps"])


def test_cli_plan_only_makes_no_state_writes(tmp_path, capsys):
    issued_at = (core.utcnow() - dt.timedelta(seconds=1)).isoformat().replace("+00:00", "Z")
    plan = make_plan(issued_at=issued_at)
    plan_file = tmp_path / "plan.json"
    key_file = tmp_path / "node-plan.key"
    idle_file = tmp_path / "idle.json"
    plan_file.write_text(json.dumps(plan))
    key_file.write_bytes(KEY)
    idle_file.write_text(json.dumps(fresh_idle_snapshot()))

    rc = core.main(
        [
            "--node-id",
            NODE,
            "--core",
            "http://127.0.0.1:9",
            "--plan-key-path",
            str(key_file),
            "--state-root",
            str(tmp_path),
            "--plan-only",
            "--plan-file",
            str(plan_file),
            "--idle-snapshot",
            str(idle_file),
            "converge",
        ]
    )
    assert rc == 0
    assert "restart" in capsys.readouterr().out
    assert not (tmp_path / "var/lib/chief/converger").exists()


class FakeState:
    def __init__(self):
        self.events = []
        self.rollback_attempts = 0
        self.state_dir = pathlib.Path("/missing")

    def update_watermark(self, plan):
        self.events.append(("watermark", plan.artifact))

    def convergence_lease(self, *args, **kwargs):
        class Lease:
            def __enter__(self_inner):
                return {}

            def __exit__(self_inner, *exc):
                return False

        return Lease()

    def read_json(self, path, default):
        return {
            "hermes-node": {
                "disk_ref": "prev",
                "running_ref": "prev",
                "restore_method": "git_checkout+uv_install+systemd_restart",
            }
        }


class FailingOps:
    def __init__(self):
        self.state = FakeState()
        self.emitted = []
        self.rollback_installs = 0

    def emit(self, event_name, plan, **extra):
        self.emitted.append((event_name, extra))

    def fetch(self, plan):
        pass

    def install_restart_required(self, plan):
        self.rollback_installs += 1

    def restart_units(self, plan):
        pass

    def poll_runtime_ack(self, plan, signal_at, timeout_s=30):
        return None

    def journal_before(self, action, detail):
        if action == "rollback":
            self.state.rollback_attempts += 1

    def artifact_path(self, artifact):
        return "/tmp"


def test_restart_failure_attempts_rollback_once_then_stops(monkeypatch):
    verified = verify(make_plan())
    ops = FailingOps()
    monkeypatch.setattr(core.subprocess, "run", lambda *a, **kw: None)
    result = core.execute_plan(verified, ops, fresh_idle_snapshot())
    assert result == "failed"
    assert ops.state.rollback_attempts == 1
    assert [name for name, _ in ops.emitted].count("failed") >= 1
    assert not any(name == "rolled_back" for name, _ in ops.emitted)


class DummyTransport:
    def emit(self, event_type, payload):
        pass


def test_reload_target_not_allowlisted_rejected_before_signal(tmp_path, monkeypatch):
    plan = make_plan(
        artifact="config",
        apply_mode="live_patch",
        target_ref="abcdef0",
        affected_processes=["not-allowed.service"],
        restart_units=[],
    )
    verified = verify(plan)
    ops = core.HostOps(core.LocalState(tmp_path), DummyTransport())
    calls = []
    monkeypatch.setattr(core.subprocess, "run", lambda cmd, *a, **kw: calls.append(cmd))

    with pytest.raises(core.ConvergerError, match="reload_target_not_allowlisted:not-allowed.service"):
        ops.record_reload_and_signal(verified)

    assert calls == []
    assert not (tmp_path / "var/lib/chief/converger/reload-signal-times.json").exists()


class BusyInsideOps:
    def __init__(self):
        self.state = FakeState()
        self.emitted = []
        self.fetched = False
        self.installed = False
        self.restarted = False

    def emit(self, event_name, plan, **extra):
        self.emitted.append((event_name, extra))

    def fetch(self, plan):
        self.fetched = True

    def install_restart_required(self, plan):
        self.installed = True

    def restart_units(self, plan):
        self.restarted = True

    def poll_runtime_ack(self, plan, signal_at, timeout_s=30):
        return {"method": "test", "loaded_ref": plan.raw["target_ref"]}


def test_inside_lease_busy_recheck_defers_before_restart():
    verified = verify(make_plan())
    snapshots = [
        fresh_idle_snapshot(),
        fresh_idle_snapshot(active_directives=["dir_accepted_after_first_check"]),
    ]
    ops = BusyInsideOps()

    result = core.execute_plan(verified, ops, idle_snapshot_reader=lambda: snapshots.pop(0))

    assert result == "deferred"
    assert not ops.fetched
    assert not ops.installed
    assert not ops.restarted
    assert ("watermark", "hermes-node") not in ops.state.events
    assert ops.emitted[-1][0] == "deferred"
    assert ops.emitted[-1][1]["reason"] == "accepted_work_after_idle_check"


def test_malformed_target_ref_rejected_before_git_checkout(tmp_path, monkeypatch):
    verified = verify(make_plan(target_ref="main;rm-rf"))
    ops = core.HostOps(core.LocalState(tmp_path), DummyTransport())
    monkeypatch.setattr(ops, "artifact_path", lambda artifact: str(tmp_path))
    calls = []
    monkeypatch.setattr(core.subprocess, "run", lambda cmd, *a, **kw: calls.append(cmd))

    with pytest.raises(core.ConvergerError, match="target_ref_not_git_sha:main;rm-rf"):
        ops.fetch(verified)

    assert ["git", "fetch", "--all", "--prune"] in calls
    assert not any(cmd[:2] == ["git", "checkout"] for cmd in calls)
