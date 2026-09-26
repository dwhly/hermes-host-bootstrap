"""Live-canary regressions; all execution stays inside private host fixtures."""
from __future__ import annotations

import json
import os
import pathlib
import shlex
import shutil
import stat
import subprocess
from types import SimpleNamespace

import pytest

from hermes_converger import core, runtime, security
from test_currency_fix1 import Host
from test_currency_fix2 import PulseHost
from test_currency_step0 import PAYLOAD, REGISTRY, ROOT

EVIDENCE = (ROOT / 'tests/fixtures/macos-paths-ioreg.txt').read_text()
MACS = [part for part in EVIDENCE.split('== ') if part.strip()]


@pytest.mark.parametrize('evidence', MACS, ids=['h-mini2-26.5.2', 'h-air-26.3.1', 'h-mini-15.6.1'])
def test_real_mac_wake_outputs_in_both_parsers(tmp_path, monkeypatch, evidence):
    listing = '\n'.join(line for line in evidence.splitlines() if line.startswith('      '))
    assert '"System Capabilities" = 15' in listing
    assert 'SystemPowerStateCapabilities' not in listing
    monkeypatch.setattr(runtime.os, 'uname', lambda: SimpleNamespace(sysname='Darwin'))
    monkeypatch.setattr(runtime.subprocess, 'run', lambda *a, **k: SimpleNamespace(returncode=0, stdout=listing))
    assert runtime.full_wake(True)
    assert not runtime.full_wake(False)
    monkeypatch.undo()
    host = PulseHost(tmp_path)
    host.tool('ioreg', 'cat <<\'IOREG\'\n' + listing + '\nIOREG')
    result = host.run()
    assert result.returncode == 0 and 'full=yes' in result.stdout, result.stderr


@pytest.mark.parametrize('value,expected', [('1', False), ('9', False), ('3', True), ('15', True),
    ('015', True), ('unknown', False), ('15oops', False), ('', False), ('999999999999999999999999', False)])
def test_wake_masks_and_unparseable_real_key_stay_report_only(tmp_path, monkeypatch, value, expected):
    listing = MACS[0].replace('"System Capabilities" = 15', '"System Capabilities" = ' + value)
    # A malformed primary must not be rescued by the legacy key or wake history.
    listing += '\n"SystemPowerStateCapabilities" = 15\n'
    monkeypatch.setattr(runtime.os, 'uname', lambda: SimpleNamespace(sysname='Darwin'))
    monkeypatch.setattr(runtime.subprocess, 'run', lambda *a, **k: SimpleNamespace(returncode=0, stdout=listing))
    assert runtime.full_wake(True) is expected
    monkeypatch.undo()
    host = PulseHost(tmp_path)
    host.tool('ioreg', 'cat <<\'IOREG\'\n' + listing + '\nIOREG')
    result = host.run()
    assert result.returncode == 0 and ('full=yes' if expected else 'full=no') in result.stdout, result.stderr


def test_h_air_local_maps_to_reviewed_node_in_both_config_readers(tmp_path):
    assert security.resolve_config(None, 'h-air.local', REGISTRY)['CHIEF_NODE_ID'] == 'h-air'
    host = Host(tmp_path, hostname='h-air.local')
    result = host.run()
    assert result.returncode == 0, host.output(result)
    assert security.read_env(host.root / 'etc/chief/node.env')['CHIEF_NODE_ID'] == 'h-air'


def snapshot(root):
    result = {}
    for path in [root, *sorted(root.rglob('*'))]:
        info = path.lstat()
        result[str(path.relative_to(root))] = (info.st_mode, info.st_uid, info.st_gid, info.st_ino,
            info.st_mtime_ns, info.st_ctime_ns,
            os.readlink(path) if path.is_symlink() else path.read_bytes() if path.is_file() else None)
    return result


def preflight(host):
    return subprocess.run(['/bin/sh', str(host.base / 'close.sh'), '--preflight'],
                          text=True, capture_output=True, timeout=60)


