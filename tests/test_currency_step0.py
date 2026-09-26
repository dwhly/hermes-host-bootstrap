"""Offline Step 0 fixtures. No sudo, service manager, host, or network calls."""
from __future__ import annotations
import contextlib
import datetime as dt
import fcntl
import io
import json
import os
import re
import pathlib
import plistlib
import shlex
import stat
import subprocess
import sys
from types import SimpleNamespace
import urllib.error

import pytest
from hermes_converger import core, runtime, security
from test_converger import make_plan, KEY, NODE, NOW

ROOT = pathlib.Path(__file__).resolve().parents[1]
PAYLOAD = ROOT / "hermes_converger/step0"
REGISTRY = json.loads((PAYLOAD / "host-contracts.json").read_text())


@pytest.fixture
def metadata(monkeypatch, tmp_path):
    """Synthetic root ownership, with real filesystem contents and modes."""
    original = pathlib.Path.lstat
    changes = {}
    observed = []
    def lstat(path):
        info = list(original(path))
        observed.append(path)
        info[4] = 0  # uid, without chown or root
        if path in tmp_path.parents:
            info[0] = stat.S_IFDIR | 0o755
        if path in changes:
            info[4], mode = changes[path]
            info[0] = stat.S_IFMT(info[0]) | mode
        return os.stat_result(info)
    monkeypatch.setattr(pathlib.Path, "lstat", lstat)
    original_fstat = os.fstat
    def fstat(fd):
        info = list(original_fstat(fd))
        info[4] = 0
        return os.stat_result(info)
    monkeypatch.setattr(os, "fstat", fstat)
    return changes, observed


@pytest.mark.parametrize("bad_part", ["parent", "binary", "import"])
@pytest.mark.parametrize("uid,mode", [(501,0o755),(0,0o775),(0,0o777)])
def test_python_or_import_substitution_rejected(tmp_path, metadata, bad_part, uid, mode):
    changes, observed = metadata
    parent = tmp_path / "runtime"
    parent.mkdir()
    binary = parent / "python3"
    binary.write_text("malicious")
    module = parent / "os.py"
    module.write_text("malicious")
    changes[{"parent":parent,"binary":binary,"import":module}[bad_part]] = (uid,mode)
    with pytest.raises(security.TrustError, match="untrusted_path"):
        security.trusted_path(parent, tree=True)
    assert pathlib.Path("/") in observed


def test_symlink_target_parent_validated(tmp_path, metadata):
    changes, _ = metadata
    user = tmp_path / "login"
    user.mkdir()
    python = user / "python3"
    python.touch()
    link = tmp_path / "root-python"
    link.symlink_to(python)
    changes[user] = (501, 0o755)
    with pytest.raises(security.TrustError):
        security.trusted_path(link)


@pytest.mark.parametrize("launcher", ["hermes-converger", "chief-node-supervisor", "chief-update"])
@pytest.mark.parametrize("attack", [["--core","http://attacker"],["--state-root","/tmp"],["--plan-key-path","/tmp/key"],["--plan-file","/tmp/plan"],["--loop"],["-c","evil"]])
def test_launchers_reject_caller_argv_before_any_privileged_code(launcher, attack, tmp_path):
    marker = tmp_path / "pwned"
    evil = tmp_path / "startup"
    evil.write_text(f"touch {shlex.quote(str(marker))}\n")
    out = subprocess.run(["/bin/sh", str(ROOT / "scripts" / launcher), *attack],
                         env={"PATH":str(tmp_path), "HOME":str(tmp_path), "BASH_ENV":str(evil), "ENV":str(evil)},
                         text=True, capture_output=True)
    assert out.returncode == 2 and "arguments refused" in out.stderr
    assert not marker.exists()


