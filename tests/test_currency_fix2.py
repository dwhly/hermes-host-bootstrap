"""Round 2 regressions. All files/controls are private fixtures, never live hosts."""
from __future__ import annotations
import hashlib
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import time

import pytest
from test_currency_fix1 import Host
from test_currency_step0 import ROOT, PAYLOAD


class PulseHost:
    """Execute the real generated launcher/guard/pulse with synthetic OS replies.

    Only paths, ownership/ACL replies and OS/network probes are substituted.
    No trust functions, fork operations or shell control flow are stubbed.
    """
    def __init__(self, tmp, shell='/bin/sh'):
        self.root = tmp/'host'
        self.base = self.root/'opt/chief/lib/hermes-host-bootstrap/hermes_converger/step0'
        self.state = self.root/'var/lib/chief/currency-step0'
        self.bin = tmp/'tools'; self.bin.mkdir()
        self.calls = tmp/'calls'
        self.base.mkdir(parents=True)
        self.state.mkdir(parents=True)
        (self.root/'etc/chief').mkdir(parents=True)
        (self.root/'opt/chief/bin').mkdir(parents=True)
        self.hints = self.root/'var/lib/chief/requests'; self.hints.mkdir()
        self.tool('uname', 'echo Darwin')
        self.tool('id', 'echo 0')
        self.tool('stat', '''shift 2
for path do
    if [ -L "$path" ]; then printf '0 120755\n'; else printf '0 100755\n'; fi
done''')
        self.tool('ls', "echo 'drwxr-xr-x 2 root wheel 64 Sep 26 01:43 fixture'")
        self.tool('sysctl', "printf 'boot\nwake\n'")
        self.tool('ioreg', '''echo '"SystemPowerStateCapabilities" = 15' ''')
        self.tool('curl', ':')
        self.tool('launchctl', "echo 'state = running'")
        self.tool('systemctl', ':')
        for name,value in {'prepared':'fix1','grants-removed':'','last-check':str(int(time.time())-100),
                           'boot':'boot','wake':'wake','full':'yes','online':'yes',
                           'last-health':str(int(time.time())),
                           'supervisor-targets':'launchd gui/502/com.chief.node yes 0'}.items():
            (self.state/name).write_text(value+'\n')
        (self.root/'etc/chief/node.env').write_text('CHIEF_CORE_URL=http://fixture\n')
        for name in ('login','wake','network','request'): (self.hints/name).touch()
        commands = ['/usr/bin/uname','/usr/bin/id','/usr/bin/stat','/bin/ls','/usr/sbin/sysctl',
                    '/usr/sbin/ioreg','/usr/bin/curl','/bin/launchctl','/usr/bin/systemctl']
        for name in ('trust.sh','pulse.sh','supervise.sh'):
            source = (PAYLOAD/name).read_text()
            (self.base/name).write_text(self.rewrite(source, commands))
        for name in ('hermes-converger','chief-node-supervisor','chief-update'):
            source = (PAYLOAD/'bin'/name).read_text()
            source = source.replace('/bin/sh -c', shell+' -c')
            # Simulate Mac Bash's own OSTYPE/EUID; dash still uses the OS tools.
            source = source.replace('linux*) TRUST_OS=Linux', 'linux*) TRUST_OS=Darwin')
            source = source.replace('${EUID:-', '${CURRENCY_TEST_UID:-')
            if shell == '/bin/bash':
                source = source.replace('LANG=C ', 'LANG=C CURRENCY_TEST_UID=0 ')
            (self.root/'opt/chief/bin'/name).write_text(self.rewrite(source, commands))

    def rewrite(self, source, commands):
        source = re.sub(r'/(?:private/)?(opt|etc|var)(?=[/\s\'"])', lambda m: str(self.root)+'/'+m[1], source)
        for command in commands: source = source.replace(command, str(self.bin/command.rsplit('/',1)[1]))
        return source

    def tool(self, name, body):
        p = self.bin/name
        p.write_text('#!/bin/sh\nprintf "%s\\n" '+shlex.quote(name)+' >> '+shlex.quote(str(self.calls))+'\n'+body+'\n')
        p.chmod(0o755)

    def argv(self, entry='hermes-converger'):
        return ['/bin/sh',str(self.root/'opt/chief/bin'/entry)]

    def run(self, entry='hermes-converger'):
        return subprocess.run(self.argv(entry), capture_output=True, text=True, timeout=10)