def prepare_preflight(host):
    # Preserve real validation/control flow, but model trusted ownership in this
    # private root and use its OS/interpreter adapters. None touch the live host.
    trust = (host.base / 'trust.sh').read_text()
    trust = trust.replace('trusted_path() { :; }', '''trusted_path() {
    [ -e "$1" ] || { hold "missing path: $1"; return 1; }
    case "$1" in */var/run|*/writable*) hold "writable path: $1"; return 1;; esac
}''')
    (host.base / 'trust.sh').write_text(trust)
    # The fixture models only registry users as existing, for sudo -ll checks.
    wrapper = host.bin / 'python'
    wrapper.write_text(wrapper.read_text().replace('\nimport sys\n',
        '\nimport sys,pwd,types\npwd.getpwnam = lambda name: types.SimpleNamespace(pw_uid=502)\n'))


@pytest.mark.parametrize('platform,hostname', [('Darwin', 'h-mini2'), ('Linux', 'h-do1')])
def test_preflight_pass_is_read_only_before_and_after_closure(tmp_path, platform, hostname):
    host = Host(tmp_path, platform, hostname)
    prepare_preflight(host)
    for closed in (False, True):
        before = snapshot(host.root)
        calls = host.log.read_text() if host.log.exists() else ''
        result = preflight(host)
        assert result.returncode == 0, result.stdout + result.stderr
        assert 'PASS (read-only' in result.stdout
        assert snapshot(host.root) == before
        actions = host.log.read_text()[len(calls):]
        assert not any(word in actions for word in ('install ', 'bootstrap ', 'bootout ', 'stop ', 'disable ', 'enable ', 'dseditgroup ', 'chown ', 'sync '))
        if not closed:
            result = host.run()
            assert result.returncode == 0, host.output(result)


def test_preflight_collects_independent_holds_without_writing(tmp_path):
    host = Host(tmp_path)
    prepare_preflight(host)
    (host.root / 'etc/chief/node.env').write_text('CHIEF_NODE_ID=h-air\nCHIEF_CORE_URL=http://core:8088\n')
    (host.root / 'opt/chief/bin/chief-update').symlink_to('/missing')
    job = host.base / 'launchd/com.chief.node-supervisor.plist'
    job.write_text('broken plist')
    host.tool('sudo', "printf 'Sudoers entry:\\n    Options: !authenticate\\n    Commands:\\n        ALL\\n'")
    host.fragment.chmod(0o640)
    host.fragment.write_text(host.fragment.read_text() + '\n@include /unsupported\n')
    host.fragment.chmod(0o440)
    before = snapshot(host.root)
    result = preflight(host)
    assert result.returncode == 1
    output = result.stdout + result.stderr
    for reason in ('destination symlink', 'node_identity_conflicts', 'nonstandard sudoers include',
                   'job_definition:node-supervisor', 'remaining_passwordless_grant'):
        assert reason in output, output
    assert snapshot(host.root) == before


def test_preflight_python_hold_does_not_skip_path_or_shell_config_checks(tmp_path):
    host = Host(tmp_path)
    prepare_preflight(host)
    trust = host.base / 'trust.sh'
    trust.write_text(trust.read_text().replace('trusted_python() {', 'trusted_python() { return 1; '))
    host.tool('hostname', 'echo unmapped-host')
    (host.root / 'etc/chief/node.env').symlink_to('/missing')
    before = snapshot(host.root)
    result = preflight(host)
    assert result.returncode == 1
    assert 'trusted_python_unavailable' in result.stderr and 'destination symlink' in result.stderr
    assert snapshot(host.root) == before


@pytest.mark.parametrize('boot,live,expected', [('old-boot', True, 0), ('boot-or-wake', False, 0), ('boot-or-wake', True, 75), ('', True, 75)])
def test_persistent_closure_lock_reclaims_old_boot_or_dead_pid(tmp_path, boot, live, expected):
    host = Host(tmp_path)
    lock = host.root / 'var/lib/chief/chief-currency-closure.lock'
    lock.mkdir(parents=True)
    (lock / 'boot').write_text(boot + '\n')
    (lock / 'pid').write_text(str(os.getpid() if live else 2147483647) + '\n')
    result = host.run()
    assert result.returncode == expected, host.output(result)
    assert lock.exists() is (expected == 75)


