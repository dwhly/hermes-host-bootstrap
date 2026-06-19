from __future__ import annotations

import datetime as dt
import json
import pathlib
import sys

import pytest

CHIEF_SPEC_SDK = pathlib.Path("/root/code/chief/chief-spec/sdk/python")
if CHIEF_SPEC_SDK.exists():
    sys.path.insert(0, str(CHIEF_SPEC_SDK))

from chief_spec.validation import validate_event

from hermes_converger import core


KEY = b"test-plan-key"
NODE = "h-do1"
NOW = dt.datetime(2026, 6, 19, 0, 0, 0, tzinfo=dt.UTC)
FIXTURES = pathlib.Path(__file__).parent / "fixtures"


def refresh_plan_auth(plan):
    auth = plan["auth"][0]
    plan["plan_digest"] = core.sha256_digest(core.canonical_json(core.plan_digest_payload(plan)))
    auth["plan_digest"] = plan["plan_digest"]
    auth["signature"] = {
        "alg": "HMAC-SHA256",
        "key_id": f"node:{NODE}:plan-v1",
        "value": core.sign_plan_fields(auth, KEY),
    }
    return plan


def make_plan(**row_overrides):
    issued_at = row_overrides.pop("issued_at", (NOW - dt.timedelta(seconds=10)).isoformat().replace("+00:00", "Z"))
    plan = {
        "node_id": NODE,
        "issued_at": issued_at,
        "desired": [
            {
                "desired_id": "des_01",
                "node_id": NODE,
                "artifact": "hermes-node",
                "apply_mode": "restart_required",
                "target_ref": "abc1234",
                "target": {"ref": "abc1234", "kind": "git", "repo": "hermes-node", "source": "test"},
                "allowed_executor_action": "converge",
                "current_fold": {},
            }
        ],
        "plan_digest": None,
        "auth": [
            {
                "desired_id": "des_01",
                "node_id": NODE,
                "target_ref": "abc1234",
                "plan_digest": None,
                "issued_at": issued_at,
                "signature": None,
            }
        ],
        "signature": None,
    }
    row = plan["desired"][0]
    row.update(row_overrides)
    if "target_ref" in row_overrides:
        row["target"] = {**row.get("target", {}), "ref": row["target_ref"]}
    auth = plan["auth"][0]
    auth["desired_id"] = row["desired_id"]
    auth["node_id"] = row["node_id"]
    auth["target_ref"] = row["target_ref"]
    return refresh_plan_auth(plan)


def lookup(key_id):
    return KEY if key_id == f"node:{NODE}:plan-v1" else None


def test_resolve_tool_uses_shutil_which(monkeypatch):
    monkeypatch.setattr(core.shutil, "which", lambda name: f"/custom/bin/{name}")

    assert core._resolve_tool("uv") == "/custom/bin/uv"


def test_resolve_tool_uses_fixed_fallback_when_which_missing(monkeypatch):
    expected = "/usr/local/bin/uv"
    monkeypatch.setattr(core.shutil, "which", lambda name: None)
    monkeypatch.setattr(core.os.path, "isfile", lambda path: path == expected)
    monkeypatch.setattr(core.os, "access", lambda path, mode: path == expected and mode == core.os.X_OK)

    assert core._resolve_tool("uv") == expected


def test_resolve_tool_raises_clear_error_when_missing(monkeypatch):
    monkeypatch.setattr(core.shutil, "which", lambda name: None)
    monkeypatch.setattr(core.os.path, "isfile", lambda path: False)
    monkeypatch.setattr(core.os, "access", lambda path, mode: False)

    with pytest.raises(core.ConvergerError, match="tool_not_found:uv"):
        core._resolve_tool("uv")


