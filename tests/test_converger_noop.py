"""Periodic convergence uses live local proof; all OS mutations are fixtures."""
from __future__ import annotations

import dataclasses
import datetime as dt
import json
import os
import pathlib
from types import SimpleNamespace

import pytest

from hermes_converger import core
from test_converger import KEY, NODE, NOW, fresh_idle_snapshot, lookup, make_plan


@pytest.fixture(params=["launchd", "systemd"])
def host(request, tmp_path, monkeypatch):
    macos = request.param == "launchd"
    h = SimpleNamespace(root=tmp_path, now=NOW, pid=500, processes={}, commands=[], events=[],
                        macos=macos, tz_offset=dt.timedelta(0))
    monkeypatch.setattr(core, "IS_MACOS", macos)
    monkeypatch.setattr(core, "RUN_BASE", "/var/lib" if macos else "/run")
    monkeypatch.setattr(core, "utcnow", lambda: h.now)
    monkeypatch.setattr(core, "_resolve_tool", lambda name: name)
    monkeypatch.setattr(core, "trusted_path", lambda *args, **kwargs: None)
    monkeypatch.setattr(core, "_launchd_target", lambda *args: "gui/502/com.chief.node")
    monkeypatch.setattr(core, "_git_fetch_env", lambda: {})
    monkeypatch.setenv("CHIEF_RUNTIME_USER", "root")
    monkeypatch.setenv("CHIEF_CODE_ROOT", str(tmp_path / "code"))
    monkeypatch.setenv("HERMES_RUNTIME_STAMP_DIR", str(tmp_path / "runtime"))
    monkeypatch.setattr(core.time, "sleep", lambda seconds: pytest.fail("runtime proof missed"))
    h.state = core.LocalState(tmp_path)

    def emit(event):
        core.validate_envelope(event)
        h.events.append(event)

    h.ops = core.HostOps(h.state, SimpleNamespace(emit=emit))

    def plan(**overrides):
        h.signed = make_plan(issued_at=(h.now - dt.timedelta(seconds=1)).isoformat(), **overrides)
        h.plan = dataclasses.replace(core.verify_plan(h.signed, node_id=NODE, key_lookup=lookup,
            watermarks=h.state.load_watermarks(), now=h.now), trigger="periodic")
        # This is the real self-runtime writer's directory on *both* platforms.
        h.stamp = tmp_path / "runtime/chief-node.service" / (h.plan.artifact + ".json")
        return h.plan

    h.make_plan = plan

    def publish():
        h.pid += 1
        h.processes[h.pid] = (h.now.replace(microsecond=0), "S")
        # The acknowledgment is newer than the signal at whole-second precision.
        h.now = h.now.replace(microsecond=500000)
        h.stamp.parent.mkdir(parents=True, exist_ok=True)
        h.stamp.write_text(json.dumps({"loaded_ref": h.plan.raw["target_ref"], "pid": h.pid,
            "monotonic_nonce": h.pid, "process_start_time": h.processes[h.pid][0].isoformat(),
            "written_at": h.now.isoformat()}))
        os.utime(h.stamp, (h.now.timestamp(), h.now.timestamp()))

    h.publish = publish

    def command(cmd, **kwargs):
        h.commands.append(cmd)
        stdout = ""
        if cmd[0] == "ps":
            started, status = h.processes[int(cmd[-1])]
            if kwargs.get("env", {}).get("TZ") == "UTC":
                started -= h.tz_offset
            stdout = started.strftime("%a %b %d %H:%M:%S %Y") + " " + status + "\n"
        elif cmd[:2] in (["launchctl", "kickstart"], ["systemctl", "restart"], ["systemctl", "kill"]):
            publish()
        return SimpleNamespace(returncode=0, stdout=stdout, stderr="")

    monkeypatch.setattr(core.subprocess, "run", command)

    def kill(pid, sig):
        assert sig == 0, "only a read-only process-existence probe is allowed"
        if pid not in h.processes:
            raise ProcessLookupError(pid)

    monkeypatch.setattr(core.os, "kill", kill)
    real_read = pathlib.Path.read_text
    boot = int((NOW - dt.timedelta(days=1)).timestamp())

    def read(path, *args, **kwargs):
        if str(path) == "/proc/stat":
            return f"btime {boot}\n"
        if path.parent.parent == pathlib.Path("/proc") and path.name == "stat":
            started, status = h.processes[int(path.parent.name)]
            ticks = int((started.timestamp() - boot) * os.sysconf("SC_CLK_TCK"))
            return f"{path.parent.name} (chief node) {status} " + "0 " * 18 + str(ticks)
        return real_read(path, *args, **kwargs)

    monkeypatch.setattr(pathlib.Path, "read_text", read)
    return h