def test_isolated_python_ignores_venv_site_cwd_and_env(tmp_path):
    marker = tmp_path / "pwned"
    for name in ("sitecustomize.py", "usercustomize.py", "os.py"):
        (tmp_path / name).write_text(f"open({str(marker)!r},'w').write('bad')")
    (tmp_path / "hermes_converger").mkdir()
    (tmp_path / "hermes_converger/__init__.py").write_text(f"open({str(marker)!r},'w').write('bad')")
    env = dict(os.environ, PYTHONPATH=str(tmp_path), PYTHONHOME=str(tmp_path), VIRTUAL_ENV=str(tmp_path), HOME=str(tmp_path))
    code = f"import sys; sys.path.insert(0,{str(ROOT)!r}); import hermes_converger.core as c; print(c.__file__)"
    result = subprocess.run([sys.executable,"-I","-S","-B","-c",code], cwd=tmp_path, env=env, text=True,capture_output=True)
    assert result.returncode == 0, result.stderr
    assert str(ROOT / "hermes_converger/core.py") in result.stdout
    assert not marker.exists()


def test_dispatcher_clears_all_caller_environment(tmp_path):
    # Execute the generated, real prelude up to the trust functions, then observe
    # its environment. No production action/body or privileged path is executed.
    launcher = (ROOT / "scripts/hermes-converger").read_text()
    prefix = launcher.split(" /bin/sh -c ", 1)[0] + " /bin/sh -c "
    probe = tmp_path / "probe.sh"
    probe.write_text(prefix + shlex.quote("/usr/bin/env") + "\n")
    env = dict(os.environ, PYTHONPATH="/evil", CHIEF_CORE_URL="http://evil", CHIEF_CODE_ROOT="/evil",
               SUDO_UID="501", GIT_CONFIG_COUNT="1", BASH_ENV="/evil", VIRTUAL_ENV="/evil", OSTYPE="evil", EUID="501")
    out = subprocess.run(["/bin/sh",str(probe)],env=env,text=True,capture_output=True,check=True)
    assert "evil" not in out.stdout and "SUDO_UID=" not in out.stdout
    assert "HOME=/var/empty" in out.stdout


def test_root_tool_lookup_ignores_login_path(monkeypatch, tmp_path):
    monkeypatch.setenv("PATH", str(tmp_path))
    monkeypatch.setenv("SUDO_USER", "attacker")
    monkeypatch.setenv("LD_PRELOAD", "/evil")
    monkeypatch.setattr(core, "trusted_path", lambda p: None)
    assert core._resolve_tool("sh") in {"/usr/bin/sh", "/bin/sh"}
    assert "LD_PRELOAD" not in core._tool_subprocess_env()
    assert str(tmp_path) not in core._tool_subprocess_env()["PATH"]


def test_git_and_build_code_drop_privilege_before_exec(monkeypatch, tmp_path):
    monkeypatch.setenv("CHIEF_RUNTIME_USER", "fixture")
    account = SimpleNamespace(pw_uid=502,pw_gid=20,pw_dir="/Users/dan_1")
    monkeypatch.setattr(core.pwd, "getpwnam", lambda name: account)
    calls = []
    monkeypatch.setattr(core.subprocess, "run", lambda *a, **k: calls.append((a,k)))
    ops = core.HostOps(core.LocalState(tmp_path), SimpleNamespace())
    ops.run_artifact(["/usr/bin/git","checkout","abc1234"],"/Users/dan_1/code/chief/hermes-node")
    kwargs = calls[0][1]
    assert (kwargs["user"],kwargs["group"],kwargs["extra_groups"]) == (502,20,[])
    assert kwargs["env"]["HOME"] == "/Users/dan_1"
    assert "GIT_CONFIG_COUNT" not in kwargs["env"]


def test_config_never_evaluates_shell_or_accepts_path_overrides():
    for hostname in ("h-mini2", "MacBook-Air-8.local"):
        config = security.resolve_config(None, hostname, REGISTRY)
        assert config["CHIEF_CORE_URL"] == "http://100.122.202.37:8088"
    with pytest.raises(security.TrustError, match="secret_path"):
        security.resolve_config({"CHIEF_NODE_ID":"h-mini2", "CHIEF_CORE_URL":"http://core:8088",
                                 "CHIEF_NODE_PLAN_KEY":"/evil"}, "h-mini2", REGISTRY)
    with pytest.raises(security.TrustError):
        security.resolve_config(None, "unknown", REGISTRY)