def verify(plan, watermarks=None, target_artifact=None):
    return core.verify_plan(plan, node_id=NODE, key_lookup=lookup, watermarks=watermarks or {}, now=NOW, target_artifact=target_artifact)


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
        (lambda p: p["auth"][0]["signature"].update(value="AAAA"), "bad_signature"),
        (lambda p: p["auth"][0].update(issued_at=(NOW - dt.timedelta(seconds=600)).isoformat().replace("+00:00", "Z")), "stale_plan"),
        (lambda p: p["auth"][0].update(issued_at=(NOW + dt.timedelta(seconds=61)).isoformat().replace("+00:00", "Z")), "future_plan"),
        (lambda p: p["desired"][0].update(target_ref="changed-after-digest"), "plan_digest_mismatch"),
        (lambda p: p["auth"][0]["signature"].update(key_id="node:h-do1:plan-v2"), "unknown_key_id"),
        (lambda p: p["desired"][0].update(artifact="unknown"), "artifact_not_allowlisted:unknown"),
    ],
)
def test_plan_verification_rejects_failure_modes(mutate, reason):
    plan = make_plan()
    mutate(plan)
    if reason not in {"bad_signature", "plan_digest_mismatch", "unknown_key_id"}:
        refresh_plan_auth(plan)
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
                "desired_id": current["desired"][0]["desired_id"],
                "target_ref": current["desired"][0]["target_ref"],
                "issued_at": current["auth"][0]["issued_at"],
                "plan_digest": current["auth"][0]["plan_digest"],
            }
        }
    }
    assert verify(current, identical_mark).raw["target_ref"] == current["desired"][0]["target_ref"]


def test_live_shape_verifies_and_selects_single_desired_row():
    plan = make_plan()
    verified = verify(plan)
    assert verified.artifact == "hermes-node"
    assert verified.raw["desired_id"] == "des_01"
    assert verified.raw["target_ref"] == "abc1234"
    assert verified.restart_units == ("chief-node.service",)
    assert verified.affected_processes == ("chief-node.service",)


def test_multi_desired_requires_target_artifact_and_selects_matching_row():
    plan = make_plan()
    harness = {
        **plan["desired"][0],
        "desired_id": "des_02",
        "artifact": "harness",
        "target_ref": "def5678",
        "target": {"ref": "def5678", "kind": "git", "repo": "harness", "source": "test"},
    }
    plan["desired"].append(harness)
    plan["auth"].append(
        {
            "desired_id": "des_02",
            "node_id": NODE,
            "target_ref": "def5678",
            "plan_digest": None,
            "issued_at": plan["auth"][0]["issued_at"],
            "signature": None,
        }
    )
    refresh_plan_auth(plan)
    plan["auth"][1]["plan_digest"] = plan["plan_digest"]
    plan["auth"][1]["signature"] = {
        "alg": "HMAC-SHA256",
        "key_id": f"node:{NODE}:plan-v1",
        "value": core.sign_plan_fields(plan["auth"][1], KEY),
    }

    with pytest.raises(core.VerificationError, match="artifact_required_for_multi_desired_plan"):
        verify(plan)

    verified = verify(plan, target_artifact="harness")
    assert verified.artifact == "harness"
    assert verified.restart_units == ("chief-loop-watchdog.service",)


def test_missing_or_mismatched_auth_entry_rejected_fail_closed():
    plan = make_plan()
    plan["auth"] = []
    with pytest.raises(core.VerificationError, match="auth_missing_for_desired:des_01"):
        verify(plan)

    plan = make_plan()
    plan["auth"][0]["target_ref"] = "def5678"
    plan["auth"][0]["signature"]["value"] = core.sign_plan_fields(plan["auth"][0], KEY)
    with pytest.raises(core.VerificationError, match="auth_target_ref_mismatch"):
        verify(plan)


def test_captured_live_fixture_shape_verifies_after_resigning_current_auth():
    plan = json.loads((FIXTURES / "cv_plan3.json").read_text())
    issued_at = (NOW - dt.timedelta(seconds=10)).isoformat().replace("+00:00", "Z")
    plan["issued_at"] = issued_at
    plan["auth"][0]["issued_at"] = issued_at
    refresh_plan_auth(plan)

    verified = verify(plan, target_artifact="hermes-node")
    assert verified.artifact == "hermes-node"
    assert verified.raw["desired_id"] == "des_6c6b2517eadb"
    assert verified.raw["target_ref"] == "d4dddc1890eb9e5b68f71c59e35ce7eec03721a2"


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
    def emit(self, envelope):
        pass