@pytest.mark.parametrize('shell', ['/bin/sh','/bin/bash'])
@pytest.mark.parametrize('entry', ['hermes-converger','chief-node-supervisor'])
def test_noop_process_ceiling_and_zero_python(tmp_path, shell, entry):
    host = PulseHost(tmp_path, shell)
    counter = tmp_path/'count-forks.so'
    subprocess.run(['cc','-shared','-fPIC','-Wall','-Werror','-o',str(counter),
                    str(ROOT/'tests/fixtures/count_forks.c'),'-ldl'], check=True)
    trace = tmp_path/'forks'
    path = host.root/'opt/chief/bin'/entry
    # Fixture injection after env -i keeps the real dispatcher and all its forks.
    source=path.read_text().replace('LANG=C ', f'LANG=C LD_PRELOAD={counter} CURRENCY_FORK_LOG={trace} ')
    path.write_text(source)
    out=host.run(entry)
    assert out.returncode==0 and 'python=0' in out.stdout, out.stderr+out.stdout
    events=trace.read_text().splitlines()
    children=events.count('child')
    assert children <= 10, children
    executions=[line[5:] for line in events if line.startswith('exec ')]
    assert executions and not any('python' in pathlib.Path(p).name for p in executions), executions
    calls=host.calls.read_text().splitlines()
    assert calls.count('stat') == 1 and calls.count('ls') == 1
    assert set(calls) <= {'uname','id','stat','ls','sysctl','ioreg','curl','launchctl'}
    # Calibrate against shell-only children too, not just instrumented tools.
    trace.unlink()
    subprocess.run([shell,'-c','( : ); ( : ); /bin/true'], check=True,
                   env={**os.environ,'LD_PRELOAD':str(counter),'CURRENCY_FORK_LOG':str(trace)})
    assert trace.read_text().splitlines().count('child') >= 2
    assert 'exec /bin/true' in trace.read_text()
    print(f'{shell} {entry}: children={children}, Python=0')



@pytest.mark.parametrize('bad', ['owner','mode','acl','link'])
def test_batched_entry_guard_rejects_substitution_before_source(tmp_path, bad):
    host = PulseHost(tmp_path)
    marker = tmp_path/'executed'
    (host.base/'pulse.sh').write_text('echo bad > '+shlex.quote(str(marker)))
    if bad == 'owner': host.tool('stat', "echo '501 755'")
    elif bad == 'mode': host.tool('stat', "echo '0 775'")
    elif bad == 'acl': host.tool('ls', "echo 'drwxr-xr-x+ root wheel fixture'")
    else:
        (host.base/'pulse.sh').unlink()
        payload=tmp_path/'login-payload';payload.write_text('echo bad > '+shlex.quote(str(marker)))
        (host.base/'pulse.sh').symlink_to(payload)
    result = host.run()
    assert result.returncode != 0 and not marker.exists()


def test_boot_reconcile_has_no_long_start_or_network_ordering():
    text = (ROOT/'systemd/chief-node-reconcile.service').read_text()
    assert 'Type=exec\n' in text and 'Type=oneshot' not in text
    assert 'RuntimeMaxSec=1860\n' in text and 'TimeoutStartSec=10\n' in text
    assert not re.search(r'^(Before|After|Requires|Wants)=',text,re.M)
    # The existing owner node unit may retain After=reconcile; exec readiness
    # completes before the worker can issue a restart, so it cannot deadlock.
    baseline=subprocess.check_output(['git','show','c8f7ec5:systemd/chief-node.service'],cwd=ROOT,text=True)
    assert 'chief-node-reconcile.service' in baseline


@pytest.mark.parametrize('stale_success', [False,True])
def test_preparation_failure_returns_contained_receipt(tmp_path, stale_success):
    host = Host(tmp_path)
    if stale_success:
        result=host.run(); assert result.returncode==0,host.output(result)
        (host.state/'prepared').unlink()
    # Fail after stop_jobs but before payload/config/service installation.
    host.tool('dscl','exit 1');host.tool('dseditgroup','exit 1')
    result=host.run()
    assert result.returncode != 0
    receipt=(host.state/'closure-status').read_text()
    assert 'hold: contained:preparation_failed' in receipt
    assert 'jobs: disabled' in receipt and 'grants: removed' in receipt
    assert receipt in result.stdout
    assert not (host.state/'grants-removed').exists()
    assert 'NOPASSWD' not in host.fragment.read_text()


def test_preparing_receipt_visible_before_injected_failure(tmp_path):
    host=Host(tmp_path)
    observed=tmp_path/'observed'
    host.tool('dscl', 'cp '+shlex.quote(str(host.state/'closure-status'))+' '+shlex.quote(str(observed))+'\nexit 1')
    host.tool('dseditgroup','exit 1')
    host.run()
    assert 'hold: preparing\njobs: disabled\ngrants: pending' in observed.read_text()


