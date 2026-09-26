"""Post-approval regressions, confined to private hosts and fake service controls."""
from __future__ import annotations

import datetime as dt
import json
import os
import pathlib
import shutil
import stat
import subprocess
from types import SimpleNamespace

import pytest

from hermes_converger import core, runtime, security
from test_converger import DummyTransport, NOW, fresh_idle_snapshot, make_plan, verify
from test_currency_fix1 import Host
from test_currency_fix4 import preflight, prepare_preflight, snapshot
from test_currency_step0 import ROOT


@pytest.mark.parametrize('reader', ['hermes-converger', 'chief-node-supervisor'])
def test_minor_2_post_reboot_restart_convergence(tmp_path, monkeypatch, reader):
    host = Host(tmp_path)
    result = host.run()
    assert result.returncode == 0, host.output(result)
    # A healthy reader would normally no-op, even with recent persistent stamps.
    result = host.run(reader)
    assert result.returncode == 0, host.output(result)
    result = host.run(reader)
    assert result.returncode == 0 and 'python=0' in result.stdout, host.output(result)
    volatile = host.root / 'var/run'
    shutil.rmtree(volatile)  # fixture reboot, not just a missing leaf directory
    volatile.mkdir(mode=0o775)
    host.tool('sysctl', "printf 'new-boot\\nnew-wake\\n'")
    result = host.run(reader)
    assert result.returncode == 0, host.output(result)
    runtime_dir = volatile / 'chief/runtime'
    assert (runtime_dir.stat().st_uid, runtime_dir.stat().st_gid,
            stat.S_IMODE(runtime_dir.stat().st_mode)) == (0, os.getgid(), 0o770)
    assert stat.S_IMODE(runtime_dir.parent.stat().st_mode) == 0o750
    assert 'python=0' not in result.stdout

    monkeypatch.delenv('HERMES_RUNTIME_STAMP_DIR', raising=False)
    monkeypatch.setattr(core, 'IS_MACOS', True)
    monkeypatch.setattr(core, 'RUN_BASE', '/var/lib')
    monkeypatch.setattr(core, 'MACOS_RUNTIME_STAMP_DIR', runtime_dir)
    monkeypatch.setattr(core, 'utcnow', lambda: NOW)
    monkeypatch.setattr(core, '_resolve_tool', lambda name: name)
    monkeypatch.setattr(core, '_launchd_target', lambda *a: 'gui/502/com.chief.node')
    state = core.LocalState(host.root)
    ops = core.HostOps(state, DummyTransport())
    events = []
    monkeypatch.setattr(ops, 'emit', lambda name, plan, **kw: events.append((name, kw)))
    monkeypatch.setattr(ops, 'fetch', lambda plan: None)
    monkeypatch.setattr(ops, 'install_restart_required', lambda plan: None)
    plan = verify(make_plan())
    stamp = runtime_dir / 'chief-node/hermes-node.json'
    payload = json.dumps({'loaded_ref': plan.raw['target_ref'], 'health': 'healthy',
        'pid': 502, 'monotonic_nonce': 1, 'process_start_time': NOW.isoformat(),
        'observed_at': (NOW + dt.timedelta(seconds=1)).isoformat()})
    # Use a real login-user process where the runner maps non-root UIDs. The
    # restricted local user namespace maps only root; there the Host fixture's
    # modeled credentials apply, with the group write/traverse modes asserted.
    uid_map = pathlib.Path('/proc/self/uid_map')
    mapped = not uid_map.exists() or any(
        int(row.split()[0]) <= 65534 < int(row.split()[0]) + int(row.split()[2])
        for row in uid_map.read_text().splitlines())
    # /tmp ancestors are outside the virtual host; allow group traversal.
    for ancestor in runtime_dir.parents:
        if ancestor == pathlib.Path('/tmp'):
            break
        ancestor.chmod(ancestor.stat().st_mode | 0o010)
    producer = tmp_path / 'producer.py'
    producer.write_text('import pathlib\np=pathlib.Path(' + repr(str(stamp)) + ')\n'
                        'p.parent.mkdir()\np.write_text(' + repr(payload) + ')\n')
    producer.chmod(0o644)
    real_run = subprocess.run

    def login_user():
        os.setgroups([os.getgid()])
        os.setuid(65534)

    def restart(command, **kwargs):
        if command == ['launchctl', 'print', 'gui/502']:
            return SimpleNamespace(returncode=0)
        assert command == ['launchctl', 'kickstart', '-k', 'gui/502/com.chief.node']
        real_run(['/usr/bin/python3', str(producer)],
                 preexec_fn=login_user if mapped else None, check=True)
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(core.subprocess, 'run', restart)
    monkeypatch.setattr(core.time, 'sleep', lambda seconds: pytest.fail('runtime proof would time out'))
    assert core.execute_plan(plan, ops, fresh_idle_snapshot()) == 'applied', events
    assert stamp.stat().st_uid == (65534 if mapped else 0)
    assert events[-1][1]['verification']['method'] == 'runtime_stamp'
    assert not any(name in {'failed', 'rolled_back'} for name, _ in events)
    assert state.load_watermarks()[plan.raw['node_id']]['hermes-node']['target_ref'] == plan.raw['target_ref']