def test_plan_supplied_reload_targets_are_ignored_for_fixed_artifact_map(tmp_path, monkeypatch):
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
    monkeypatch.setattr(core, "_resolve_tool", lambda name: name)
    monkeypatch.setattr(core.subprocess, "run", lambda cmd, *a, **kw: calls.append(cmd))

    ops.record_reload_and_signal(verified)

    assert calls == [["systemctl", "kill", "-s", "HUP", "chief-node.service"]]
    data = json.loads((tmp_path / "var/lib/chief/converger/reload-signal-times.json").read_text())
    assert set(data) == {"chief-node.service"}
    assert set(data["chief-node.service"]) == {"config"}


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
    monkeypatch.setattr(core, "_resolve_tool", lambda name: name)
    monkeypatch.setattr(core.subprocess, "run", lambda cmd, *a, **kw: calls.append(cmd))

    with pytest.raises(core.ConvergerError, match="target_ref_not_git_sha:main;rm-rf"):
        ops.fetch(verified)

    assert ["git", "fetch", "--all", "--prune"] in calls
    assert not any(cmd[:2] == ["git", "checkout"] for cmd in calls)


def spec_verification(target_ref="abc1234", reload_signal_at="2026-06-19T00:00:01Z"):
    return {
        "method": "runtime_stamp",
        "runtime_source": {"kind": "file", "path": "/run/chief/runtime/chief-node.service/hermes-node.json", "source": "runtime-stamp"},
        "observed_at": "2026-06-19T00:00:05Z",
        "stamp_freshness_evidence": {
            "reload_signal_at": reload_signal_at,
            "stamp_mtime": "2026-06-19T00:00:05Z",
            "pid": 1234,
            "process_start_time": "2026-06-19T00:00:03Z",
            "monotonic_nonce": 987654321,
            "loaded_ref": target_ref,
        },
    }


@pytest.mark.parametrize(
    "event_name,extra",
    [
        ("started", {"trigger": "operator"}),
        ("fetched", {}),
        ("applied", {"verification": spec_verification()}),
        ("failed", {"reason": "steady_health_timeout"}),
        ("deferred", {"reason": "active_directive", "idle_snapshot": {"active_directives": ["dir_01"]}}),
        ("rolled_back", {"rollback_ref": "def5678", "verification": spec_verification("def5678")}),
    ],
)
def test_convergence_event_envelopes_validate_against_chief_spec(event_name, extra):
    verified = verify(make_plan(force=True))
    envelope = core.build_convergence_envelope(event_name, verified, observed_at="2026-06-19T00:00:02Z", **extra)

    validate_event(envelope)
    assert envelope["type"] == f"hermes.fleet.convergence.{event_name}"
    assert envelope["source"] == f"hermes-converger://{NODE}"
    assert envelope["entityid"] == f"ent_node_{NODE}"
    assert envelope["actorid"] == f"act_node_{NODE}"
    assert envelope["data"]["executor"]["instance"].startswith(f"{NODE}/cnv_")


def test_convergence_id_is_stable_across_one_run():
    verified = verify(make_plan())
    started = core.build_convergence_envelope("started", verified, observed_at="2026-06-19T00:00:02Z")
    fetched = core.build_convergence_envelope("fetched", verified, observed_at="2026-06-19T00:00:03Z")
    applied = core.build_convergence_envelope("applied", verified, observed_at="2026-06-19T00:00:06Z", verification=spec_verification())

    assert started["data"]["convergence_id"] == fetched["data"]["convergence_id"] == applied["data"]["convergence_id"]


def test_transport_emit_posts_observations_endpoint(tmp_path, monkeypatch):
    verified = verify(make_plan())
    envelope = core.build_convergence_envelope("started", verified, observed_at="2026-06-19T00:00:02Z")
    captured = {}

    class Response:
        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def read(self):
            return b"{}"

    def fake_urlopen(req, timeout):
        captured["url"] = req.full_url
        captured["body"] = json.loads(req.data.decode("utf-8"))
        captured["timeout"] = timeout
        return Response()

    monkeypatch.setattr(core.urllib.request, "urlopen", fake_urlopen)

    core.Transport("http://core.example", NODE, token_path=tmp_path / "missing.token").emit(envelope)

    assert captured["url"] == "http://core.example/v1/observations"
    assert captured["body"]["type"] == "hermes.fleet.convergence.started"