def test_persistent_revocation_hold_throttles_without_starving_readers(tmp_path):
    host=Host(tmp_path)
    host.tool('sudo', "printf 'Sudoers entry:\\n    Options: !authenticate\\n    Commands:\\n        ALL\\n'")
    result=host.run();assert result.returncode != 0
    receipt=(host.state/'closure-status').read_text()
    assert 'remaining_passwordless_grant:dano:ALL' in receipt and receipt in result.stdout
    assert 'jobs: enabled' in receipt and 'grants: pending' in receipt
    before=host.log.read_text()
    for entry in ('hermes-converger','chief-node-supervisor'):
        result=host.run(entry);assert result.returncode==0,host.output(result)
    actions=host.log.read_text()[len(before):]
    assert 'visudo' not in actions and 'sudo -ll' not in actions
    assert 'boss check-in' in actions and 'health healthy' in actions
    (host.state/'revocation-retry').write_text(str(int(time.time())-1)+'\n')
    before=host.log.read_text()
    result=host.run('hermes-converger');assert result.returncode!=0
    assert 'sudo -ll' in host.log.read_text()[len(before):]
    host.tool('sudo',':')
    (host.state/'revocation-retry').write_text('0\n')
    result=host.run('hermes-converger');assert result.returncode==0,host.output(result)
    assert (host.state/'grants-removed').exists()


@pytest.mark.parametrize('qualified', [False,True])
def test_persistent_unhealthy_supervisor_does_not_start_python_every_minute(tmp_path, qualified):
    host=Host(tmp_path)
    import json
    plan=json.loads(host.plan.read_text());plan['wake_qualified']=qualified;host.sign_plan(plan)
    result=host.run();assert result.returncode==0,host.output(result)
    result=host.run('hermes-converger');assert result.returncode==0,host.output(result)
    p=host.bin/'launchctl';p.write_text(p.read_text().replace('state = running','state = stopped'))
    if qualified:
        # Model an already exhausted limiter / quarantined target.
        (host.root/'var/lib/chief/converger/supervisor-restarts.json').write_text(json.dumps({'launchd:gui/502/com.chief.node':[time.time()]*5}))
    result=host.run('chief-node-supervisor');assert result.returncode==0,host.output(result)
    before=host.log.read_text()
    for _ in range(3):
        result=host.run('chief-node-supervisor')
        assert result.returncode==0 and 'python=0' in result.stdout,host.output(result)
    assert 'health ' not in host.log.read_text()[len(before):]
    (host.state/'last-health').write_text(str(int(time.time())-301)+'\n')
    result=host.run('chief-node-supervisor');assert result.returncode==0,host.output(result)
    assert 'health ' in host.log.read_text()[len(before):]


def test_offline_periodic_has_no_python_but_keeps_explicit_hints(tmp_path):
    host=PulseHost(tmp_path)
    host.tool('curl','exit 1')
    (host.state/'online').write_text('no\n')
    (host.state/'last-check').write_text(str(int(time.time())-600)+'\n')
    result=host.run();assert result.returncode==0 and 'python=0' in result.stdout
    # Replace only the worker boundary with a fixture exit; pending hints must
    # reach it without being consumed by shell even when offline.
    entry=host.root/'opt/chief/bin/hermes-converger'
    source=entry.read_text().replace('trusted_runtime() {','trusted_runtime() { exit 99;\n')
    entry.write_text(source)
    (host.hints/'login').write_text('login\n')
    result=host.run();assert result.returncode==99
    assert (host.hints/'login').read_text()=='login\n'


def test_archive_hashes_private_copy_and_never_uses_changed_transfer(tmp_path):
    source=tmp_path/'transfer.tar';source.write_bytes(b'reviewed tar bytes')
    expected=hashlib.sha256(source.read_bytes()).hexdigest()
    marker=tmp_path/'extracted'
    # Stop at tar: the complete real archive/install path is tested in fix1.
    tar=tmp_path/'tar'
    tar.write_text('#!/bin/sh\nfor p do case "$p" in */payload.tar) /bin/cp "$p" '+shlex.quote(str(marker))+';; esac; done\nexit 77\n');tar.chmod(0o755)
    script=(PAYLOAD/'install-archive.sh').read_text().replace('/usr/bin/tar',str(tar))
    script=script.replace('private=/var/root','private='+str(tmp_path)).replace('private=/root','private='+str(tmp_path))
    script=script.replace('/bin/cp "$archive" "$stage/payload.tar"','/bin/cp "$archive" "$stage/payload.tar"\nprintf tampered > "$archive"')
    path=tmp_path/'installer';path.write_text(script)
    result=subprocess.run(['/bin/sh',str(path),str(source),expected],env={**os.environ,'HOME':str(tmp_path)},text=True,capture_output=True)
    assert result.returncode==77 and marker.read_bytes()==b'reviewed tar bytes'
    marker.unlink()
    result=subprocess.run(['/bin/sh',str(path),str(source),expected],env={**os.environ,'HOME':str(tmp_path)},text=True,capture_output=True)
    assert result.returncode!=0 and 'digest mismatch' in result.stderr and not marker.exists()