def test_stale_cache_keeps_fetch_failure_reason_and_never_mutates(tmp_path,monkeypatch,capsys):
    state = core.LocalState(tmp_path)
    plan = make_plan(issued_at=(NOW-dt.timedelta(days=90)).isoformat())
    state.write_json_0640(state.state_dir/"cached-plan.json",plan)
    key=tmp_path/"key"; key.write_bytes(KEY)
    monkeypatch.setattr(core, "utcnow", lambda: NOW)
    monkeypatch.setattr(core.Transport,"get_plan",lambda _: (_ for _ in ()).throw(urllib.error.URLError("connection refused")))
    monkeypatch.setattr(core.HostOps,"emit",lambda *a,**k: pytest.fail("event mutation"))
    monkeypatch.setattr(core,"execute_plan",lambda *a,**k: pytest.fail("package mutation"))
    args=core.build_parser().parse_args(["--core","http://configured:8088","--node-id",NODE,"--state-root",str(tmp_path),"--plan-key-path",str(key),"--plan-only","reconcile","--trigger","boot"])
    with pytest.raises(core.VerificationError,match="stale_plan"):
        core.reconcile(args)
    err=capsys.readouterr().err
    assert "connection refused" in err and "cached-plan.json" in err and "http://configured:8088" in err
    assert not (tmp_path/"var/run/chief/reconcile.lock").exists()


def test_missing_cli_config_is_loud(monkeypatch):
    monkeypatch.delenv("CHIEF_NODE_ID",raising=False)
    monkeypatch.delenv("CHIEF_CORE_URL",raising=False)
    with pytest.raises(SystemExit) as exc:
        core.main(["converge"])
    assert exc.value.code == 2


@pytest.mark.parametrize("mode", ["converge","supervisor"])
def test_coalescing_retains_pending_on_contention(tmp_path,monkeypatch,capsys,mode):
    monkeypatch.setattr(runtime,"STATE",tmp_path)
    monkeypatch.setattr(runtime,"load_config",lambda: {})
    monkeypatch.setattr(runtime,"trusted_path",lambda *a,**kw: None)
    monkeypatch.setattr(runtime,"consume_hints",lambda: pytest.fail("consumed while busy"))
    with (tmp_path/"run.lock").open("w") as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        assert runtime.run(mode)==0
    assert "pending" in capsys.readouterr().out


def test_hint_slots_nofollow_bounded_and_fixed_enum(tmp_path,metadata):
    for name in ("login","wake","network","request"):
        (tmp_path/name).write_text(name+"\n")
    assert runtime.consume_hints(tmp_path)==["login","wake","network","request"]
    (tmp_path/"wake").write_text("wake"*100)
    (tmp_path/"request").write_text("../../evil")
    assert runtime.consume_hints(tmp_path)==[]
    target=tmp_path/"target"; target.write_text("untouched")
    (tmp_path/"login").unlink(); (tmp_path/"login").symlink_to(target)
    with pytest.raises(OSError): runtime.consume_hints(tmp_path)
    assert target.read_text()=="untouched"


def test_unknown_wake_defers_service_and_package_actions(tmp_path,monkeypatch):
    monkeypatch.setattr(core,"mutation_allowed",lambda:False)
    ops=core.HostOps(core.LocalState(tmp_path),SimpleNamespace())
    with pytest.raises(core.Deferred,match="dark_or_unknown_wake"):
        ops.fetch(SimpleNamespace())
    monkeypatch.setattr(runtime,"STATE",tmp_path)
    monkeypatch.setattr(runtime,"trusted_path",lambda *a,**k:None)
    monkeypatch.setattr(runtime,"load_config",lambda:{})
    monkeypatch.setattr(runtime,"full_wake",lambda:False)
    from hermes_converger import supervisor
    monkeypatch.setattr(runtime, "supervisor_admission", lambda config: False)
    observed = []
    monkeypatch.setattr(supervisor, "main", lambda args: observed.append(supervisor.mutation_allowed()) or 0)
    assert runtime.run("supervisor")==0
    assert observed == [False]


