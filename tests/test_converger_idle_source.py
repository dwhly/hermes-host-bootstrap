"""Node-attested idle admission, using private files and fake service controls."""
from __future__ import annotations

import contextlib
import datetime as dt
import json
import os
from types import SimpleNamespace
from urllib.parse import parse_qs, urlsplit

import pytest

from hermes_converger import core, runtime
from test_converger import KEY, NODE, NOW, make_plan, refresh_plan_auth, verify


def node_idle(status="idle", age=0, **evidence):
    return {"status": status, "checked_at": (NOW - dt.timedelta(seconds=age)).isoformat(),
            "evidence": {"owned_active_directives": [], "held_leases": [], "work_subprocesses": [], **evidence}}


@pytest.fixture
def idle_file(tmp_path, monkeypatch):
    root = tmp_path / "runtime"
    root.mkdir(mode=0o770)
    monkeypatch.setattr(core, "runtime_stamp_roots", lambda: [root])
    monkeypatch.setattr(core, "utcnow", lambda: NOW)
    return root / "idle.json"


def provenance(event):
    return {key: values[0] for key, values in parse_qs(urlsplit(event["sourceref"]).query).items()}


@pytest.mark.parametrize("age", [0, 9, 30, 179.9, 180])
def test_fresh_local_attestation_admits_for_full_180_seconds(idle_file, age):
    idle_file.write_text(json.dumps(node_idle(age=age)))
    idle_file.chmod(0o660)  # same-group writers are allowed for attestations
    snapshot = core.read_idle_snapshot(verify(make_plan(current_fold={"idle": node_idle("busy")})))
    assert snapshot["idle_source"] == "local_file"
    assert core.evaluate_idle(snapshot, now=NOW).idle


@pytest.mark.parametrize("kind", ["missing", "stale", "future", "symlink", "dangling", "directory", "fifo",
                                   "malformed", "nested", "utf8", "list", "timestamp", "evidence", "oversize", "status"])
@pytest.mark.parametrize("fallback", [True, False])
def test_unusable_local_falls_through(idle_file, kind, fallback):
    data = node_idle()
    if kind == "stale":
        data = node_idle(age=180.001)
    elif kind == "future":
        data = node_idle(age=-0.001)
    elif kind == "timestamp":
        data["checked_at"] = "invalid"
    elif kind == "evidence":
        data["evidence"] = {"held_leases": False}
    elif kind == "status":
        data["status"] = ["idle"]
    if kind in {"symlink", "dangling"}:
        target = idle_file.with_name("target")
        if kind == "symlink":
            target.write_text(json.dumps(node_idle()))
        idle_file.symlink_to(target)
    elif kind == "directory":
        idle_file.mkdir()
    elif kind == "fifo":
        os.mkfifo(idle_file)
    elif kind == "malformed":
        idle_file.write_text("{")
    elif kind == "nested":
        idle_file.write_text("[" * 2000 + "]" * 2000)
    elif kind == "utf8":
        idle_file.write_bytes(b"\xff")
    elif kind == "list":
        idle_file.write_text("[]")
    elif kind == "oversize":
        idle_file.write_text(json.dumps({**data, "padding": "x" * 65536}))
    elif kind != "missing":
        idle_file.write_text(json.dumps(data))
    plan = verify(make_plan(current_fold={"idle": node_idle()} if fallback else {}))
    snapshot = core.read_idle_snapshot(plan)
    if fallback:
        assert snapshot["idle_source"] == "signed_plan"
        assert core.evaluate_idle(snapshot, now=NOW).idle
    else:
        assert snapshot is None
        assert core.evaluate_idle(snapshot, now=NOW).reason == "coordination_probe_untrusted"


@pytest.mark.parametrize("age,accepted", [(0, True), (180, True), (180.001, False), (-0.001, False)])
def test_signed_plan_freshness_is_checked_at_not_plan_issuance(idle_file, age, accepted):
    plan = verify(make_plan(current_fold={"idle": node_idle(age=age)}))
    snapshot = core.read_idle_snapshot(plan)
    assert core.evaluate_idle(snapshot, now=NOW).idle is accepted
    assert (snapshot or {}).get("idle_source") == ("signed_plan" if accepted else None)


@pytest.mark.parametrize("source", ["local_file", "signed_plan"])
@pytest.mark.parametrize("status", ["busy", "unknown"])
def test_busy_and_unknown_never_admit_even_with_empty_evidence(idle_file, source, status):
    if source == "local_file":
        idle_file.write_text(json.dumps(node_idle(status)))
    plan = verify(make_plan(current_fold={"idle": node_idle(status if source == "signed_plan" else "idle")}))
    snapshot = core.read_idle_snapshot(plan)
    assert snapshot["idle_source"] == source
    assert not core.evaluate_idle(snapshot, now=NOW).idle


@pytest.mark.parametrize("field,reason", [("owned_active_directives", "active_directive"),
                                         ("held_leases", "held_process_lease"),
                                         ("work_subprocesses", "running_work_subprocess")])
