"""Review regressions: private host files, OS controls recorded, no live mutation."""
from __future__ import annotations
import hashlib
import json
import os
import pathlib
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
from types import SimpleNamespace

import pytest
from hermes_converger import core, runtime, security, supervisor
from test_currency_step0 import ROOT, PAYLOAD, REGISTRY
from test_converger import make_plan, KEY, NOW


class Host:
    def __init__(self, tmp, platform="Darwin", hostname="h-mini2"):
        self.root = tmp / "host"
        self.base = self.root / "opt/chief/lib/hermes-host-bootstrap/hermes_converger/step0"
        self.state = self.root / "var/lib/chief/currency-step0"
        self.log = tmp / "commands"
        self.bin = tmp / "bin"
        self.bin.mkdir()
        shutil.copytree(ROOT / "hermes_converger", self.base.parent, ignore=shutil.ignore_patterns("__pycache__"))
        for directory in ("usr/local/bin", "opt/chief/bin", "etc/chief", "etc/sudoers.d", "Library/LaunchDaemons", "Library/LaunchAgents",
                          "etc/systemd/system", "usr/lib/systemd", "var/lib", "var/log", "var/run", "run"):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        self.policy = self.root / "etc/sudoers"
        self.policy.write_text("root ALL=(ALL) ALL\n@includedir " + str(self.root / "etc/sudoers.d") + "\n")
        self.policy.chmod(0o440)
        self.fragment = self.root / "etc/sudoers.d/chief"
        self.fragment.write_text("".join("fixture ALL=(root) NOPASSWD: /usr/local/bin/"+n+"\n" for n in ("chief-update", "hermes-converger", "chief-node-supervisor")))
        self.fragment.chmod(0o440)
        self.tool("uname", 'echo '+shlex.quote(platform))
        self.tool("hostname", 'echo '+shlex.quote(hostname))
        self.tool("id", 'echo 0')
        for name in ("getent", "groupadd", "dscl", "dseditgroup", "chown", "sudo", "sync", "curl"):
            self.tool(name, ':')
        self.tool("sysctl", 'echo boot-or-wake')
        self.tool("ioreg", '''echo '\"SystemPowerStateCapabilities\" = 15' ''')
        self.tool("visudo", f'''if [ "$#" = 1 ]; then exec /usr/sbin/visudo -c -f {shlex.quote(str(self.policy))}; fi
exec /usr/sbin/visudo "$@"''')
        self.tool("systemctl", f'''case "$*" in *FragmentPath*) echo {shlex.quote(str(self.root))}/etc/systemd/system/"$2";; esac''')
        self.tool("launchctl", f'''case "$1" in
bootout) rm -f {shlex.quote(str(tmp))}/loaded-*;;
print) case "$2" in gui/*) echo 'state = running';; *) test -f {shlex.quote(str(tmp))}/loaded-"${{2##*/}}";; esac;;
bootstrap) touch {shlex.quote(str(tmp))}/loaded-"$(basename "$3" .plist)";;
esac''')
        installer = self.bin / "install"
        installer.write_text('''#!/usr/bin/python3
import subprocess,sys
args=[]
it=iter(sys.argv[1:])
for arg in it:
    if arg in {'-o','-g'}: next(it)
    else: args.append(arg)
subprocess.run(['/usr/bin/install',*args],check=True)
''')
        installer.chmod(0o755)
        # The real Python runtime/config/verifier/dispatcher execute. Only OS
        # identity, service controls and transport/application side effects fake.
        prelude = f'''
import sys,os,pathlib,json,types
sys.path.append({str(self.base.parent.parent)!r})
from hermes_converger import runtime,security,core,supervisor
security.trusted_path = runtime.trusted_path = core.trusted_path = lambda *a,**k: None
security.socket.gethostname = lambda: {hostname!r}
runtime.os.uname = lambda: types.SimpleNamespace(sysname={platform!r})
runtime.grp.getgrnam = lambda name: types.SimpleNamespace(gr_gid=os.getgid())
runtime.os.chown = lambda *args: None
core.IS_MACOS = {platform == 'Darwin'!r}
supervisor.sys_platform = lambda: {'darwin' if platform == 'Darwin' else 'linux'!r}
supervisor._launchd_target = lambda token,label: 'gui/502/'+label
core._resolve_tool = supervisor._resolve_tool = lambda name: {str(self.bin)!r}+'/'+name
core.utcnow = lambda: __import__('datetime').datetime.fromisoformat({NOW.isoformat()!r})
def record(text):
    with open({str(self.log)!r},'a') as f: f.write(text+'\\n')
core.Transport.get_plan = lambda self: (record('boss check-in') or json.loads(pathlib.Path({str(tmp / 'plan.json')!r}).read_text()))
core.HostOps.emit = lambda self,status,plan,**kw: record('event '+status)
def action(self,plan):
    core.guard_mutation()
    record('apply '+plan.artifact)
core.HostOps.fetch = action
core.HostOps.record_reload_and_signal = lambda self,plan: (action(self,plan) or core.iso_now())
core.HostOps.poll_runtime_ack = lambda *a,**k: {{'method':'fixture'}}
supervisor.SupervisorTransport.emit_health = lambda self,payload: record('health '+payload['status'])
'''
        wrapper = self.bin / "python"
        wrapper.write_text('#!'+sys.executable+'\nimport sys\nexec('+repr(prelude)+'+sys.argv[-1])\n')
        wrapper.chmod(0o755)
        self.trust = f'''set -eu
TRUST_OS={platform}
trusted_entries() {{
    STATE={shlex.quote(str(self.state))}
    CONFIG={shlex.quote(str(self.root/'etc/chief/node.env'))}
    REQUESTS={shlex.quote(str(self.root/'var/lib/chief/requests'))}
}}
trusted_path() {{ :; }}
trusted_tree() {{ :; }}
trusted_python() {{ PY={shlex.quote(str(wrapper))}; export PY; }}
trusted_runtime() {{ trusted_python; }}
hold() {{ HOLD_REASON=$*; echo "HOLD: $*" >&2; return 1; }}
'''
        helpers = (PAYLOAD/'trust.sh').read_text()
        self.trust += helpers[helpers.index('read_state() {'):helpers.index('# Check both sides')]
        dirs = ('/opt/' , '/usr/local/', '/etc/', '/var/', '/Library/', '/usr/lib/systemd', '/run/')
        commands = ('/usr/bin/id', '/usr/bin/uname', '/bin/hostname', '/usr/bin/getent', '/usr/sbin/groupadd',
                    '/usr/bin/dscl', '/usr/sbin/dseditgroup', '/usr/bin/systemctl', '/bin/launchctl', '/bin/chown',
                    '/usr/sbin/chown', '/usr/sbin/visudo', '/usr/bin/sudo', '/bin/sync', '/usr/bin/install',
                    '/usr/bin/curl', '/usr/sbin/sysctl', '/usr/sbin/ioreg')
        for path in self.base.parent.rglob('*'):
            if not path.is_file(): continue
            source = path.read_text()
            if path.parent.name == 'bin' and path.name != 'chief-update-request':
                start = source.index('exec /usr/bin/env')
                args = shlex.split(source[start:])
                body = args[-1]
                a = body.index('# Sourced only after')
                b = body.index('remove_grants() {', a)
                body = body[:a] + self.trust + body[b:]
                source = source[:start] + ' '.join(shlex.quote(v) for v in args[:-1]) + ' ' + shlex.quote(body) + '\n'
            source = source.replace(str(self.root), '@HOST@')
            source = re.sub('|'.join(re.escape(d) for d in dirs), lambda m: '@HOST@'+m[0], source)
            source = source.replace('@HOST@@HOST@', '@HOST@').replace('@HOST@', str(self.root))
            source = re.sub('|'.join(re.escape(c) for c in sorted(commands, key=len, reverse=True)), lambda m: str(self.bin/m[0].rsplit('/',1)[1]), source)
            path.write_text(source)
        (self.base/'trust.sh').write_text(self.trust)
        (self.root/'etc/chief/node-plan.key').write_bytes(KEY)
        self.plan = tmp / 'plan.json'
        plan = make_plan(artifact='theme', apply_mode='live_patch')
        plan['node_id'] = plan['desired'][0]['node_id'] = plan['auth'][0]['node_id'] = hostname
        plan['wake_qualified'] = True
        self.sign_plan(plan)

    def sign_plan(self, plan):
        plan['plan_digest'] = core.sha256_digest(core.canonical_json(core.plan_digest_payload(plan)))
        auth = plan['auth'][0]
        auth['plan_digest'] = plan['plan_digest']
        auth['signature'] = {'alg':'HMAC-SHA256','key_id':'node:'+plan['node_id']+':plan-v1',
                             'value':core.sign_plan_fields(auth, KEY)}
        self.plan.write_text(json.dumps(plan))

    def tool(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/sh\nprintf "%s\\n" '+shlex.quote(name)+'" $*" >> '+shlex.quote(str(self.log))+'\n'+body+'\n')
        path.chmod(0o755)

    def run(self, entry='close.sh'):
        path = self.base/entry if entry.endswith('.sh') else self.root/'opt/chief/bin'/entry
        result = subprocess.run(['/bin/sh', str(path)], text=True, capture_output=True, timeout=15)
        return result

    def output(self, result):
        log = self.root/'var/log/chief-closure.log'
        return result.stdout + result.stderr + (log.read_text() if log.exists() else '')


@pytest.mark.parametrize('platform,host', [('Darwin','h-mini2'),('Linux','h-do1'),('Linux','h-af'),('Linux','h-btp')])
def test_closure_activation_and_idempotence(tmp_path, platform, host):
    fixture = Host(tmp_path, platform, host)
    if host in {'h-af','h-btp'}:
        (fixture.root/'etc/chief/node.env').write_text(f'CHIEF_NODE_ID={host}\nCHIEF_CORE_URL=http://core:8088\n')
    result = fixture.run()
    assert result.returncode == 0, fixture.output(result)
    config = fixture.root/'etc/chief/node.env'
    before = config.stat(), config.read_bytes()
    assert (fixture.state/'grants-removed').exists()
    assert 'NOPASSWD' not in fixture.fragment.read_text()
    assert 'jobs: enabled' in (fixture.state/'closure-status').read_text()
    result = fixture.run()
    assert result.returncode == 0, fixture.output(result)
    assert (config.stat().st_ino, config.stat().st_mtime_ns, config.read_bytes()) == (before[0].st_ino, before[0].st_mtime_ns, before[1])
    assert not (fixture.root/'etc/systemd/system/chief-node.service').exists()


@pytest.mark.parametrize('qualified,caps,apply', [(True,15,True),(True,1,False),(False,15,False)])
def test_mac_post_closure_end_to_end(tmp_path, qualified, caps, apply):
    fixture = Host(tmp_path)
    fixture.tool('ioreg', f'''echo '\"SystemPowerStateCapabilities\" = {caps}' ''')
    plan = json.loads(fixture.plan.read_text()); plan['wake_qualified'] = qualified
    fixture.sign_plan(plan)
    result = fixture.run()
    assert result.returncode == 0, fixture.output(result)
    result = fixture.run('hermes-converger')
    assert result.returncode == 0, fixture.output(result)
    result = fixture.run('chief-node-supervisor')
    assert result.returncode == 0, fixture.output(result)
    actions = fixture.log.read_text()
    assert 'boss check-in' in actions and 'health healthy' in actions
    assert ('apply theme' in actions) is apply
    assert ('event applied' in actions) is apply
    # Second healthy pulse has no Python, scan or repeated reporting.
    result = fixture.run('chief-node-supervisor')
    assert result.returncode == 0 and 'python=0' in result.stdout, fixture.output(result)
    tool = fixture.bin/'launchctl'
    tool.write_text(tool.read_text().replace('state = running', 'state = stopped'))
    before = fixture.log.read_text()
    result = fixture.run('chief-node-supervisor')
    assert result.returncode == 0, fixture.output(result)
    controls = fixture.log.read_text()[len(before):]
    assert ('launchctl kickstart -k gui/502/com.chief.node' in controls) is apply


def test_killed_revocation_resumes_from_fixed_launcher(tmp_path):
    fixture = Host(tmp_path)
    fixture.tool('visudo', f'''if [ -f {shlex.quote(str(fixture.state/'prepared'))} ] && [ ! -f {shlex.quote(str(tmp_path/'killed'))} ]; then
 touch {shlex.quote(str(tmp_path/'killed'))}
 kill -KILL "$PPID"
 exit 1
fi
if [ "$#" = 1 ]; then exec /usr/sbin/visudo -c -f {shlex.quote(str(fixture.policy))}; fi
exec /usr/sbin/visudo "$@"''')
    result = fixture.run()
    assert result.returncode == -signal.SIGKILL
    assert (fixture.state/'prepared').exists() and not (fixture.state/'grants-removed').exists()
    assert 'pending' in (fixture.state/'closure-status').read_text()
    result = fixture.run('chief-node-supervisor')
    assert result.returncode == 0, fixture.output(result)
    assert (fixture.state/'grants-removed').exists()
    assert 'NOPASSWD' not in fixture.fragment.read_text()
    assert 'grants: removed' in result.stdout


@pytest.mark.parametrize('rule', ['/usr/local/bin/chief-*','/usr/local/bin/','ALL'])
def test_effective_wildcard_sudo_grant_fails_loudly(tmp_path, rule):
    fixture = Host(tmp_path)
    if rule.startswith('/'):
        rule = str(fixture.root) + rule
    fixture.tool('sudo', "cat <<'EOF'\nSudoers entry:\n    Options: !authenticate\n    RunAsUsers: root\n    Commands:\n        "+rule+'\nEOF')
    result = fixture.run()
    assert result.returncode != 0
    assert not (fixture.state/'grants-removed').exists()
    assert 'remaining_passwordless_grant' in fixture.output(result)
    assert 'pending' in (fixture.state/'closure-status').read_text()


def test_mac_bootstrap_retries_and_disconnected_caller(tmp_path):
    fixture = Host(tmp_path)
    old = (fixture.bin/'launchctl').read_text()
    (fixture.bin/'launchctl').write_text(old.replace('case "$1" in', f'''if [ "$1" = bootstrap ] && [ ! -f {shlex.quote(str(tmp_path/'retry'))} ]; then touch {shlex.quote(str(tmp_path/'retry'))}; exit 5; fi
case "$1" in'''))
    with subprocess.Popen(['/bin/sh', str(fixture.base/'close.sh')], stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
        process.stdout.close()
        error = process.stderr.read()
        assert process.wait(timeout=15) == 0, error
    assert (fixture.state/'grants-removed').exists()
    assert 'jobs: enabled' in (fixture.state/'closure-status').read_text()


@pytest.mark.parametrize('content,ok', [
    ('# retained\nCHIEF_NODE_ID=h-mini2\nCHIEF_CORE_URL=http://core:8088/\n',True),
    ('CHIEF_NODE_ID=h-mini2\nCHIEF_CORE_URL=http://127.0.0.1:8088\n',False),
    ('CHIEF_NODE_ID=h-air\nCHIEF_CORE_URL=http://core:8088\n',False),
    ('CHIEF_NODE_ID=h-mini2\nCHIEF_CORE_URL=http://core:8088\nOWNER_THING=keep\n',False)])
def test_shell_config_writer_preserves_existing_bytes_and_inode(tmp_path, content, ok):
    fixture = Host(tmp_path)
    config = fixture.root/'etc/chief/node.env'
    config.write_text(content)
    before = config.stat()
    script = fixture.base/'configure.sh'
    result = subprocess.run(['/bin/sh'], input=f'BASE={shlex.quote(str(fixture.base))}\n. "$BASE/trust.sh"\n. "$BASE/configure.sh"\nconfigure_node_env\n', text=True, capture_output=True)
    assert (result.returncode == 0) is ok, result.stderr
    assert config.read_text() == content
    assert config.stat().st_ino == before.st_ino and config.stat().st_mtime_ns == before.st_mtime_ns


def test_fifo_symlink_and_oversized_runtime_stamps_do_not_block(tmp_path, monkeypatch):
    monkeypatch.setattr(core,'runtime_stamp_roots',lambda:[tmp_path])
    stamp = tmp_path/'pid/theme.json'; stamp.parent.mkdir()
    os.mkfifo(stamp)
    assert core.read_runtime_proof('theme','abc1234') is None
    stamp.unlink(); stamp.symlink_to('/dev/zero')
    assert core.read_runtime_proof('theme','abc1234') is None
    stamp.unlink(); stamp.write_bytes(b'x'*65537)
    assert core.read_runtime_proof('theme','abc1234') is None


def test_runtime_deadline_cancels_and_restores_alarm(tmp_path, monkeypatch):
    events=[]
    monkeypatch.setattr(runtime.signal,'alarm',lambda seconds:events.append(seconds))
    monkeypatch.setattr(runtime,'_run',lambda mode: (_ for _ in ()).throw(ValueError('fixture')))
    with pytest.raises(ValueError): runtime.run('converge')
    assert events == [1800,0]


def test_report_only_supervisor_isolates_errors_and_never_controls(tmp_path, monkeypatch):
    allow=tmp_path/'allow.json'; allow.write_text(json.dumps({'units':['chief-core','chief-loop-watchdog','chief-node']}))
    def status(unit):
        if unit=='chief-core': raise security.TrustError('unsafe docker')
        return {'target':unit,'manager':'launchd','active':False}
    monkeypatch.setattr(supervisor,'process_status',status)
    monkeypatch.setattr(supervisor,'mutation_allowed',lambda:False)
    monkeypatch.setattr(supervisor,'restart',lambda *a:pytest.fail('restart'))
    monkeypatch.setattr(supervisor,'enter_crash_looping',lambda *a:pytest.fail('disable'))
    reports=[]
    monkeypatch.setattr(supervisor.SupervisorTransport,'emit_health',lambda self,p:reports.append(p))
    args=SimpleNamespace(allowlist=str(allow),state_dir=str(tmp_path),core='http://core',node_id='h-air',auth_token_path='unused')
    assert supervisor.supervise_once(args)==0
    assert [p['status'] for p in reports]==['unknown','dead','dead']


def test_render_is_deterministic_and_registry_is_generated(tmp_path):
    before={p:p.read_bytes() for p in [*(ROOT/'scripts').glob('chief-*'),ROOT/'scripts/hermes-converger',*PAYLOAD.rglob('*')] if p.is_file() and '__pycache__' not in str(p)}
    subprocess.run([sys.executable,str(ROOT/'scripts/render-currency-step0.py')],check=True)
    assert all(p.read_bytes()==value for p,value in before.items())
    for node, record in REGISTRY.items():
        assert dict(line.split('=',1) for line in (PAYLOAD/'hosts'/f'{node}.env').read_text().splitlines())['CHIEF_RUNTIME_USER']==record['runtime_user']


def test_trusted_clt_python_and_framework_aliases(tmp_path):
    framework = tmp_path/'clt/Library/Frameworks/Python3.framework'
    version = framework/'Versions/3.9'
    version.mkdir(parents=True)
    (framework/'Versions/Current').symlink_to('3.9',target_is_directory=True)
    (framework/'Python3').symlink_to('Versions/Current/Python3')
    (version/'Python3').touch()
    binary=tmp_path/'clt/usr/bin/python3'; binary.parent.mkdir(parents=True)
    ran=tmp_path/'ran'
    binary.write_text('#!/bin/sh\necho "$*" >> '+shlex.quote(str(ran))+'\n'); binary.chmod(0o755)
    stat=tmp_path/'stat'; stat.write_text('#!/bin/sh\necho "0 755"\n'); stat.chmod(0o755)
    source=(PAYLOAD/'trust.sh').read_text().replace('/bin/ls -lde','/bin/ls -ld').replace('! -user root',f'! -uid {os.getuid()}').replace('/usr/bin/stat',str(stat)).replace('/Library/Developer/CommandLineTools',str(tmp_path/'clt')).replace('/opt/chief/python',str(tmp_path/'absent'))
    run=lambda:subprocess.run(['/bin/sh'],input=source+'\nTRUST_OS=Darwin\ntrusted_python\necho "$PY"\n',text=True,capture_output=True,timeout=10)
    result=run()
    assert result.returncode==0 and str(binary) in result.stdout, result.stderr
    assert ran.read_text().startswith('-I -S -B -c')
    ran.unlink(); (version/'Python3').chmod(0o666)
    result=run()
    assert result.returncode!=0 and not ran.exists()


def test_runtime_trust_cache_hits_and_identity_invalidation(tmp_path):
    state=tmp_path/'state'; state.mkdir()
    base=tmp_path/'package/step0'; base.mkdir(parents=True)
    for name in ('trust.sh','pulse.sh','supervise.sh'): (base/name).touch()
    runtime_tree=tmp_path/'runtime'; runtime_tree.mkdir()
    binary=runtime_tree/'python'; binary.write_text('first')
    scan=tmp_path/'scans'
    source=(PAYLOAD/'trust.sh').read_text().replace('/var/lib/chief/currency-step0',str(state))
    setup=f'''
BASE={shlex.quote(str(base))}
trusted_path() {{ :; }}
select_python() {{ PY={shlex.quote(str(binary))}; PY_TREE={shlex.quote(str(runtime_tree))}; }}
trusted_python() {{ echo version >> {shlex.quote(str(scan))}; }}
trusted_tree() {{ echo scan >> {shlex.quote(str(scan))}; }}
trusted_runtime
'''
    run=lambda:subprocess.run(['/bin/sh'],input=source+setup,text=True,capture_output=True)
    assert run().returncode==0
    assert scan.read_text()=='scan\nversion\n'
    assert run().returncode==0 and scan.read_text()=='scan\nversion\n'
    binary.write_text('replaced interpreter bytes')
    assert run().returncode==0 and scan.read_text()=='scan\nversion\nscan\nversion\n'
    for name in ('pulse.sh','supervise.sh'):
        before=scan.read_text()
        (base/name).write_text('new entry bytes')
        assert run().returncode==0 and scan.read_text()==before+'scan\nversion\n'


def test_signed_wake_field_cannot_be_added_after_signature():
    plan=make_plan()
    plan['wake_qualified']=True
    with pytest.raises(core.VerificationError,match='plan_digest_mismatch'):
        core.verify_plan(plan,node_id='h-do1',key_lookup=lambda _:KEY,now=NOW)


def test_post_closure_transient_trust_failure_keeps_jobs_enabled(tmp_path):
    fixture=Host(tmp_path)
    result=fixture.run(); assert result.returncode==0,fixture.output(result)
    before=fixture.log.read_text()
    trust=fixture.root/'opt/chief/bin/hermes-converger'
    trust.write_text(trust.read_text().replace('trusted_runtime() { trusted_python; }','trusted_runtime() { hold unavailable; }'))
    result=fixture.run('hermes-converger')
    assert result.returncode!=0
    new=fixture.log.read_text()[len(before):]
    assert 'bootout' not in new and 'disable' not in new
    assert (fixture.state/'grants-removed').exists()


def test_real_git_archive_installer_uses_safe_modes(tmp_path):
    # Build exactly the runbook artifact from a real Git tree, including its
    # default umask trap. Metadata ownership is synthetic; trust code is real.
    repo=tmp_path/'repo'; repo.mkdir()
    shutil.copytree(ROOT/'hermes_converger',repo/'hermes_converger',ignore=shutil.ignore_patterns('__pycache__'))
    subprocess.run(['git','init','-q',str(repo)],check=True)
    subprocess.run(['git','-C',str(repo),'add','.'],check=True)
    tree=subprocess.check_output(['git','-C',str(repo),'write-tree'],text=True).strip()
    archive=tmp_path/'payload.tar'
    with archive.open('wb') as f:
        subprocess.run(['git','-C',str(repo),'-c','tar.umask=022','archive','--format=tar',tree,'hermes_converger'],stdout=f,check=True)
    host=tmp_path/'target'; host.mkdir(); (host/'var').mkdir()
    # Stage/extract and run the real trust check and install block. Stop at
    # close.sh (its execution is covered by the Host fixtures above).
    stat=tmp_path/'stat'
    stat.write_text('#!/bin/sh\nfor p do :; done\necho "0 $(/usr/bin/stat -c %a "$p")"\n');stat.chmod(0o755)
    trust=(repo/'hermes_converger/step0/trust.sh').read_text()
    trust=trust.replace('/usr/bin/stat',str(stat)).replace('! -user root',f'! -uid {os.getuid()}')
    # Only fake ancestor ownership/mode of tmp; payload modes remain real.
    stat.write_text('#!/bin/sh\nfor p do :; done\ncase "$p" in '+shlex.quote(str(tmp_path))+'/*) echo "0 $(/usr/bin/stat -c %a "$p")";; *) echo "0 755";; esac\n')
    (repo/'hermes_converger/step0/trust.sh').write_text(trust)
    contain=(repo/'hermes_converger/step0/contain.sh').read_text()
    contain=contain.replace('/var/lib',str(host)+'/var/lib').replace('/usr/bin/systemctl','/bin/true')
    contain=contain.replace('/usr/bin/install -d -o root','/usr/bin/install -d')
    (repo/'hermes_converger/step0/contain.sh').write_text(contain)
    subprocess.run(['git','-C',str(repo),'add','.'],check=True)
    tree=subprocess.check_output(['git','-C',str(repo),'write-tree'],text=True).strip()
    with archive.open('wb') as f:
        subprocess.run(['git','-C',str(repo),'-c','tar.umask=022','archive','--format=tar',tree,'hermes_converger'],stdout=f,check=True)
    source=(PAYLOAD/'install-archive.sh').read_text().replace('private=/var/root','private='+str(host)).replace('private=/root','private='+str(host))
    source=source.replace('/opt',str(host)+'/opt').replace('/var/lib/chief',str(host)+'/var/lib/chief')
    source=source.replace('/usr/bin/install -d -o root','/usr/bin/install -d')
    source=source.replace('/bin/sh "$base/hermes_converger/step0/close.sh"','trusted_tree "$base/hermes_converger"')
    script=tmp_path/'install.sh';script.write_text(source)
    result=subprocess.run(['/bin/sh',str(script),str(archive),hashlib.sha256(archive.read_bytes()).hexdigest()],env={**os.environ,'HOME':str(host)},text=True,capture_output=True)
    assert result.returncode==0,result.stderr
    installed=host/'opt/chief/lib/hermes-host-bootstrap/hermes_converger'
    assert installed.is_dir()
    assert all(not p.stat().st_mode & 0o022 for p in installed.rglob('*'))


def test_core_policy_patch_field_is_inside_the_signed_digest():
    # Exercise the producer expression shipped as a reviewable Core patch.
    patch=(ROOT/'patches/chief-core-step0-wake-qualified.patch').read_text()
    line=next(line[1:].strip() for line in patch.splitlines() if line.startswith('+        "wake_qualified":'))
    node_id='h-mini2'
    for setting, expected in [('',False),('h-mini2,h-air',True),(' h-mini2 , h-air ',True),('h-mini',False)]:
        data=eval('{'+line+'}', {'os':SimpleNamespace(environ={'CHIEF_WAKE_QUALIFIED_NODES':setting}), 'node_id':node_id})
        assert data['wake_qualified'] is expected
        plan=make_plan(); before=core.plan_digest_payload(plan)
        assert core.sha256_digest(core.canonical_json({**before,**data})) != plan['plan_digest']


def test_legacy_delivery_relocates_to_canonical_root_home(tmp_path):
    fixture=Host(tmp_path)
    legacy=fixture.root/'usr/local/lib/hermes-host-bootstrap/hermes_converger'
    legacy.parent.mkdir(parents=True)
    shutil.move(str(fixture.base.parent),legacy)
    entry=fixture.root/'usr/local/bin/hermes-converger'
    shutil.copyfile(legacy/'step0/bin/hermes-converger',entry)
    result=subprocess.run(['/bin/sh',str(entry)],text=True,capture_output=True,timeout=15)
    assert result.returncode==0,fixture.output(result)
    assert (fixture.root/'opt/chief/bin/hermes-converger').exists()
    assert (fixture.state/'grants-removed').exists()
    assert '/opt/chief/bin/hermes-converger' in (fixture.root/'Library/LaunchDaemons/com.chief.node-reconcile.plist').read_text()


def test_changed_wake_epoch_defers_even_a_qualified_signed_plan(tmp_path, monkeypatch):
    plan=make_plan();plan['wake_qualified']=True
    from test_converger import refresh_plan_auth
    refresh_plan_auth(plan)
    planfile=tmp_path/'plan';planfile.write_text(json.dumps(plan))
    key=tmp_path/'key';key.write_bytes(KEY)
    args=core.build_parser().parse_args(['--node-id','h-do1','--core','http://fixture',
        '--state-root',str(tmp_path),'--plan-file',str(planfile),'--plan-key-path',str(key),'converge'])
    args.step0=True;args.step0_wake_id='before-sleep'
    monkeypatch.setattr(core,'utcnow',lambda:NOW)
    monkeypatch.setattr(runtime,'wake_identity',lambda:'after-sleep')
    monkeypatch.setattr(runtime,'full_wake',lambda qualified:True)
    monkeypatch.setattr(core,'execute_plan',lambda *a:pytest.fail('old authorization applied'))
    events=[]
    monkeypatch.setattr(core.HostOps,'emit',lambda self,status,plan,**kw:events.append(status))
    # Restore the callback because the production entry is process-isolated.
    previous=core.mutation_allowed
    try:
        assert core.converge(args)==0
        assert events==['deferred']
    finally:
        core.mutation_allowed=previous


@pytest.mark.parametrize('hostname', ['h-af','h-btp'])
def test_preserved_config_and_allowlist_never_rewritten(tmp_path, hostname):
    fixture=Host(tmp_path,'Linux',hostname)
    config=fixture.root/'etc/chief/node.env'
    config.write_text(f'# owner bytes\nCHIEF_NODE_ID={hostname}\nCHIEF_CORE_URL=http://core:8088\n')
    allow=fixture.root/'etc/chief/supervisor-allowlist.json';allow.write_text('{ "units": ["chief-node"] }\n')
    before=[(p.stat().st_ino,p.stat().st_mtime_ns,p.read_bytes()) for p in (config,allow)]
    result=fixture.run();assert result.returncode==0,fixture.output(result)
    assert before==[(p.stat().st_ino,p.stat().st_mtime_ns,p.read_bytes()) for p in (config,allow)]
    result=fixture.run('chief-node-supervisor');assert result.returncode==0,fixture.output(result)


def test_exact_legacy_mac_allowlist_repaired_and_audited(tmp_path):
    fixture=Host(tmp_path)
    allow=fixture.root/'etc/chief/supervisor-allowlist.json'
    allow.write_text('{"units":["chief-node.service","chief-loop-watchdog.service","chief-stack-core-1"]}')
    result=fixture.run();assert result.returncode==0,fixture.output(result)
    assert json.loads(allow.read_text())=={'units':['chief-node']}
    assert 'supervisor_allowlist' in fixture.output(result)


@pytest.mark.parametrize('status,expected', [('healthy','healthy'),('dead','unhealthy'),('restarting','unhealthy'),('crash_looping','crash_looping'),('unknown','unknown')])
def test_health_transport_posts_schema_valid_observation(tmp_path, monkeypatch, status, expected):
    requests=[]
    class Response:
        def __enter__(self): return self
        def __exit__(self,*args): pass
        def read(self): return b'{}'
    def urlopen(request, **kwargs):
        requests.append(request)
        return Response()
    monkeypatch.setattr(core.urllib.request,'urlopen',urlopen)
    token=tmp_path/'token';token.write_text('fixture-token')
    tx=supervisor.SupervisorTransport('http://boss','h-mini2',token)
    tx.emit_health({'process_id':'chief-node','manager':'launchd','status':status,
                    'manager_restart_count':0,'observed_at':NOW.isoformat()})
    assert requests[0].full_url=='http://boss/v1/observations'
    assert requests[0].get_header('Authorization')=='Bearer fixture-token'
    envelope=json.loads(requests[0].data)
    assert envelope['data']['status']==expected
    assert envelope['data']['manager']=='supervisor:launchd'
    assert envelope['data']['loaded_ref']=='unknown'
    # Transport.emit calls the installed Spec validator when available, and the
    # isolated 3.9 runtime uses the existing stdlib envelope validator.
    core.validate_envelope(envelope)