@pytest.fixture(params=["restart_required", "live_patch"])
def applied(host, request):
    host.mode = request.param
    host.artifact = "hermes-node" if host.mode == "restart_required" else "theme"
    host.make_plan(artifact=host.artifact, apply_mode=host.mode)
    assert core.execute_plan(host.plan, host.ops, fresh_idle_snapshot()) == "applied", [
        (event["type"], event["data"].get("reason")) for event in host.events]
    assert ["git", "fetch", "--all", "--prune"] in host.commands
    expected = (["launchctl", "kickstart", "-k", "gui/502/com.chief.node"] if host.macos else
        (["systemctl", "restart", "chief-node.service"] if host.mode == "restart_required" else
         ["systemctl", "kill", "-s", "HUP", "chief-node.service"]))
    assert expected in host.commands
    assert host.state.load_watermarks()[NODE][host.artifact]["applied"] is True
    host.commands.clear()
    host.events.clear()
    return host


def state_snapshot(host):
    return {str(path): (path.read_bytes(), path.stat().st_mtime_ns)
            for path in host.root.rglob("*") if path.is_file()}


def forbidden(*args, **kwargs):
    pytest.fail("already-converged target attempted idle admission or mutation")


def test_repeated_periodic_checks_do_not_fetch_restart_signal_or_write(applied, monkeypatch):
    h = applied
    before = state_snapshot(h)
    monkeypatch.setattr(core, "evaluate_idle", forbidden)
    monkeypatch.setattr(h.state, "convergence_lease", forbidden)
    monkeypatch.setattr(h.state, "write_json_0640", forbidden)
    for delay in (360, 360, 86400):
        h.now += dt.timedelta(seconds=delay)
        # Core refreshes authorization/fold/digest for the same desired target.
        h.make_plan(artifact=h.artifact, apply_mode=h.mode, current_fold={"refreshed": str(h.now)})
        assert core.execute_plan(h.plan, h.ops, idle_snapshot_reader=forbidden) == "already_converged"
    # Count the actual subprocess boundary. macOS only needs its read-only ps;
    # Linux reads /proc, with zero subprocesses of any kind.
    assert len(h.commands) == (3 if h.macos else 0)
    assert all(cmd[0] == "ps" for cmd in h.commands)
    assert sum(cmd[0] in {"git", "uv", "launchctl", "systemctl"} for cmd in h.commands) == 0
    assert h.events == []
    assert state_snapshot(h) == before


@pytest.mark.parametrize("divergence", ["missing", "rollback", "crashed", "pid_reused", "zombie",
                                        "unhealthy", "wrong_process", "malformed_time", "future", "unacked_reload"])
def test_watermark_without_current_runtime_proof_reconverges(applied, divergence):
    """A prior success is history: crashes/external rollback are real divergence."""
    h = applied
    h.now += dt.timedelta(seconds=360)
    h.make_plan(artifact=h.artifact, apply_mode=h.mode)
    data = json.loads(h.stamp.read_text())
    if divergence == "missing":
        h.stamp.unlink()
    elif divergence == "crashed":
        del h.processes[h.pid]
    elif divergence == "pid_reused":
        h.processes[h.pid] = (h.now, "S")
    elif divergence == "zombie":
        h.processes[h.pid] = (h.processes[h.pid][0], "Z")
    elif divergence == "wrong_process":
        wrong = h.stamp.parent.with_name("unrelated.service")
        wrong.mkdir()
        h.stamp.rename(wrong / h.stamp.name)
    elif divergence == "unacked_reload":
        h.state.write_json_0640(h.state.state_dir / "reload-signal-times.json",
                               {"chief-node": {h.artifact: h.now.isoformat()}})
    else:
        data.update({"rollback": {"loaded_ref": "def5678"}, "unhealthy": {"health": "failed"},
                     "malformed_time": {"written_at": "bad"},
                     "future": {"written_at": (h.now + dt.timedelta(seconds=1)).isoformat()}}[divergence])
        h.stamp.write_text(json.dumps(data))
        os.utime(h.stamp, (h.now.timestamp(), h.now.timestamp()))
    assert core.execute_plan(h.plan, h.ops, fresh_idle_snapshot()) == "applied"
    assert sum(cmd[:2] == ["git", "fetch"] for cmd in h.commands) == 1
    assert sum(cmd[:2] in (["launchctl", "kickstart"], ["systemctl", "restart"], ["systemctl", "kill"])
               for cmd in h.commands) == 1
    assert h.events[-1]["type"] == "hermes.fleet.convergence.applied"