def test_interrupted_legacy_copy_can_retry_without_partial_destination(tmp_path):
    host=Host(tmp_path)
    legacy=host.root/'usr/local/lib/hermes-host-bootstrap/hermes_converger'
    legacy.parent.mkdir(parents=True)
    shutil.move(str(host.base.parent),legacy)
    entry=host.root/'usr/local/bin/hermes-converger'
    shutil.copyfile(legacy/'step0/bin/hermes-converger',entry)
    original=entry.read_text()
    copy=tmp_path/'copy'
    copy.write_text('#!/bin/sh\n/bin/cp "$@"\nexit 73\n');copy.chmod(0o755)
    entry.write_text(original.replace('/bin/cp -R',str(copy)+' -R'))
    result=subprocess.run(['/bin/sh',str(entry)],text=True,capture_output=True)
    assert result.returncode==73 and not host.base.parent.exists()
    entry.write_text(original)
    result=subprocess.run(['/bin/sh',str(entry)],text=True,capture_output=True,timeout=15)
    assert result.returncode==0,host.output(result)
    assert (host.state/'grants-removed').exists()


def test_runbook_pins_private_installer_and_archive_before_execution(tmp_path):
    transfer=tmp_path/'transfer';transfer.mkdir()
    marker=tmp_path/'ran'
    installer=transfer/'install-archive.sh'
    installer.write_text('printf reviewed > '+shlex.quote(str(marker))+'\n')
    archive=transfer/'currency-step0.tar';archive.write_bytes(b'reviewed archive')
    source=(ROOT/'docs/currency-step0.md').read_text().split('```sh\numask 077\n',1)[1].split('```',1)[0]
    source='umask 077\n'+source.replace('/var/tmp',str(transfer))
    source=source.replace('<manager installer SHA256>',hashlib.sha256(installer.read_bytes()).hexdigest())
    source=source.replace('<manager archive SHA256>',hashlib.sha256(archive.read_bytes()).hexdigest())
    # Replace both transfer originals AFTER copying; execution must still use
    # the private copies verified by the manager's independently pinned values.
    source=source.replace("currency_installer_sha=", 'printf tampered > '+shlex.quote(str(installer))+'\nprintf tampered > '+shlex.quote(str(archive))+"\ncurrency_installer_sha=",1)
    result=subprocess.run(['/bin/sh'],input=source,env={**os.environ,'HOME':str(tmp_path)},text=True,capture_output=True)
    assert result.returncode==0 and marker.read_text()=='reviewed',result.stderr
    marker.unlink()
    result=subprocess.run(['/bin/sh'],input=source,env={**os.environ,'HOME':str(tmp_path)},text=True,capture_output=True)
    assert result.returncode!=0 and not marker.exists()


def test_failed_activation_never_claims_jobs_enabled(tmp_path):
    host=Host(tmp_path)
    host.tool('launchctl', 'case "$1" in enable|disable|bootout) exit 0;; *) exit 5;; esac')
    result=host.run()
    assert result.returncode!=0
    receipt=(host.state/'closure-status').read_text()
    assert 'jobs: activation_pending' in receipt and 'grants: pending' in receipt
    assert 'jobs: enabled' not in receipt and receipt in result.stdout
    assert (host.state/'revocation-retry').exists()


def test_linux_batched_guard_checks_real_type_and_mode_bits(tmp_path):
    host=PulseHost(tmp_path)
    host.tool('uname','echo Linux')
    # Synthetic ownership only: real lstat types/modes, including the fixed parents.
    host.tool('stat', 'shift 2\nexec /usr/bin/stat -c "0 %f" "$@"')
    (host.state/'supervisor-targets').write_text('systemd chief-node.service yes 0\n')
    result=host.run('chief-node-supervisor')
    assert result.returncode==0 and 'python=0' in result.stdout,result.stderr
    parent=host.root/'opt/chief/lib';parent.chmod(0o775)
    result=host.run('chief-node-supervisor');assert result.returncode!=0
    parent.chmod(0o755)
    target=tmp_path/'user-lib';parent.rename(target);parent.symlink_to(target)
    result=host.run('chief-node-supervisor');assert result.returncode!=0