@pytest.mark.parametrize("platform,expected", [("macos","calendar minute"),("linux","h-do1 boot reconcile independent of Core")])
def test_closure_plan_is_offline_and_explicit(platform,expected,tmp_path):
    result=subprocess.run(["/bin/sh",str(PAYLOAD/"close.sh"),"--plan",platform],env={"PATH":str(tmp_path)},text=True,capture_output=True,check=True)
    assert expected in result.stdout
    assert "LAST privileged phase" in result.stdout and "visudo -c" in result.stdout
    assert all(name in result.stdout for name in ("chief-update","hermes-converger"))
    assert list(tmp_path.iterdir())==[]


def test_trigger_definitions_and_delivery_payload():
    for path in (ROOT/"launchd").glob("com.chief.*.plist"):
        data=plistlib.loads(path.read_bytes())
        if path.name=="com.chief.node.plist": continue
        assert len(data["ProgramArguments"])==1
        assert (PAYLOAD/"launchd"/path.name).read_bytes()==path.read_bytes()
    pulse=plistlib.loads((ROOT/"launchd/com.chief.update-request.plist").read_bytes())
    assert pulse["StartCalendarInterval"]=={} and len(pulse["WatchPaths"])==4
    for name in ("chief-node-reconcile.service","chief-update.service","chief-update-request.service"):
        unit=(ROOT/"systemd"/name).read_text()
        assert "ExecStart=/opt/chief/bin/hermes-converger\n" in unit
        assert "EnvironmentFile" not in unit
        assert (PAYLOAD/"systemd"/name).read_text()==unit
    assert "Before=chief-node" not in (ROOT/"systemd/chief-node-reconcile.service").read_text()
    assert "default.target" in (ROOT/"systemd/chief-update-login.service").read_text()
    assert "OnUnitActiveSec=60s" in (ROOT/"systemd/chief-update.timer").read_text()
    for name in ("hermes-converger","chief-node-supervisor","chief-update","chief-update-request"):
        assert (ROOT/"scripts"/name).read_bytes()==(PAYLOAD/"bin"/name).read_bytes()


def test_shell_checks_every_parent_before_interpreter(tmp_path):
    stat_stub = tmp_path/"stat"
    bad = tmp_path/"user-parent"
    bad.mkdir(); exe=bad/"python3"; exe.touch()
    stat_stub.write_text('#!/bin/sh\nfor p do :; done\ncase "$p" in '+shlex.quote(str(bad))+') echo "501 755";; *) echo "0 755";; esac\n')
    stat_stub.chmod(0o755)
    source=(PAYLOAD/"trust.sh").read_text().replace('/usr/bin/stat',str(stat_stub))
    result=subprocess.run(["/bin/sh"],input=source+'\ntrusted_path '+shlex.quote(str(exe))+'\n',text=True,capture_output=True)
    assert result.returncode != 0
    assert "not root-owned: "+str(bad) in result.stderr


def test_launcher_refuses_untrusted_runtime_without_executing_it(tmp_path):
    runtime_dir=tmp_path/"python"
    (runtime_dir/"bin").mkdir(parents=True)
    marker=tmp_path/"pwned"
    exe=runtime_dir/"bin/python3"
    exe.write_text('#!/bin/sh\ntouch '+shlex.quote(str(marker))+'\n'); exe.chmod(0o777)
    stat_stub=tmp_path/"stat"
    stat_stub.write_text('#!/bin/sh\necho "0 755"\n'); stat_stub.chmod(0o755)
    source=(PAYLOAD/"trust.sh").read_text().replace('/usr/bin/stat',str(stat_stub)).replace('/opt/chief/python',str(runtime_dir))
    result=subprocess.run(["/bin/sh"],input=source+'\ntrusted_python\n',text=True,capture_output=True)
    assert result.returncode != 0 and "untrusted tree" in result.stderr
    assert not marker.exists()