def provision_fixture(tmp_path, monkeypatch):
    volatile = tmp_path / 'run'
    volatile.mkdir(mode=0o775)
    monkeypatch.setattr(runtime.os, 'uname', lambda: SimpleNamespace(sysname='Darwin'))
    monkeypatch.setattr(runtime.grp, 'getgrnam', lambda name: SimpleNamespace(gr_gid=os.getgid()))
    real_open = os.open

    def local_open(path, *args, **kwargs):
        return real_open(volatile if path == '/var/run' else path, *args, **kwargs)

    monkeypatch.setattr(runtime.os, 'open', local_open)
    return volatile, local_open


@pytest.mark.parametrize('component', ['chief', 'runtime'])
@pytest.mark.parametrize('kind', ['link', 'non-root', 'file', 'fifo'])
def test_minor_2_provisioner_holds_before_chmod_chown(tmp_path, monkeypatch, capsys, component, kind):
    volatile, _ = provision_fixture(tmp_path, monkeypatch)
    parent = volatile
    if component == 'runtime':
        parent = volatile / 'chief'
        parent.mkdir(mode=0o750)
    entry = parent / component
    if kind == 'link':
        target = tmp_path / 'target'
        target.mkdir()
        entry.symlink_to(target)
    elif kind == 'file':
        entry.touch()
    elif kind == 'fifo':
        os.mkfifo(entry)
    else:
        entry.mkdir()
        # Ownership adapter: local user namespaces may map only UID 0.
        real_stat = os.stat

        def nonroot(path, *args, **kwargs):
            info = real_stat(path, *args, **kwargs)
            if path == component and kwargs.get('follow_symlinks') is False:
                return SimpleNamespace(st_uid=65534, st_mode=info.st_mode)
            return info

        monkeypatch.setattr(runtime.os, 'stat', nonroot)
    before = snapshot(volatile)
    monkeypatch.setattr(runtime.os, 'fchmod', lambda *a: pytest.fail('unsafe chmod'))
    monkeypatch.setattr(runtime.os, 'fchown', lambda *a: pytest.fail('unsafe chown'))
    with pytest.raises(security.TrustError, match='unsafe_runtime_directory'):
        runtime.prepare_runtime_directory()
    assert 'HOLD: runtime_directory_unavailable:' in capsys.readouterr().out
    assert snapshot(volatile) == before


def test_minor_2_symlink_swap_cannot_redirect_metadata_changes(tmp_path, monkeypatch, capsys):
    volatile, local_open = provision_fixture(tmp_path, monkeypatch)
    chief = volatile / 'chief'
    chief.mkdir(mode=0o750)
    entry = chief / 'runtime'
    entry.mkdir(mode=0o700)
    target = tmp_path / 'target'
    target.mkdir(mode=0o711)
    before = target.stat()

    def swap(path, *args, **kwargs):
        if path == 'runtime':
            entry.rename(chief / 'original')
            entry.symlink_to(target)
        return local_open(path, *args, **kwargs)

    monkeypatch.setattr(runtime.os, 'open', swap)
    with pytest.raises(OSError):
        runtime.prepare_runtime_directory()
    assert 'HOLD: runtime_directory_unavailable:' in capsys.readouterr().out
    assert target.stat() == before


