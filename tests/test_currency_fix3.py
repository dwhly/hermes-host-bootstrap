"""Round 3: private hosts with service controls that really terminate callers."""
from __future__ import annotations

import hashlib
import pathlib
import shlex
import shutil
import signal
import subprocess
import tarfile
import time

import pytest

from test_currency_fix1 import Host
from test_currency_fix2 import PulseHost
from test_currency_step0 import PAYLOAD, ROOT


PLATFORMS = [('Darwin', 'h-mini2'), ('Linux', 'h-do1')]


class ManagedHost(Host):
    """Model enable/start/stop and SIGTERM the fixture job on its own stop.

    The PID is published by the child wrapper itself, never a live host PID.
    Both old disable --now and new stop controls have real termination semantics.
    """
    def __init__(self, tmp, platform, hostname):
        super().__init__(tmp, platform, hostname)
        self.platform = platform
        self.manager = tmp/'manager'
        self.manager.mkdir()
        self.pidfile = self.manager/'job-pid'
        self.caller = 'com.chief.update-request' if platform == 'Darwin' else 'chief-update.service'
        self.triggers = (['com.chief.node-reconcile', 'com.chief.node-supervisor', 'com.chief.update-request']
                         if platform == 'Darwin' else
                         ['chief-node-reconcile.service', 'chief-node-supervisor.timer',
                          'chief-update.timer', 'chief-update-request.path'])
        common = f'''manager={shlex.quote(str(self.manager))}
state={shlex.quote(str(self.state))}
stop_job() {{
    rm -f "$manager/running-$unit"
    if [ "$unit" = {shlex.quote(self.caller)} ] && [ -f "$manager/job-pid" ]; then
        read -r caller < "$manager/job-pid"
        if kill -0 "$caller" 2>/dev/null; then
            cp "$state/closure-status" "$manager/receipt-at-kill"
            kill -TERM "$caller"
        fi
    fi
}}
'''
        if platform == 'Darwin':
            body = '''unit=${2##*/}
case "$1" in
    disable) rm -f "$manager/enabled-$unit";;
    enable) touch "$manager/enabled-$unit";;
    bootout) stop_job;;
    print) case "$2" in gui/*) echo 'state = running';;
        *) test -f "$manager/running-$unit";; esac;;
    bootstrap) unit=${3##*/}; unit=${unit%.plist}; touch "$manager/running-$unit";;
esac'''
            self.tool('launchctl', common+body)
        else:
            body = f'''case "$*" in *FragmentPath*) echo {shlex.quote(str(self.root))}/etc/systemd/system/"$2"; exit;; esac
action=$1; shift
case "$action" in
    disable)
        now=no
        for unit do
            if [ "$unit" = --now ]; then now=yes; continue; fi
            rm -f "$manager/enabled-$unit"
            [ "$now" = no ] || stop_job
        done;;
    stop) for unit do stop_job; done;;
    enable) for unit do touch "$manager/enabled-$unit"; done;;
    start) for unit do touch "$manager/running-$unit"; done;;
esac'''
            self.tool('systemctl', common+body)

    def start_job(self, pause=False):
        if pause:
            path = self.base/'close.sh'
            source = path.read_text()
            barrier = f'''
if [ -f {shlex.quote(str(self.pidfile))} ]; then
    read -r job < {shlex.quote(str(self.pidfile))}
    if [ "$$" = "$job" ]; then
        touch {shlex.quote(str(self.manager/'locked'))}
        while [ ! -f {shlex.quote(str(self.manager/'resume'))} ]; do /bin/sleep 0.02; done
    fi
fi
'''
            source = source.replace('cleanup() {', barrier+'\ncleanup() {', 1)
            path.write_text(source)
        wrapper = f'echo $$ > {shlex.quote(str(self.pidfile))}\nexec /bin/sh {shlex.quote(str(self.root/"opt/chief/bin/hermes-converger"))}'
        return subprocess.Popen(['/bin/sh', '-c', wrapper], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def assert_enabled(self):
        assert all((self.manager/('enabled-'+name)).exists() for name in self.triggers)
        running = self.triggers if self.platform == 'Darwin' else self.triggers[1:]
        assert all((self.manager/('running-'+name)).exists() for name in running)
        receipt = (self.state/'closure-status').read_text()
        assert receipt == 'hold: none\njobs: enabled\ngrants: removed\n'
        assert (self.state/'grants-removed').exists()

    def remove_markers(self):
        for name in ('prepared', 'grants-removed'):
            (self.state/name).unlink()


def wait_file(path):
    deadline = time.monotonic()+10
    while not path.exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    assert path.exists(), path


@pytest.mark.parametrize('platform,hostname', PLATFORMS)
@pytest.mark.parametrize('race', [False, True], ids=['interrupted-marker-removal', 'job-wins-lock'])
def test_root_job_recovers_marker_loss_without_stopping_itself(tmp_path, platform, hostname, race):
    host = ManagedHost(tmp_path, platform, hostname)
    result = host.run(); assert result.returncode == 0, host.output(result)
    host.remove_markers()
    job = host.start_job(pause=race)
    try:
        if race:
            wait_file(host.manager/'locked')
            admin = host.run()
            assert admin.returncode == 75 and 'revocation pending' in admin.stdout
            (host.manager/'resume').touch()
        stdout, stderr = job.communicate(timeout=15)
        assert job.returncode == 0, stdout+stderr
    finally:
        if job.poll() is None:
            job.kill(); job.communicate()
    assert not (host.manager/'receipt-at-kill').exists()
    host.assert_enabled()
    # Subsequent minute readers really check in/report instead of re-entering
    # closure in the old disable --now death loop.
    before = host.log.read_text()
    for entry in ('hermes-converger', 'chief-node-supervisor'):
        result = host.run(entry); assert result.returncode == 0, host.output(result)
    actions = host.log.read_text()[len(before):]
    assert 'boss check-in' in actions and 'health ' in actions
    assert ' disable ' not in actions and 'visudo ' not in actions


@pytest.mark.parametrize('platform,hostname', PLATFORMS)
@pytest.mark.parametrize('failure', ['unsafe-definition', 'preparation-failed'])
def test_terminated_root_job_has_current_hold_and_no_enabled_trigger(tmp_path, platform, hostname, failure):
    host = ManagedHost(tmp_path, platform, hostname)
    result = host.run(); assert result.returncode == 0, host.output(result)
    host.remove_markers()
    if failure == 'unsafe-definition':
        definition = host.root/('Library/LaunchDaemons/com.chief.update-request.plist'
                                if platform == 'Darwin' else 'etc/systemd/system/chief-update.service')
        definition.write_text(definition.read_text()+'\n# obsolete definition\n')
    else:
        for tool in (('dscl', 'dseditgroup') if platform == 'Darwin' else ('getent', 'groupadd')):
            host.tool(tool, 'exit 1')
    job = host.start_job()
    job.communicate(timeout=15)
    assert job.returncode == -signal.SIGTERM
    receipt = (host.manager/'receipt-at-kill').read_text()
    assert 'hold: none' not in receipt and 'jobs: disabled' in receipt
    assert ('hold: preparing' if failure == 'unsafe-definition' else 'hold: contained:preparation_failed') in receipt
    assert receipt == (host.state/'closure-status').read_text()
    assert not any((host.manager/('enabled-'+name)).exists() for name in host.triggers)
    assert 'NOPASSWD' not in host.fragment.read_text()
    # The documented administrator recovery reclaims the killed holder's lock.
    host.pidfile.unlink()
    for tool in ('dscl', 'dseditgroup', 'getent', 'groupadd'):
        host.tool(tool, ':')
    result = host.run(); assert result.returncode == 0, host.output(result)
    host.assert_enabled()


@pytest.mark.parametrize('platform,hostname', PLATFORMS)
@pytest.mark.parametrize('entry', ['install-archive.sh', 'update.sh'])
def test_admin_update_stops_before_marker_or_payload_loss_and_recovers(tmp_path, platform, hostname, entry):
    host = ManagedHost(tmp_path, platform, hostname)
    result = host.run(); assert result.returncode == 0, host.output(result)
    # Every disable/stop sees intact markers and payload, and a new hold receipt.
    tool = host.bin/('launchctl' if platform == 'Darwin' else 'systemctl')
    original = tool.read_text()
    checks = f'''
case "$1" in disable|bootout|stop)
    test -f {shlex.quote(str(host.state/'prepared'))} || exit 91
    test -f {shlex.quote(str(host.state/'grants-removed'))} || exit 92
    test -f {shlex.quote(str(host.base/'close.sh'))} || exit 93
    /usr/bin/grep -q '^hold: preparing$' {shlex.quote(str(host.state/'closure-status'))} || exit 94
    touch {shlex.quote(str(host.manager/'intact-at-stop'))};;
esac
'''
    tool.write_text(original.replace('manager=', checks+'\nmanager=', 1))
    # Source for the update is a private copy, with every OS control already
    # redirected to this fixture. No git network or live manager is ever called.
    source_tree = tmp_path/'reviewed'
    shutil.copytree(host.base.parent, source_tree/'hermes_converger')
    script = host.base/entry
    source = script.read_text()
    if entry == 'install-archive.sh':
        archive = tmp_path/'payload.tar'
        with tarfile.open(archive, 'w') as tar:
            tar.add(source_tree/'hermes_converger', arcname='hermes_converger')
        args = [str(archive), hashlib.sha256(archive.read_bytes()).hexdigest()]
        source = source.replace('private=/root', 'private='+shlex.quote(str(tmp_path)))
        source = source.replace('private='+str(host.root/'var/root'), 'private='+shlex.quote(str(tmp_path)))
    else:
        host.tool('git', f'''case "$*" in
    *clone*) for destination do :; done; mkdir "$destination"; cp -R {shlex.quote(str(source_tree/'hermes_converger'))} "$destination/";;
esac''')
        # Assert the actual pinned checkout command in the recorder below.
        args = ['a'*40]
        source = source.replace(str(host.root/'Library/Developer/CommandLineTools/usr/bin/git'), str(host.bin/'git'))
        source = source.replace('/usr/bin/git', str(host.bin/'git'))
    installer = tmp_path/entry
    remove = '/bin/rm -f '+str(host.state/'prepared')+' '+str(host.state/'grants-removed')
    assert remove in source
    # Abrupt session loss immediately after rm: the surviving receipt is current
    # and all triggers are already disabled. No stale success or timer loop.
    installer.write_text(source.replace(remove, remove+'\nkill -KILL $$', 1))
    result = subprocess.run(['/bin/sh', str(installer), *args], text=True, capture_output=True, timeout=15)
    assert result.returncode == -signal.SIGKILL, result.stdout+result.stderr
    assert (host.manager/'intact-at-stop').exists()
    assert not any((host.manager/('enabled-'+name)).exists() for name in host.triggers)
    assert (host.state/'closure-status').read_text() == 'hold: preparing\njobs: disabled\ngrants: pending\n'
    assert host.base.is_dir() and not (host.state/'prepared').exists()
    tool.write_text(original)
    installer.write_text(source)
    result = subprocess.run(['/bin/sh', str(installer), *args], text=True, capture_output=True, timeout=15)
    assert result.returncode == 0, host.output(result)
    host.assert_enabled()
    assert not list(host.base.parent.parent.glob('previous.*'))
    if entry == 'update.sh':
        assert 'checkout --quiet --detach '+args[0] in host.log.read_text()


@pytest.mark.parametrize('commit', ['', 'main', 'a'*39, 'a'*41, '-'+('a'*39)])
def test_update_rejects_unpinned_ref_before_any_host_access(commit):
    result = subprocess.run(['/bin/sh', str(PAYLOAD/'update.sh'), *([commit] if commit else [])], capture_output=True)
    assert result.returncode == 2


@pytest.mark.parametrize('platform', ['Darwin', 'Linux'])
def test_core_probe_retries_one_miss_and_bounds_offline_suppression(tmp_path, platform):
    host = PulseHost(tmp_path)
    if platform == 'Linux':
        host.tool('uname', 'echo Linux')
        host.tool('stat', 'shift 2\nexec /usr/bin/stat -c "0 %f" "$@"')
        (host.state/'boot').write_text(pathlib.Path('/proc/sys/kernel/random/boot_id').read_text())
        (host.state/'wake').write_text('linux\n')
    attempts = tmp_path/'attempts'
    host.tool('curl', f'''echo "$*" >> {shlex.quote(str(attempts))}
test -f {shlex.quote(str(tmp_path/'missed'))} && exit 0
touch {shlex.quote(str(tmp_path/'missed'))}
exit 28''')
    result = host.run(); assert result.returncode == 0, result.stderr
    assert len(attempts.read_text().splitlines()) == 2
    assert all('--max-time 3 --connect-timeout 3' in row for row in attempts.read_text().splitlines())
    assert (host.state/'online').read_text().strip() == 'yes'
    assert not (host.hints/'network').read_text()
    host.tool('curl', 'exit 28')
    entry = host.root/'opt/chief/bin/hermes-converger'
    entry.write_text(entry.read_text().replace('trusted_runtime() {', 'trusted_runtime() { exit 99;\n'))
    (host.state/'last-check').write_text(str(int(time.time())-600)+'\n')
    result = host.run(); assert result.returncode == 0, result.stderr
    (host.state/'last-check').write_text(str(int(time.time())-1801)+'\n')
    result = host.run(); assert result.returncode == 99, result.stderr


def test_mac_log_cap_preserves_open_append_descriptors(tmp_path):
    host = PulseHost(tmp_path)
    logs = host.root/'var/log'; logs.mkdir(parents=True)
    paths = [logs/(label+suffix) for label in ('com.chief.node-reconcile', 'com.chief.node-supervisor', 'com.chief.update-request')
             for suffix in ('.log', '.err')]
    for path in paths: path.write_bytes(b'x'*1048576)
    # Darwin stat shape with synthetic root ownership; actual file type/size.
    host.tool('stat', '''shift 2
for path do
    if [ -L "$path" ]; then mode=120777; else mode=100644; fi
    size=0
    if [ -f "$path" ]; then size=$(/usr/bin/stat -c %s "$path"); fi
    printf '0 %s %s %s\n' "$mode" "$size" "$path"
done''')
    with paths[0].open('ab') as opened:
        result = host.run(); assert result.returncode == 0, result.stderr
        assert all(path.stat().st_size == 0 for path in paths)
        opened.write(b'still logged\n'); opened.flush()
    result = host.run('chief-node-supervisor'); assert result.returncode == 0, result.stderr
    assert paths[0].read_bytes() == b'still logged\n'
    # An oversized linked log must be refused, never truncate its target.
    outside = tmp_path/'other'; outside.write_bytes(b'z'*1048576)
    paths[0].unlink(); paths[0].symlink_to(outside)
    result = host.run(); assert result.returncode != 0
    assert outside.stat().st_size == 1048576


def test_login_hint_failure_is_ignored_by_user_manager():
    assert 'ExecStart=-/opt/chief/bin/chief-update-request\n' in (ROOT/'systemd/chief-update-login.service').read_text()