def test_sudoers_render_removes_three_grants_and_continuations(tmp_path):
    original='''root ALL=(ALL:ALL) ALL
fixture ALL=(root) NOPASSWD: /usr/local/bin/hermes-converger
fixture ALL=(root) NOPASSWD: /usr/local/bin/chief-node-supervisor
fixture ALL=(root) NOPASSWD: /usr/local/bin/chief-update
fixture ALL=(root) NOPASSWD: /bin/true, \\
 /usr/local/bin/chief-update
fixture ALL=(root) /bin/echo
'''
    result=subprocess.run(["/usr/bin/awk","-f",str(PAYLOAD/"sudoers.awk")],input=original,text=True,capture_output=True,check=True)
    assert "/usr/local/bin/" not in result.stdout
    assert "fixture ALL=(root) /bin/echo" in result.stdout
    policy=tmp_path/"sudoers"; policy.write_text(result.stdout); policy.chmod(0o440)
    checked=subprocess.run(["/usr/sbin/visudo","-c","-f",str(policy)],text=True,capture_output=True)
    assert checked.returncode == 0, checked.stderr


@pytest.mark.parametrize("reject",[False,True])
def test_whole_sudoers_validation_precedes_replacement(tmp_path,reject):
    etc=tmp_path/"etc"; etc.mkdir()
    fragments=etc/"sudoers.d"; fragments.mkdir()
    policy=etc/"sudoers"; policy.write_text('root ALL=(ALL) ALL\n@includedir '+str(fragments)+'\n'); policy.chmod(0o440)
    fragment=fragments/"chief-converger"
    before='fixture ALL=(root) NOPASSWD: /usr/local/bin/chief-update\n'
    fragment.write_text(before); fragment.chmod(0o440)
    calls=tmp_path/"calls"
    validator=tmp_path/"visudo"
    validator.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> '+shlex.quote(str(calls))+'\n'+
        ('[ "$#" = 1 ] || exit 77\n' if reject else '')+
        'if [ "$#" = 1 ]; then exec /usr/sbin/visudo -c -f '+shlex.quote(str(policy))+'; fi\nexec /usr/sbin/visudo "$@"\n')
    validator.chmod(0o755)
    source=(PAYLOAD/"contain.sh").read_text().replace('/etc/',str(etc)+'/').replace('/usr/sbin/visudo',str(validator)).replace('/usr/bin/id', '/bin/false')
    assert '/etc/sudoers' not in source.replace(str(etc),'FIXTURE')
    # All mutations go to the synthetic /etc; service functions are never called.
    result=subprocess.run(["/bin/sh"],input='set -eu\ntrusted_path() { :; }\nhold() { echo "$*" >&2; return 1; }\n'+source+'\nremove_grants\n',text=True,capture_output=True)
    if reject:
        assert result.returncode != 0 and fragment.read_text()==before
        assert len(calls.read_text().splitlines())==2
    else:
        assert result.returncode==0, result.stderr
        assert 'chief-update' not in fragment.read_text()
        assert len(calls.read_text().splitlines())==3
        assert stat.S_IMODE(fragment.stat().st_mode)==0o440


def test_pulse_noop_never_starts_python_or_consumes_hints(tmp_path):
    state=tmp_path/"state"; state.mkdir()
    hints=tmp_path/"requests"; hints.mkdir()
    for name,value in {"last-check":str(int(__import__('time').time())-100),"wake":"linux","boot":pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip(),"online":"yes","full":"yes"}.items():
        (state/name).write_text(value+'\n')
    env=tmp_path/"node.env"; env.write_text('CHIEF_CORE_URL=http://fixture\n')
    curl=tmp_path/"curl"; curl.write_text('#!/bin/sh\nexit 0\n'); curl.chmod(0o755)
    helpers = (PAYLOAD/'trust.sh').read_text()
    source = f'STATE={shlex.quote(str(state))}\nCONFIG={shlex.quote(str(env))}\nREQUESTS={shlex.quote(str(hints))}\nTRUST_OS=Linux\n'
    source += helpers[helpers.index('read_state() {'):helpers.index('# Check both sides')]
    source += 'trusted_runtime() { exit 99; }\n' + (PAYLOAD/'pulse.sh').read_text().replace('/usr/bin/curl',str(curl))
    result=subprocess.run(["/bin/sh"],input=source,text=True,capture_output=True)
    assert result.returncode==0, result.stderr
    assert "python" not in result.stderr
    # A pending login bypasses five-minute cadence, but is not consumed by shell.
    (hints/"login").write_text('login\n')
    result=subprocess.run(["/bin/sh"],input=source,text=True,capture_output=True)
    assert result.returncode==99 and (hints/"login").read_text()=='login\n'
    (hints/"login").write_text('')
    (hints/"network").touch()
    curl.write_text('#!/bin/sh\nexit 1\n')
    offline=subprocess.run(["/bin/sh"],input=source,text=True,capture_output=True)
    assert offline.returncode==0 and (state/"online").read_text().strip()=='no'
    curl.write_text('#!/bin/sh\nexit 0\n')
    returned=subprocess.run(["/bin/sh"],input=source,text=True,capture_output=True)
    assert returned.returncode==99
    assert (hints/"network").read_text()=='network\n'



