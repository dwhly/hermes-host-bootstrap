from types import SimpleNamespace
import json
import time

import pytest
from hermes_converger import core, supervisor as sup


@pytest.fixture
def mac(monkeypatch):
    monkeypatch.setattr(core, "IS_MACOS", True)
    monkeypatch.setattr(sup, "sys_platform", lambda: "darwin")
    monkeypatch.delenv("SUDO_UID", raising=False)
    monkeypatch.delenv("CHIEF_RUNTIME_USER", raising=False)
    monkeypatch.setattr(core, "_launch_agent_plist_owner_uid", lambda label: 502)
    monkeypatch.setattr(sup, "_resolve_tool", lambda name: name)
    calls = []
    def run(cmd, **kwargs):
        calls.append(cmd)
        return SimpleNamespace(returncode=0, stdout="state = running" if cmd[0] == "launchctl" else '[{"State":{"Running":true}}]')
    monkeypatch.setattr(sup.subprocess, "run", run)
    return calls


@pytest.mark.parametrize("token", ["chief-node.service", "chief-node"])
def test_macos_node_status_restart_quarantine_same_gui_target(mac, token):
    status = sup.process_status(token)
    assert status["target"] == "gui/502/com.chief.node"
    sup.restart(status["target"], status["manager"])
    sup.enter_crash_looping(status["target"], status["manager"])
    assert mac == [["launchctl", "print", "gui/502"],
                   ["launchctl", "print", "gui/502/com.chief.node"],
                   ["launchctl", "kickstart", "-k", "gui/502/com.chief.node"],
                   ["launchctl", "disable", "gui/502/com.chief.node"],
                   ["launchctl", "bootout", "gui/502/com.chief.node"]]


def test_mac_docker_and_system_watchdog(mac):
    for token in ("chief-core", "chief-loop-watchdog.service"):
        status = sup.process_status(token)
        sup.restart(status["target"], status["manager"])
    assert mac == [["docker", "inspect", "chief-stack-core-1"],
                   ["docker", "restart", "chief-stack-core-1"],
                   ["launchctl", "print", "system/com.chief.loop-watchdog"],
                   ["launchctl", "kickstart", "-k", "system/com.chief.loop-watchdog"]]


def test_linux_unchanged(monkeypatch):
    monkeypatch.setattr(core, "IS_MACOS", False)
    monkeypatch.setattr(sup, "sys_platform", lambda: "linux")
    calls = []
    monkeypatch.setattr(sup, "systemd_status", lambda u: calls.append(("systemd", u)) or {"manager": "systemd"})
    monkeypatch.setattr(sup, "docker_status", lambda u: calls.append(("docker", u)) or {"manager": "docker"})
    for unit in ("chief-node.service", "chief-loop-watchdog.service", "chief-stack-core-1"):
        assert sup.process_status(unit)["target"] == unit
    assert calls == [("systemd", "chief-node.service"), ("systemd", "chief-loop-watchdog.service"), ("docker", "chief-stack-core-1")]


def test_unknown_rejected_before_subprocess(mac):
    with pytest.raises(core.ConvergerError, match="not_allowlisted"):
        sup.process_status("com.evil.root")
    assert mac == []


def test_no_gui_defers(mac, monkeypatch):
    monkeypatch.setattr(sup.subprocess, "run", lambda *a, **k: SimpleNamespace(returncode=113))
    assert sup.process_status("chief-node")["deferred"] == "gui_unavailable"


@pytest.mark.parametrize("active,new_budget,action", [(True,False,None), (False,False,"restart"), (False,True,"quarantine")])
def test_old_mac_budget_cannot_quarantine_real_node(tmp_path, monkeypatch, mac, active, new_budget, action):
    allow = tmp_path / "allow.json"
    allow.write_text('{"units":["chief-node.service"]}')
    budget_key = "launchd:gui/502/com.chief.node" if new_budget else "chief-node.service"
    state = tmp_path / "supervisor-restarts.json"
    state.write_text(json.dumps({budget_key: [time.time()] * 5}))
    monkeypatch.setattr(sup, "process_status", lambda _: {"manager":"launchd", "target":"gui/502/com.chief.node", "active":active})
    actions = []
    monkeypatch.setattr(sup, "restart", lambda *a: actions.append("restart"))
    monkeypatch.setattr(sup, "enter_crash_looping", lambda *a: actions.append("quarantine"))
    monkeypatch.setattr(sup.SupervisorTransport, "emit_health", lambda *a: None)
    args = SimpleNamespace(allowlist=str(allow), state_dir=str(tmp_path), core="http://core", node_id="h-air", auth_token_path=str(tmp_path/"token"))
    assert sup.supervise_once(args) == 0
    assert actions == ([action] if action else [])
    if action == "restart":
        assert len(json.loads(state.read_text())["launchd:gui/502/com.chief.node"]) == 1