def test_live_canary_hold_retry_refreshes_verified_opt_copy_and_completes(tmp_path):
    host = Host(tmp_path)
    legacy = host.root / 'usr/local/lib/hermes-host-bootstrap/hermes_converger'
    shutil.copytree(host.base.parent, legacy)
    entry = host.root / 'usr/local/bin/hermes-converger'
    shutil.copy2(legacy / 'step0/bin/hermes-converger', entry)
    # Exact canary state: verified previous /opt copy, no state/config/jobs,
    # all grants retained. Prove retry replaces it instead of re-entering it.
    (host.base / 'close.sh').write_text("echo 'old canary /var/run HOLD' >&2\nexit 1\n")
    assert not host.state.exists()
    assert not list((host.root / 'Library/LaunchDaemons').iterdir())
    assert host.fragment.read_text().count('NOPASSWD') == 3
    result = subprocess.run(['/bin/sh', str(entry)], text=True, capture_output=True, timeout=30)
    assert result.returncode == 0, host.output(result)
    assert (host.state / 'grants-removed').exists()
    assert (host.state / 'closure-status').read_text() == 'hold: none\njobs: enabled\ngrants: removed\n'
    assert 'NOPASSWD' not in host.fragment.read_text()
    assert len(list((host.root / 'Library/LaunchDaemons').iterdir())) == 3
    result = subprocess.run(['/bin/sh', str(entry)], text=True, capture_output=True, timeout=30)
    assert result.returncode == 0, host.output(result)


def test_mac_runtime_paths_and_unweakened_group_write_guard(tmp_path, monkeypatch):
    assert str(core.MACOS_RUNTIME_STAMP_DIR) == '/var/lib/chief/runtime'
    source = (ROOT / 'hermes_converger/core.py').read_text()
    assert 'RUN_BASE = "/var/lib" if IS_MACOS else "/run"' in source
    assert 'state._path(f"{RUN_BASE}/chief/reconcile.lock")' in source
    assert '/var/run' not in source.replace('# macOS /var/run is root:daemon 0775.', '')
    # Execute the actual unchanged path guard with root:daemon 0775 evidence.
    path = tmp_path / 'var/run'
    path.mkdir(parents=True)
    path.chmod(0o775)
    tool = tmp_path / 'stat'
    tool.write_text('#!/bin/sh\nfor p do :; done\ncase "$p" in '+shlex.quote(str(path))+') echo "0 775";; *) echo "0 755";; esac\n')
    tool.chmod(0o755)
    trust = (PAYLOAD / 'trust.sh').read_text().replace('/usr/bin/stat', str(tool))
    result = subprocess.run(['/bin/sh'], input=trust+'\ntrusted_path '+shlex.quote(str(path))+'\n', text=True, capture_output=True)
    assert result.returncode == 1 and 'writable path:' in result.stderr


@pytest.mark.parametrize('kind', ['drop-in', 'transient', 'not-found', 'unsafe-manager'])
def test_preflight_effective_linux_definitions(tmp_path, kind):
    host = Host(tmp_path, 'Linux', 'h-do1')
    prepare_preflight(host)
    if kind == 'not-found':
        host.tool('systemctl', 'echo not-found; exit 1')
    elif kind == 'unsafe-manager':
        manager = host.root / 'run/systemd/system'
        (manager / 'chief-update.service.d').mkdir(parents=True)
        trust = host.base / 'trust.sh'
        trust.write_text(trust.read_text().replace('trusted_path() {',
            'trusted_path() {\ncase "$1" in ' + shlex.quote(str(manager)) +
            ') hold unsafe_override_parent; return 1;; esac\n'))
    elif kind == 'drop-in':
        host.tool('systemctl', 'case "$*" in *DropInPaths*) echo /etc/systemd/system/service.d/global.conf;; esac')
    else:
        host.tool('systemctl', 'case "$*" in *FragmentPath*) echo /run/systemd/transient/"$2";; esac')
    before = snapshot(host.root)
    result = preflight(host)
    assert (result.returncode == 0) is (kind == 'not-found'), result.stdout + result.stderr
    if kind == 'unsafe-manager':
        assert 'unsafe_override_parent' in result.stderr
    elif kind != 'not-found':
        assert 'effective_unit_override:' in result.stderr
    assert snapshot(host.root) == before


def test_preflight_reports_live_closure_lock_without_reclaiming_it(tmp_path):
    host = Host(tmp_path)
    prepare_preflight(host)
    lock = host.root / 'var/lib/chief/chief-currency-closure.lock'
    lock.mkdir(parents=True)
    (lock / 'pid').write_text(str(os.getpid()) + '\n')
    (lock / 'boot').write_text('boot-or-wake\n')
    before = snapshot(host.root)
    result = preflight(host)
    assert result.returncode == 1 and 'closure_already_running' in result.stderr
    assert snapshot(host.root) == before