def test_nonempty_evidence_vetoes_inconsistent_idle_status(idle_file, field, reason):
    idle_file.write_text(json.dumps(node_idle(**{field: ["work"]})))
    snapshot = core.read_idle_snapshot(verify(make_plan()))
    assert core.evaluate_idle(snapshot, now=NOW).reason == reason


def test_runtime_directory_symlink_falls_through(idle_file):
    root = idle_file.parent
    moved = root.with_name("redirect")
    root.rename(moved)
    root.symlink_to(moved, target_is_directory=True)
    idle_file.write_text(json.dumps(node_idle()))
    snapshot = core.read_idle_snapshot(verify(make_plan(current_fold={"idle": node_idle()})))
    assert snapshot["idle_source"] == "signed_plan"


def test_open_race_cannot_follow_new_leaf_symlink(idle_file, monkeypatch):
    idle_file.write_text(json.dumps(node_idle()))
    real_open = os.open
    def race(path, *args, **kwargs):
        if path == "idle.json":
            idle_file.rename(idle_file.with_name("original"))
            idle_file.symlink_to(idle_file.with_name("original"))
        return real_open(path, *args, **kwargs)
    monkeypatch.setattr(core.os, "open", race)
    assert core.read_idle_snapshot(verify(make_plan())) is None


def test_explicit_legacy_snapshot_takes_precedence_and_keeps_old_limits(idle_file):
    from test_converger import valid_idle_snapshot
    idle_file.write_text(json.dumps(valid_idle_snapshot(heartbeat_age_s=30)))
    snapshot = core.read_idle_snapshot(verify(make_plan(current_fold={"idle": node_idle()})), str(idle_file))
    assert snapshot["idle_source"] == "local_file"
    assert core.evaluate_idle(snapshot, now=NOW).reason == "heartbeat_probe_stale_or_busy"


@pytest.mark.parametrize("change", ["busy", "unknown", "missing", "expires", "fallback_expires", "fallback_busy"])
def test_in_lease_check_rereads_source_and_freshness(idle_file, tmp_path, monkeypatch, change):
    plan = verify(make_plan(current_fold={"idle": node_idle(age=180)} if change.startswith("fallback_") else {}))
    if not change.startswith("fallback_"):
        idle_file.write_text(json.dumps(node_idle(age=180 if change == "expires" else 0)))
    state = core.LocalState(tmp_path)
    events = []
    ops = core.HostOps(state, SimpleNamespace(emit=events.append))
    monkeypatch.setattr(ops, "fetch", lambda plan: pytest.fail("work admitted after idle changed"))

    @contextlib.contextmanager
    def lease(*args):
        if change in {"expires", "fallback_expires"}:
            monkeypatch.setattr(core, "utcnow", lambda: NOW + dt.timedelta(seconds=1))
        elif change == "missing":
            idle_file.unlink()
        else:
            replacement = idle_file.with_suffix(".new")
            replacement.write_text(json.dumps(node_idle("busy" if change == "fallback_busy" else change)))
            replacement.replace(idle_file)
        yield

    monkeypatch.setattr(state, "convergence_lease", lease)
    assert core.execute_plan(plan, ops, idle_snapshot_reader=lambda: core.read_idle_snapshot(plan)) == "deferred"
    assert events[-1]["data"]["reason"] == "accepted_work_after_idle_check"
    expected = "local_file" if change in {"busy", "unknown", "fallback_busy"} else "none"
    assert provenance(events[-1])["idle_source"] == expected
    assert events[-1]["data"]["idle_snapshot"]["idle_source"] == expected


@pytest.mark.parametrize("macos,label", [(True, "launchd"), (False, "systemd")])
def test_executor_label(monkeypatch, macos, label):
    monkeypatch.setattr(core, "IS_MACOS", macos)
    event = core.build_convergence_envelope("started", verify(make_plan()))
    assert event["data"]["executor"]["instance"].endswith("/" + label)


def test_plan_fallback_is_not_read_until_digest_and_hmac_verify(idle_file, tmp_path, monkeypatch):
    signed = make_plan(current_fold={"idle": node_idle("busy")})
    signed["desired"][0]["current_fold"]["idle"] = node_idle()
    planfile, key = tmp_path / "plan", tmp_path / "key"
    key.write_bytes(KEY)
    args = core.build_parser().parse_args(["--node-id", NODE, "--core", "http://fixture.invalid",
        "--state-root", str(tmp_path), "--plan-file", str(planfile), "--plan-key-path", str(key), "converge"])
    monkeypatch.setattr(core, "read_idle_snapshot", lambda *args: pytest.fail("read before authentication"))
    planfile.write_text(json.dumps(signed))
    with pytest.raises(core.VerificationError, match="plan_digest_mismatch"):
        core.converge(args)
    # Recompute the public digest, but retain the old HMAC.
    signed["plan_digest"] = core.sha256_digest(core.canonical_json(core.plan_digest_payload(signed)))
    signed["auth"][0]["plan_digest"] = signed["plan_digest"]
    planfile.write_text(json.dumps(signed))
    with pytest.raises(core.VerificationError, match="bad_signature"):
        core.converge(args)