def test_root_symlink_through_login_owned_alias_is_rejected(tmp_path,metadata):
    changes,_=metadata
    safe=tmp_path/'safe'; safe.mkdir(); (safe/'python').touch()
    login=tmp_path/'login'; login.mkdir(); (login/'alias').symlink_to(safe,target_is_directory=True)
    entry=tmp_path/'root-python'; entry.symlink_to(login/'alias/python')
    changes[login]=(501,0o755)
    with pytest.raises(security.TrustError,match='login'):
        security.trusted_path(entry)


def test_sudoers_alias_keeps_references_valid(tmp_path):
    source='Cmnd_Alias CHIEF = /usr/local/bin/chief-update\nfixture ALL=(root) NOPASSWD: CHIEF\n'
    result=subprocess.run(['/usr/bin/awk','-f',str(PAYLOAD/'sudoers.awk')],input=source,text=True,capture_output=True,check=True)
    assert '/usr/local/bin/' not in result.stdout and '/usr/bin/false' in result.stdout
    policy=tmp_path/'sudoers'; policy.write_text(result.stdout); policy.chmod(0o440)
    assert subprocess.run(['/usr/sbin/visudo','-c','-f',str(policy)],capture_output=True).returncode==0


@pytest.mark.parametrize('platform,hostname',[('Darwin','h-mini2'),('Linux','h-do1')])
def test_closure_without_python_repairs_config_disables_jobs_and_revokes_last(tmp_path,platform,hostname):
    """Execute the closure against a private fake host; OS controls are recorders."""
    import shutil
    host=tmp_path/'host'
    base=host/'opt/chief/lib/hermes-host-bootstrap/hermes_converger/step0'
    shutil.copytree(PAYLOAD,base)
    for name in ('usr/local/bin','opt/chief/bin','etc/chief','etc/sudoers.d','Library/LaunchDaemons','Library/LaunchAgents',
                 'etc/systemd/system','usr/lib/systemd','var/lib','var/log','var/run','run'):
        (host/name).mkdir(parents=True,exist_ok=True)
    policy=host/'etc/sudoers'
    policy.write_text('root ALL=(ALL) ALL\n@includedir '+str(host/'etc/sudoers.d')+'\n'); policy.chmod(0o440)
    fragment=host/'etc/sudoers.d/chief-converger'
    fragment.write_text(''.join('fixture ALL=(root) NOPASSWD: /usr/local/bin/'+name+'\n'
                               for name in ('chief-update','hermes-converger','chief-node-supervisor')))
    fragment.chmod(0o440)
    override=host/'etc/systemd/system/chief-node-converger.service.d'
    if platform=='Linux':
        override.mkdir()
        (override/'unsafe.conf').write_text('[Service]\nExecStart=/login/venv/python\n')
    log=tmp_path/'commands'
    bin=tmp_path/'bin'; bin.mkdir()
    commands=['/usr/bin/id','/usr/bin/uname','/usr/sbin/sysctl','/bin/hostname','/usr/bin/getent','/usr/sbin/groupadd',
              '/usr/bin/dscl','/usr/sbin/dseditgroup','/usr/bin/systemctl','/bin/launchctl','/usr/sbin/chown','/bin/chown','/usr/bin/sudo','/bin/sync']
    for command in commands:
        name=command.rsplit('/',1)[1]
        output={'id':'0','uname':platform,'hostname':hostname,'sysctl':'fixture-boot'}.get(name,'')
        (bin/name).write_text('#!/bin/sh\nprintf "%s\\n" '+shlex.quote(name)+'" $*" >> '+shlex.quote(str(log))+'\nprintf "%s\\n" '+shlex.quote(output)+'\n')
        (bin/name).chmod(0o755)
    installer=bin/'install'
    installer.write_text('''#!/usr/bin/python3
import subprocess,sys
args=[]
it=iter(sys.argv[1:])
for arg in it:
    if arg in {'-o','-g'}: next(it)
    else: args.append(arg)
subprocess.run(['/usr/bin/install',*args],check=True)
'''); installer.chmod(0o755)
    validator=bin/'visudo'
    validator.write_text('#!/bin/sh\necho visudo >> '+shlex.quote(str(log))+'\nif [ "$#" = 1 ]; then exec /usr/sbin/visudo -c -f '+shlex.quote(str(policy))+'; fi\nexec /usr/sbin/visudo "$@"\n')
    validator.chmod(0o755)
    for path in (base/'close.sh',base/'contain.sh',base/'configure.sh'):
        source=path.read_text()
        for directory in ('/opt/','/usr/local/','/var/lib','/var/log','/var/run','/run/','/Library/','/usr/lib/systemd','/etc/'):
            source=source.replace(directory,str(host)+directory)
        tool_pattern='|'.join(re.escape(c) for c in sorted([*commands,'/usr/bin/install','/usr/sbin/visudo'],key=len,reverse=True))
        source=re.sub(tool_pattern,lambda m:str(bin/m.group().rsplit('/',1)[1]),source)
        path.write_text(source)
    (base/'trust.sh').write_text('''set -eu
trusted_tree() { :; }
trusted_path() { :; }
trusted_python() { echo 'fixture: Python unavailable' >&2; return 1; }
hold() { echo "HOLD: $*" >&2; return 1; }
''')
    result=subprocess.run(['/bin/sh',str(base/'close.sh')],text=True,capture_output=True)
    assert result.returncode==1, result.stdout+result.stderr
    config=security.read_env(host/'etc/chief/node.env')
    assert config['CHIEF_NODE_ID']==hostname
    assert config['CHIEF_CORE_URL']=='http://100.122.202.37:8088'
    assert stat.S_IMODE((host/'etc/chief/node.env').stat().st_mode)==0o640
    assert 'NOPASSWD' not in fragment.read_text()
    assert 'trusted_python_unavailable' in (host/'var/lib/chief/currency-step0/closure-status').read_text()
    assert not (host/'var/lib/chief/currency-step0/prepared').exists()
    actions=log.read_text().splitlines()
    assert 'visudo' in actions and (host/'var/lib/chief/currency-step0/grants-removed').exists()
    assert not any(line.startswith(('systemctl start','launchctl bootstrap')) for line in actions)
    assert any(line.startswith('chown root:chief ') for line in actions)
    assert not (host/'etc/systemd/system/chief-node.service').exists()
    if platform=='Linux':
        assert not override.exists()
        assert len(list((host/'var/lib/chief/currency-step0').glob('retired-overrides.*/chief-node-converger.service.d/unsafe.conf')))==1


@pytest.mark.parametrize('qualified,listing,expected',[(False,'"SystemPowerStateCapabilities"=15',False),
    (True,'"SystemPowerStateCapabilities"=15',True),(True,'"SystemPowerStateCapabilities"=1',False),(True,'unknown wake',False)])
def test_actual_wake_classifier_requires_signed_qualification_and_cpu_graphics(monkeypatch,qualified,listing,expected):
    monkeypatch.setattr(runtime.os,'uname',lambda:SimpleNamespace(sysname='Darwin'))
    original=pathlib.Path.exists
    monkeypatch.setattr(pathlib.Path,'exists',lambda p:qualified if str(p)=='/etc/chief/wake-qualified' else original(p))
    monkeypatch.setattr(runtime,'trusted_path',lambda p:None)
    calls=[]
    monkeypatch.setattr(subprocess,'run',lambda *a,**k:calls.append(a) or SimpleNamespace(returncode=0,stdout=listing))
    assert runtime.full_wake(qualified) is expected
    assert bool(calls) is qualified
