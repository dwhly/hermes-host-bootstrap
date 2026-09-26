"""Gate-3 r5 findings: private Mac/Linux fixtures; no host or service mutation."""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import tarfile
import time
from types import SimpleNamespace

import pytest

from hermes_converger import core
from test_converger import DummyTransport, NOW, fresh_idle_snapshot, make_plan, verify
from test_currency_fix1 import Host
from test_currency_fix4 import preflight, prepare_preflight, snapshot
from test_currency_step0 import PAYLOAD, ROOT


def bridge_fixture(host):
    legacy = host.root / 'usr/local/lib/hermes-host-bootstrap/hermes_converger'
    shutil.copytree(host.base.parent, legacy)
    entry = host.root / 'usr/local/bin/hermes-converger'
    shutil.copy2(legacy / 'step0/bin/hermes-converger', entry)
    return legacy / 'step0', entry


def test_major_1_runtime_proof_contract_mac_preflight_and_restart_convergence(tmp_path, monkeypatch):
    host = Host(tmp_path)
    prepare_preflight(host)
    # Literal producer setup from the runbook, including the writable data dir.
    doc = (ROOT / 'docs/chief-node-source-reconciliation.md').read_text()
    producer = re.search(r'-m 0770 (/var/run/\S+)', doc)[1]
    assert producer == str(core.MACOS_RUNTIME_STAMP_DIR)
    (host.root / 'var/run').chmod(0o775)
    runtime_dir = host.root / producer.lstrip('/')
    runtime_dir.mkdir(parents=True)
    runtime_dir.parent.chmod(0o750)
    runtime_dir.chmod(0o770)
    before = snapshot(host.root)
    result = preflight(host)
    assert result.returncode == 0, result.stdout + result.stderr
    assert snapshot(host.root) == before
    result = host.run()
    assert result.returncode == 0, host.output(result)

    monkeypatch.delenv('HERMES_RUNTIME_STAMP_DIR', raising=False)
    monkeypatch.setattr(core, 'IS_MACOS', True)
    monkeypatch.setattr(core, 'RUN_BASE', '/var/lib')
    monkeypatch.setattr(core, 'MACOS_RUNTIME_STAMP_DIR', runtime_dir)
    monkeypatch.setattr(core, 'utcnow', lambda: NOW)
    monkeypatch.setattr(core, '_resolve_tool', lambda name: name)
    monkeypatch.setattr(core, '_launchd_target', lambda *a: 'gui/502/com.chief.node')
    state = core.LocalState(host.root)
    ops = core.HostOps(state, DummyTransport())
    events, commands = [], []
    monkeypatch.setattr(ops, 'emit', lambda name, plan, **kw: events.append((name, kw)))
    monkeypatch.setattr(ops, 'fetch', lambda plan: None)
    monkeypatch.setattr(ops, 'install_restart_required', lambda plan: None)
    plan = verify(make_plan())

    def producer_restart(command, **kwargs):
        commands.append(command)
        if command[1] == 'kickstart':
            stamp = runtime_dir / 'chief-node' / 'hermes-node.json'
            stamp.parent.mkdir()
            stamp.write_text(json.dumps({'loaded_ref': plan.raw['target_ref'], 'health': 'healthy',
                'pid': 502, 'monotonic_nonce': 1, 'process_start_time': NOW.isoformat(),
                'observed_at': (NOW + dt.timedelta(seconds=1)).isoformat()}))
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(core.subprocess, 'run', producer_restart)
    # Exercise the real poller and bounded no-follow stamp reader. A missed
    # contract would sleep here, and fails immediately instead of waiting 30s.
    monkeypatch.setattr(core.time, 'sleep', lambda seconds: pytest.fail('runtime proof would time out'))
    assert core.execute_plan(plan, ops, fresh_idle_snapshot()) == 'applied'
    assert commands[-1] == ['launchctl', 'kickstart', '-k', 'gui/502/com.chief.node']
    proof = events[-1][1]['verification']
    assert proof['method'] == 'runtime_stamp'
    assert proof['runtime_source']['path'].startswith(str(runtime_dir))
    assert state.load_watermarks()[plan.raw['node_id']]['hermes-node']['target_ref'] == plan.raw['target_ref']
    assert not any(name in {'failed', 'rolled_back'} for name, _ in events)