@pytest.mark.parametrize("desired_id,target_ref", [("des_02", "def5678"), ("des_02", "abc1234"),
                                                  ("des_01", "def5678")])
def test_new_desired_or_target_converges_normally(applied, desired_id, target_ref):
    h = applied
    h.now += dt.timedelta(seconds=360)
    h.make_plan(artifact=h.artifact, apply_mode=h.mode, desired_id=desired_id, target_ref=target_ref)
    assert core.execute_plan(h.plan, h.ops, fresh_idle_snapshot()) == "applied"
    assert sum(cmd[:2] == ["git", "fetch"] for cmd in h.commands) == 1
    mark = h.state.load_watermarks()[NODE][h.artifact]
    assert (mark["desired_id"], mark["target_ref"]) == (desired_id, target_ref)


@pytest.mark.parametrize("watermark", ["missing", "other_node", "other_artifact", "rolled_back", "legacy"])
def test_runtime_proof_also_requires_exact_successful_watermark(applied, watermark):
    h = applied
    marks = h.state.load_watermarks()
    if watermark == "missing":
        marks = {}
    elif watermark == "other_node":
        marks = {"other-node": marks[NODE]}
    elif watermark == "other_artifact":
        marks[NODE]["config"] = marks[NODE].pop(h.artifact)
    elif watermark == "rolled_back":
        h.state.update_watermark(h.plan, applied=False)
        marks = h.state.load_watermarks()
    else:
        marks[NODE][h.artifact].pop("applied")
    h.state.write_json_0640(h.state.state_dir / "desired-watermarks.json", marks)
    h.now += dt.timedelta(seconds=360)
    h.make_plan(artifact=h.artifact, apply_mode=h.mode)
    expected = "already_converged" if watermark == "legacy" else "applied"
    assert core.execute_plan(h.plan, h.ops, fresh_idle_snapshot()) == expected


def test_every_affected_process_needs_proof(applied):
    h = applied
    plan = dataclasses.replace(h.plan, affected_processes=("chief-node", "chief-loop-watchdog"))
    assert core.already_converged(plan, h.state) is False
    other = h.stamp.parent.with_name("chief-loop-watchdog.service")
    other.mkdir()
    copy = other / h.stamp.name
    copy.write_bytes(h.stamp.read_bytes())
    os.utime(copy, (h.now.timestamp(), h.now.timestamp()))
    assert core.already_converged(plan, h.state) is True


def test_process_identity_uses_platform_timestamp_encoding(host):
    host.make_plan()
    host.publish()
    host.state.update_watermark(host.plan)
    # Existing node code labels the local ps wall time UTC. On a UTC+8 host
    # this identity is later than written_at, but still names the same process.
    host.tz_offset = dt.timedelta(hours=8)
    started = host.processes[host.pid][0] + (host.tz_offset if host.macos else dt.timedelta(0))
    host.processes[host.pid] = (started, "S")
    data = json.loads(host.stamp.read_text())
    data["process_start_time"] = started.isoformat()
    host.stamp.write_text(json.dumps(data))
    os.utime(host.stamp, (host.now.timestamp(), host.now.timestamp()))
    assert core.already_converged(host.plan, host.state)


def test_cli_returns_success_without_idle_or_mutation(applied, monkeypatch):
    h = applied
    h.now += dt.timedelta(seconds=360)
    h.make_plan(artifact=h.artifact, apply_mode=h.mode)
    planfile, key = h.root / "plan.json", h.root / "key"
    planfile.write_text(json.dumps(h.signed))
    key.write_bytes(KEY)
    monkeypatch.setattr(core, "read_idle_snapshot", forbidden)
    monkeypatch.setattr(core.Transport, "emit", forbidden)
    monkeypatch.setenv("CHIEF_PULSE_TRIGGER", "periodic")
    assert core.main(["--node-id", NODE, "--core", "http://fixture.invalid", "--state-root", str(h.root),
                      "--plan-key-path", str(key), "--plan-file", str(planfile),
                      "converge"]) == 0
    assert all(cmd[0] == "ps" for cmd in h.commands)