@pytest.mark.parametrize("source", ["local_file", "signed_plan", "none"])
@pytest.mark.parametrize("trigger", ["periodic", "wake", "boot", "login", "network"])
def test_step0_mac_restart_without_idle_argument(tmp_path, monkeypatch, idle_file, source, trigger):
    """Argv-free runtime -> signed plan -> lease -> fetch/install -> launchd -> proof.

    Only host boundaries (config/paths, OS commands and HTTP) are adapted. The
    actual admission, file readers, execution, event validation and proof run.
    """
    monkeypatch.setattr(core, "IS_MACOS", True)
    monkeypatch.setattr(core, "RUN_BASE", "/var/lib")
    monkeypatch.setattr(core, "mutation_allowed", core.mutation_allowed)
    monkeypatch.setattr(core, "_resolve_tool", lambda name: name)
    monkeypatch.setattr(core, "_launchd_target", lambda *args: "gui/502/com.chief.node")
    monkeypatch.setattr(core, "_git_fetch_env", lambda: {})
    monkeypatch.setenv("CHIEF_RUNTIME_USER", "root")
    monkeypatch.setenv("CHIEF_PULSE_TRIGGER", trigger)
    monkeypatch.setenv("CHIEF_CODE_ROOT", str(tmp_path / "code"))
    signed = make_plan(current_fold={"idle": node_idle(age=120)} if source == "signed_plan" else {})
    signed["wake_qualified"] = True
    refresh_plan_auth(signed)
    if source == "local_file":
        idle_file.write_text(json.dumps(node_idle(age=120)))
    key = tmp_path / "node-plan.key"
    key.write_bytes(KEY)
    config = {"CHIEF_NODE_ID": NODE, "CHIEF_CORE_URL": "http://fixture.invalid", "CHIEF_NODE_PLAN_KEY": str(key)}
    for name, value in config.items():
        monkeypatch.setenv(name, value)
    monkeypatch.setattr(runtime, "load_config", lambda: config)
    monkeypatch.setattr(runtime, "STATE", tmp_path / "step0")
    runtime.STATE.mkdir()
    monkeypatch.setattr(runtime, "trusted_path", lambda *args, **kwargs: None)
    monkeypatch.setattr(runtime, "prepare_runtime_directory", lambda: None)
    monkeypatch.setattr(runtime, "consume_hints", lambda: [])
    monkeypatch.setattr(runtime, "wake_identity", lambda: "fixture-wake")
    monkeypatch.setattr(runtime.os, "uname", lambda: SimpleNamespace(sysname="Darwin"))
    state = core.LocalState(tmp_path)
    monkeypatch.setattr(core, "LocalState", lambda root: state)
    monkeypatch.setattr(core.Transport, "get_plan", lambda self: signed)
    events, commands = [], []
    def emit(self, event):
        core.validate_envelope(event)
        events.append(event)
    monkeypatch.setattr(core.Transport, "emit", emit)
    def command(cmd, **kwargs):
        commands.append(cmd)
        if cmd[0] == "/usr/sbin/ioreg":
            return SimpleNamespace(returncode=0, stdout='"System Capabilities" = 15')
        if cmd[:2] == ["launchctl", "kickstart"]:
            stamp = idle_file.parent / "chief-node.service" / "hermes-node.json"
            stamp.parent.mkdir()
            stamp.write_text(json.dumps({"loaded_ref": "abc1234", "pid": 502, "monotonic_nonce": 1,
                "process_start_time": NOW.isoformat(), "written_at": (NOW + dt.timedelta(seconds=1)).isoformat()}))
            timestamp = (NOW + dt.timedelta(seconds=1)).timestamp()
            os.utime(stamp, (timestamp, timestamp))
        return SimpleNamespace(returncode=0, stdout="", stderr="")
    monkeypatch.setattr(core.subprocess, "run", command)
    monkeypatch.setattr(core.HostOps, "run_artifact", lambda self, cmd, cwd, **kwargs: command(cmd, **kwargs))
    monkeypatch.setattr(core.time, "sleep", lambda seconds: pytest.fail("runtime proof missed"))
    assert runtime._run("converge") == 0
    assert [e["type"].rsplit(".", 1)[-1] for e in events] == (
        ["started", "deferred"] if source == "none" else ["started", "fetched", "applied"])
    for event in events:
        assert provenance(event) == {"trigger": trigger, "idle_source": source}
        assert event["data"]["executor"]["instance"].endswith("/launchd")
    assert events[0]["data"]["trigger"] == ("boot_reconcile" if trigger in {"boot", "login"} else "next_idle")
    if source == "none":
        assert events[-1]["data"]["reason"] == "coordination_probe_untrusted"
        assert not any(cmd[0] in {"git", "uv", "launchctl"} for cmd in commands)
    else:
        assert ["git", "fetch", "--all", "--prune"] in commands
        assert ["git", "checkout", "--detach", "abc1234"] in commands
        assert any(cmd[:3] == ["uv", "pip", "install"] for cmd in commands)
        assert ["launchctl", "kickstart", "-k", "gui/502/com.chief.node"] in commands
        assert events[-1]["data"]["verification"]["method"] == "runtime_stamp"
        assert state.load_watermarks()[NODE]["hermes-node"]["target_ref"] == "abc1234"