def wait_file(path, process=None):
    until = time.monotonic() + 10
    while not path.exists():
        if process is not None and process.poll() is not None:
            pytest.fail(str(process.communicate()))
        assert time.monotonic() < until, str(path)
        time.sleep(0.01)


@pytest.mark.parametrize('same_boot', [False, True], ids=['after-reboot', 'dead-same-boot'])
def test_minor_2_persistent_lock_concurrent_reclaim_is_single_writer(tmp_path, same_boot):
    host = Host(tmp_path)
    name = 'boot-or-wake' if same_boot else 'old-boot'
    old = host.root / f'var/lib/chief/chief-currency-closure.{name}.lock'
    old.mkdir(parents=True)
    (old / 'pid').write_text('2147483647\n')
    (old / 'boot').write_text(name + '\n')
    entered, release = tmp_path / 'entered', tmp_path / 'release'
    script = host.base / 'close.sh'
    script.write_text(script.read_text().replace('closure_lock_acquire\n', f'''closure_lock_acquire
printf '%s\\n' "$$" >> {shlex.quote(str(entered))}
while [ ! -f {shlex.quote(str(release))} ]; do /bin/sleep 0.01; done
'''))
    processes = [subprocess.Popen(['/bin/sh', str(script)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(2)]
    try:
        wait_file(entered)
        until = time.monotonic() + 10
        while all(p.poll() is None for p in processes):
            assert time.monotonic() < until
            time.sleep(0.01)
        assert len(entered.read_text().splitlines()) == 1
        assert [p.returncode for p in processes].count(75) == 1
        live_lock = host.root / 'var/lib/chief/chief-currency-closure.boot-or-wake.lock'
        assert (live_lock / 'pid').read_text().strip() == entered.read_text().strip()
        release.touch()
        results = [(p.communicate(timeout=20), p.returncode) for p in processes]
        assert sorted(p.returncode for p in processes) == [0, 75], results
        assert not live_lock.exists()
    finally:
        for p in processes:
            if p.poll() is None: p.kill()
            p.communicate()


@pytest.mark.parametrize('pending', ['reclaim', 'publication'])
def test_minor_2_interrupted_lock_handoff_holds_read_only(tmp_path, pending):
    host = Host(tmp_path)
    prepare_preflight(host)
    lock = host.root / 'var/lib/chief/chief-currency-closure.boot-or-wake.lock'
    lock.mkdir(parents=True)
    if pending == 'reclaim':
        (lock / 'pid').write_text('2147483647\n')
        lock.with_name(lock.name + '.reclaim').mkdir()
    before = snapshot(host.root)
    result = preflight(host)
    assert result.returncode == 1 and 'pending' in result.stderr
    assert snapshot(host.root) == before
    result = host.run()
    assert result.returncode == 75
    assert snapshot(host.root) == before


def test_minor_2_stable_boot_uuid_in_all_consumers(tmp_path):
    for name in ('closure-lock.sh', 'trust.sh', 'pulse.sh', 'preflight.sh'):
        source = (PAYLOAD / name).read_text()
        assert 'kern.boottime' not in source and 'kern.bootsessionuuid' in source
    host = Host(tmp_path)
    prepare_preflight(host)
    # Missing sysctl is a preflight HOLD, never a fallback to calendar time.
    host.tool('sysctl', 'exit 1')
    result = preflight(host)
    assert result.returncode == 1


@pytest.mark.parametrize('platform', ['Darwin', 'Linux'])
@pytest.mark.parametrize('unsafe', ['helper-mode', 'parent-mode', 'helper-owner', 'parent-owner', 'helper-link', 'parent-link', 'acl'])
def test_minor_3_preflight_never_sources_untrusted_helper(tmp_path, platform, unsafe):
    host = Host(tmp_path, platform, 'h-mini2' if platform == 'Darwin' else 'h-do1')
    marker = tmp_path / 'executed'
    helper = host.base / 'trust.sh'
    helper.write_text('touch '+shlex.quote(str(marker))+'\nexit 99\n')
    if unsafe == 'helper-mode': helper.chmod(0o775)
    if unsafe == 'parent-mode': host.base.chmod(0o775)
    if unsafe in {'helper-owner', 'parent-owner'}:
        target = helper if unsafe == 'helper-owner' else host.base
        stat_tool = host.bin / 'stat'
        stat_tool.write_text(stat_tool.read_text().replace('    print(uid,',
            '    if path == '+repr(str(target))+': uid=12345\n    print(uid,'))
    if unsafe == 'helper-link':
        target = tmp_path / 'evil'; helper.rename(target); helper.symlink_to(target)
    if unsafe == 'parent-link':
        target = host.base.with_name('relocated'); host.base.rename(target); host.base.symlink_to(target)
    if unsafe == 'acl':
        if platform != 'Darwin': pytest.skip('Darwin ACL guard')
        host.tool('ls', "printf 'drwxr-xr-x+ 2 root wheel 64 Sep 26 fixture\\n 0: user:fixture allow write\\n'")
    result = preflight(host)
    assert result.returncode == 1 and 'unsafe bootstrap trust chain' in result.stderr
    assert not marker.exists()


def test_minor_3_runbook_has_login_user_admin_bridge_preflight():
    doc = (ROOT / 'docs/currency-step0.md').read_text()
    bridge = doc.split('## Reachable Macs', 1)[1].split('## ', 1)[0]
    assert 'sudo /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin' in bridge
    assert '/bin/sh /usr/local/lib/hermes-host-bootstrap/hermes_converger/step0/close.sh --preflight' in bridge
    assert bridge.index('/usr/local/bin/chief-update') < bridge.index('close.sh --preflight') < bridge.index('/usr/local/bin/hermes-converger')
    assert 'administrator sudo' in bridge and 'login user' in bridge


@pytest.mark.parametrize('fault', ['none', 'launcher', 'payload', 'opt-bin', 'log', 'config', 'policy', 'lock', 'alias', 'runtime', 'missing-tool'])
def test_minor_4_preflight_bridge_closure_equivalence(tmp_path, fault):
    host = Host(tmp_path)
    prepare_preflight(host)
    legacy, entry = bridge_fixture(host)
    # Both paths execute the SAME real trust guard, with filesystem metadata
    # adapters limited to the fixture boundary. Exclude interpreter selection
    # only, since this Linux machine has no Apple CLT framework.
    trust = (PAYLOAD / 'trust.sh').read_text()
    # Real path checks run as Linux on Linux; Mac-specific ACL/bootstrap checks
    # have their own adversarial coverage above.
    trust = trust.replace('TRUST_OS=$(/usr/bin/uname -s)', 'TRUST_OS=Linux')
    trust += '\ntrusted_python() { PY='+shlex.quote(str(host.bin / 'python'))+'; export PY; }\ntrusted_runtime() { trusted_python; }\n'
    # /tmp is the private virtual host boundary, not the production root chain.
    real = tmp_path / 'trust-stat'
    real.write_text('#!/bin/sh\nfor p do :; done\ncase "$p" in '+shlex.quote(str(host.root))+'*) exec /usr/bin/stat "$@";; *) echo "0 755";; esac\n')
    real.chmod(0o755)
    trust = trust.replace('/usr/bin/stat', str(real))
    for base in (host.base, legacy): (base / 'trust.sh').write_text(trust)
    # Generated entries embed their trust helpers. Replace only that region.
    source = entry.read_text(); pos = source.index('exec /usr/bin/env'); args = shlex.split(source[pos:]); body = args[-1]
    a, b = body.index('set -eu'), body.index('remove_grants() {')
    body = body[:a] + trust + '\n' + body[b:]
    entry.write_text(source[:pos] + ' '.join(shlex.quote(v) for v in args[:-1]) + ' ' + shlex.quote(body) + '\n')
    # Restore the expansion deliberately made literal by shlex quoting argv.
    entry.write_text(entry.read_text().replace("'CHIEF_LEGACY_ENTRY=$legacy'", 'CHIEF_LEGACY_ENTRY="$legacy"'))
    if fault == 'launcher': entry.parent.chmod(0o775)
    if fault == 'payload': (legacy.parent / 'core.py').chmod(0o664)
    if fault == 'opt-bin': (host.root / 'opt/chief/bin').chmod(0o775)
    if fault == 'log': (host.root / 'var/log/chief-closure.log').mkdir()
    if fault == 'config': (host.root / 'etc/chief/node.env').write_text('invalid\n')
    if fault == 'policy': host.fragment.chmod(0o664)
    if fault == 'lock':
        lock = host.root / 'var/lib/chief/chief-currency-closure.boot-or-wake.lock'; lock.mkdir(parents=True)
        (lock / 'pid').write_text(str(os.getpid())+'\n')
    if fault == 'alias':
        directory = host.root / 'opt/chief/bin'; target = directory.with_name('aliased-bin'); directory.rename(target); directory.symlink_to(target)
    if fault == 'runtime':
        for base in (host.base, legacy):
            p = base / 'trust.sh'; p.write_text(p.read_text()+'\ntrusted_python() { return 1; }\n')
    if fault == 'missing-tool': (host.bin / 'dseditgroup').unlink()
    before = snapshot(host.root)
    result = subprocess.run(['/bin/sh', str(legacy / 'close.sh'), '--preflight'], capture_output=True, text=True, timeout=30)
    assert snapshot(host.root) == before
    if fault != 'none':
        assert result.returncode != 0, fault + result.stdout + result.stderr
    else:
        assert result.returncode == 0, result.stdout + result.stderr
        result = subprocess.run(['/bin/sh', str(entry)], capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, host.output(result)
        assert (host.state / 'closure-status').read_text() == 'hold: none\njobs: enabled\ngrants: removed\n'


def installer_fixture(tmp_path, entry):
    host = Host(tmp_path)
    source_tree = tmp_path / 'reviewed'
    shutil.copytree(host.base.parent, source_tree / 'hermes_converger')
    source = (host.base / entry).read_text()
    if entry == 'install-archive.sh':
        archive = tmp_path / 'payload.tar'
        with tarfile.open(archive, 'w') as tar: tar.add(source_tree / 'hermes_converger', arcname='hermes_converger')
        args = [str(archive), hashlib.sha256(archive.read_bytes()).hexdigest()]
        source = source.replace('private='+str(host.root / 'var/root'), 'private='+shlex.quote(str(tmp_path)))
    else:
        host.tool('git', 'case "$*" in *clone*) for destination do :; done; mkdir "$destination"; cp -R '+shlex.quote(str(source_tree / 'hermes_converger'))+' "$destination/";; esac')
        source = source.replace(str(host.root / 'Library/Developer/CommandLineTools/usr/bin/git'), str(host.bin / 'git'))
        source = source.replace('/usr/bin/git', str(host.bin / 'git'))
        args = ['a'*40]
    script = tmp_path / entry
    script.write_text(source)
    return host, script, args


@pytest.mark.parametrize('entry', ['update.sh', 'install-archive.sh'])
@pytest.mark.parametrize('sig', ['HUP', 'PIPE'])
def test_minor_5_installers_ignore_session_signals(tmp_path, entry, sig):
    host, script, args = installer_fixture(tmp_path, entry)
    marker = '/bin/mv '+str(host.base.parent)
    source = script.read_text()
    if entry == 'install-archive.sh': marker = '/bin/mv "$base/hermes_converger"'
    lines = source.splitlines()
    at = next(i for i, line in enumerate(lines) if marker in line)
    lines.insert(at+1, 'kill -'+sig+' $$')
    script.write_text('\n'.join(lines)+'\n')
    result = subprocess.run(['/bin/sh', str(script), *args], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, host.output(result)
    assert (host.state / 'grants-removed').exists()


@pytest.mark.parametrize('failure', ['exit-after-old-move', 'failed-publish-and-restore', 'kill-after-old-move'])
def test_minor_5_update_never_deletes_only_previous(tmp_path, failure):
    host, script, args = installer_fixture(tmp_path, 'update.sh')
    original = (host.base.parent / 'core.py').read_bytes()
    source = script.read_text()
    move = '/bin/mv '+str(host.base.parent)+' "$stage/previous"'
    assert move in source
    if failure != 'failed-publish-and-restore':
        source = source.replace(move, move + ('\nexit 42' if failure.startswith('exit') else '\nkill -KILL $$'))
    else:
        mv = tmp_path / 'mv-fail'
        mv.write_text('#!/bin/sh\ncase "$1" in */previous|*/src/hermes_converger) exit 1;; esac\nexec /bin/mv "$@"\n')
        mv.chmod(0o755)
        source = source.replace('/bin/mv', str(mv))
    script.write_text(source)
    result = subprocess.run(['/bin/sh', str(script), *args], capture_output=True, text=True, timeout=30)
    assert result.returncode != 0
    copies = list((host.root / 'opt/chief/lib').rglob('core.py'))
    assert any(p.read_bytes() == original for p in copies), host.output(result)
    assert host.base.is_dir() or any('/previous/' in str(p) for p in copies)


def test_nit_6_runbook_consistent_mac_lock_expiry():
    doc = (ROOT / 'docs/currency-step0.md').read_text()
    assert 'Linux: boot clears' in doc and 'macOS: boot UUID' in doc
    assert 'kern.boottime' not in doc
    assert 'boot clears stale locks' not in doc
    assert 'chief-currency-closure.<bootsessionuuid>.lock' in doc


@pytest.mark.parametrize('missing', ['config', 'launcher', 'helper'])
def test_minor_4_prepared_dispatcher_requirements_are_preflighted(tmp_path, missing):
    host = Host(tmp_path)
    prepare_preflight(host)
    result = host.run()
    assert result.returncode == 0, host.output(result)
    paths = {'config': host.root / 'etc/chief/node.env',
             'launcher': host.root / 'opt/chief/bin/chief-update',
             'helper': host.base / 'supervise.sh'}
    paths[missing].unlink()
    before = snapshot(host.root)
    result = preflight(host)
    assert result.returncode == 1 and 'missing path' in result.stderr
    assert snapshot(host.root) == before


def test_minor_2_reclaim_exit_never_removes_a_successor_guard(tmp_path):
    host = Host(tmp_path)
    lock = host.root / 'var/lib/chief/chief-currency-closure.boot-or-wake.lock'
    lock.mkdir(parents=True)
    (lock / 'pid').write_text('2147483647\n')
    helper = host.base / 'closure-lock.sh'
    # Model a successor taking the released guard, then an immediate exit in
    # the releaser before it returns to close.sh. Its old EXIT trap must be gone.
    helper.write_text(helper.read_text().replace('        /bin/rmdir "$lock.reclaim"\n',
        '        /bin/rmdir "$lock.reclaim"\n        /bin/mkdir "$lock.reclaim"\n        exit 42\n'))
    result = host.run()
    assert result.returncode == 42, host.output(result)
    assert lock.with_name(lock.name + '.reclaim').is_dir()