def test_minor_2_provisioner_idempotent_and_repairs_root_metadata(tmp_path, monkeypatch):
    volatile, _ = provision_fixture(tmp_path, monkeypatch)
    entry = volatile / 'chief/runtime'
    entry.mkdir(parents=True, mode=0o700)
    # Model a root-owned entry with a different group without needing extra
    # mapped GIDs. The real fchown must then select the fixture chief group.
    real_fstat = os.fstat
    observed = []

    def wrong_group_once(fd):
        info = real_fstat(fd)
        if stat.S_IMODE(info.st_mode) == 0o700 and not observed:
            observed.append(fd)
            return SimpleNamespace(st_dev=info.st_dev, st_ino=info.st_ino,
                                   st_uid=0, st_gid=65534, st_mode=info.st_mode)
        return info

    monkeypatch.setattr(runtime.os, 'fstat', wrong_group_once)
    runtime.prepare_runtime_directory()
    assert (entry.stat().st_uid, entry.stat().st_gid, stat.S_IMODE(entry.stat().st_mode)) == (0, os.getgid(), 0o770)
    assert observed
    before = snapshot(volatile)
    runtime.prepare_runtime_directory()
    assert snapshot(volatile) == before


@pytest.mark.parametrize('reader', ['hermes-converger', 'chief-node-supervisor', 'chief-update'])
@pytest.mark.parametrize('pending', ['reclaim', 'publication', 'live'])
def test_minor_1_pending_handoff_keeps_readers_running_without_reclaim(tmp_path, reader, pending):
    host = Host(tmp_path)
    result = host.run()
    assert result.returncode == 0, host.output(result)
    (host.state / 'grants-removed').unlink()
    host.fragment.chmod(0o640)
    host.fragment.write_text('fixture ALL=(root) NOPASSWD: /usr/local/bin/hermes-converger\n')
    host.fragment.chmod(0o440)
    lock = host.root / 'var/lib/chief/chief-currency-closure.boot-or-wake.lock'
    lock.mkdir()
    if pending in {'reclaim', 'live'}:
        (lock / 'pid').write_text(str(os.getpid() if pending == 'live' else 2147483647) + '\n')
    guard = lock.with_name(lock.name + '.reclaim')
    if pending == 'reclaim':
        guard.mkdir()
    before, policy = snapshot(lock), host.fragment.read_bytes()
    result = host.run(reader)
    assert result.returncode == (75 if reader == 'chief-update' else 0), host.output(result)
    assert 'HOLD:' in result.stderr
    assert snapshot(lock) == before
    assert guard.exists() is (pending == 'reclaim')
    assert host.fragment.read_bytes() == policy
    assert not (host.state / 'grants-removed').exists()
    calls = host.log.read_text()
    if reader == 'hermes-converger':
        assert 'boss check-in' in calls
    elif reader == 'chief-node-supervisor':
        assert 'health healthy' in calls
    else:
        assert 'boss check-in' not in calls and 'health healthy' not in calls


@pytest.mark.parametrize('name,passes', [('fixture.bak', True), ('fixture~', True), ('fixture', False)])
def test_nit_4_policy_render_obeys_sudo_include_names(tmp_path, name, passes):
    host = Host(tmp_path)
    prepare_preflight(host)
    (host.fragment.parent / name).write_text('this is invalid sudo policy\n')
    before = snapshot(host.root)
    result = preflight(host)
    assert (result.returncode == 0) is passes, result.stdout + result.stderr
    assert snapshot(host.root) == before


def test_nit_5_boot_identity_failure_has_hold(tmp_path):
    host = Host(tmp_path)
    host.tool('sysctl', 'exit 1')
    result = host.run()
    assert result.returncode == 1
    assert 'HOLD: boot_identity_unavailable' in result.stderr
    assert not host.state.exists()


def test_nit_3_generic_preflight_requires_bridge_gate():
    doc = (ROOT / 'docs/currency-step0.md').read_text()
    generic = doc.split('## Mandatory first step on every host', 1)[1].split('## Before delivery', 1)[0]
    assert 'Bridge hosts, including h-mini2 retries, must use' in generic
    assert '[Reachable Macs](#reachable-macs-with-a-trusted-legacy-delivery-path)' in generic
    assert 'A private-directory PASS does not gate' in generic
