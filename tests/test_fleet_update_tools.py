"""Only temporary fake CLIs/npm/schedulers; never update or authenticate real tools."""
import ast
import datetime
import fcntl
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(os.environ.get("FLEET_TOOLS_TEST_SCRIPT", ROOT / "scripts/fleet-update-tools"))
REAL_PERL = shutil.which("perl")


def executable(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(0o755)


def command(args, env, check=True):
    return subprocess.run([str(arg) for arg in args], env=env, capture_output=True,
                          text=True, timeout=20, check=check)


def snapshot(path):
    return {str(p.relative_to(path)): ("link", os.readlink(p)) if p.is_symlink()
            else ("file", p.read_bytes()) if p.is_file() else ("dir",)
            for p in path.rglob("*")}


CLI = '''#!/usr/bin/env python3
import json, os, pathlib, shutil, sys
cfg = json.loads(pathlib.Path(os.environ['TEST_CONFIG']).read_text())
me = pathlib.Path(__file__).resolve()
native = me.parent == pathlib.Path.home() / '.local/share/claude/versions'
name = 'claude' if native or 'claude-code' in me.parts else 'codex'
version_file = None if native else me.parent / 'version.txt'
version = me.name if native else version_file.read_text()
with open(os.environ['TEST_CALLS'], 'a') as f:
    f.write(json.dumps([name, str(me)] + sys.argv[1:]) + '\\n')
if sys.argv[1:] == ['--version']:
    if version in cfg.get('bad_versions', {}).get(name, []):
        print(name + ' 99.99.99')
        sys.exit(cfg.get('health_exit', 0))
    print(name + ' ' + version)
    sys.exit(0)
assert native and sys.argv[1] == 'install'
v = sys.argv[2]
if v == '1.0.0' and name in cfg.get('rollback_fail', []):
    sys.exit(1)
new = me.parent / v
if new != me:
    shutil.copy2(me, new)
link = pathlib.Path.home() / '.local/bin/claude'
link.unlink()
link.symlink_to(new)
sys.exit(1 if name in cfg.get('install_fail', []) and v != '1.0.0' else 0)
'''

NPM = '''#!/usr/bin/env python3
import json, os, pathlib, sys, time
cfg = json.loads(pathlib.Path(os.environ['TEST_CONFIG']).read_text())
a = sys.argv[1:]
with open(os.environ['TEST_CALLS'], 'a') as f:
    f.write(json.dumps(['npm', str(pathlib.Path(__file__).absolute())] + a) + '\\n')
if a[0] == 'view':
    name = 'claude' if a[1] == '@anthropic-ai/claude-code' else 'codex'
    if name in cfg.get('registry_fail', []): sys.exit(1)
    if a[2] == 'version': print(cfg['latest'])
    else: print(json.dumps(cfg['times']))
    if cfg.get('become_busy'): pathlib.Path(os.environ['TEST_BUSY']).touch()
    sys.exit(0)
assert a[:2] == ['i', '-g'], a
pkg, version = a[2].rsplit('@', 1)
name = 'claude' if pkg == '@anthropic-ai/claude-code' else 'codex'
prefix = pathlib.Path(a[a.index('--prefix') + 1])
assert pathlib.Path(os.environ['TEST_ROOT']) in prefix.parents
assert pathlib.Path(__file__).parent == prefix / 'bin', 'wrong npm prefix'
if version == '1.0.0' and name in cfg.get('rollback_fail', []): sys.exit(1)
(prefix / 'lib/node_modules' / pkg / 'bin/version.txt').write_text(version)
sys.exit(1 if name in cfg.get('install_fail', []) and version != '1.0.0' else 0)
'''


class Fleet:
    def __init__(self, tmp):
        self.tmp = tmp
        self.home = tmp / "home"
        self.bin = tmp / "bin"
        self.home.mkdir()
        self.bin.mkdir()
        self.calls = tmp / "calls"
        self.config = tmp / "config.json"
        self.state = self.home / ".local/state/fleet-update-tools"
        now = datetime.datetime.now(datetime.timezone.utc)
        self.cfg = dict(latest="2.0.0", times={
            "1.0.0": (now - datetime.timedelta(days=10)).isoformat(),
            "2.0.0": (now - datetime.timedelta(hours=30)).isoformat()})
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.bin) + ":/usr/bin:/bin",
                        TEST_ROOT=str(tmp), TEST_CONFIG=str(self.config), TEST_CALLS=str(self.calls),
                        TEST_BUSY=str(tmp / "busy"), PYTHONDONTWRITEBYTECODE="1")
        # Appended system paths must never expose real installed CLIs to tests.
        patches = tmp / "patches"
        patches.mkdir()
        (patches / "sitecustomize.py").write_text('''import os, pathlib, shutil
original = shutil.which
def which(name, *args, **kwargs):
    found = original(name, *args, **kwargs)
    if name in ('claude', 'codex', 'npm', 'brew') and found:
        if pathlib.Path(os.environ['TEST_ROOT']) not in pathlib.Path(found).absolute().parents:
            return None
    return found
shutil.which = which
''')
        self.env["PYTHONPATH"] = str(patches)
        executable(self.bin / "npm", NPM)
        executable(self.bin / "ps", '''#!/usr/bin/env python3
import json, os, pathlib, sys
cfg = json.loads(pathlib.Path(os.environ['TEST_CONFIG']).read_text())
assert sys.argv[1:3] == ['-u', str(os.getuid())]
if cfg.get('ps_fail'): sys.exit(1)
print(cfg.get('processes', ''))
if pathlib.Path(os.environ['TEST_BUSY']).exists(): print('node node /tmp/lib/node_modules/@openai/codex/bin/codex.js')
''')
        self.script = SCRIPT

    def install(self, name, method="npm", version="1.0.0", flavor="tools/node-22"):
        link = self.home / ".local/bin" / name
        link.parent.mkdir(parents=True, exist_ok=True)
        if method == "native":
            target = self.home / ".local/share/claude/versions" / version
        elif method == "unknown":
            target = self.home / "other" / name
        elif method == "brew":
            target = self.home / "brew/Cellar" / name / version / "bin" / name
        else:
            prefix = self.home / flavor
            pkg = "@anthropic-ai/claude-code" if name == "claude" else "@openai/codex"
            target = prefix / "lib/node_modules" / pkg / "bin/cli.js"
            executable(prefix / "bin/npm", NPM)
            bin_link = prefix / "bin" / name
            bin_link.symlink_to(target)
            link.symlink_to(bin_link)
        executable(target, CLI)
        if method != "native":
            (target.parent / "version.txt").write_text(version)
        if not link.is_symlink():
            link.symlink_to(target)
        return target

    def run(self, *args, expected=0):
        self.config.write_text(json.dumps(self.cfg))
        proc = command(["bash", self.script, *args], self.env, check=False)
        assert proc.returncode == expected, proc.stdout + proc.stderr
        if args:
            return proc
        return json.loads((self.state / "status.json").read_text())

    def row(self, name="claude", **kwargs):
        return next(row for row in self.run(**kwargs)["tools"] if row["name"] == name)

    def installs(self):
        if not self.calls.exists():
            return []
        return [json.loads(line) for line in self.calls.read_text().splitlines()
                if json.loads(line)[2] in ("i", "install")]


@pytest.fixture
def fleet(tmp_path):
    return Fleet(tmp_path)


@pytest.mark.parametrize("name,method", [("claude", "native"), ("claude", "npm"), ("codex", "npm")])
def test_updated(fleet, name, method):
    target = fleet.install(name, method)
    row = fleet.row(name)
    assert row == dict(name=name, path=str(target), method=method, result="updated 1.0.0->2.0.0",
                       **{"from": "1.0.0", "to": "2.0.0", "target": "2.0.0"})
    assert len(fleet.installs()) == 1
    if method == "native":
        assert fleet.installs()[0][2:] == ["install", "2.0.0"]
    else:
        assert fleet.installs()[0][1] != str(fleet.bin / "npm")


@pytest.mark.parametrize("flavor", ["brew", ".nvm/versions/node/v22.0.0", ".local/share/fnm/node-versions/v22.0.0/installation", "tools/node-22"])
def test_npm_uses_installations_sibling(fleet, flavor):
    fleet.install("codex", flavor=flavor)
    assert fleet.row("codex")["result"].startswith("updated")
    assert fleet.installs()[0][1] == str(fleet.home / flavor / "bin/npm")


@pytest.mark.parametrize("version", ["2.0.0", "3.0.0"])
def test_current_and_never_downgrade(fleet, version):
    fleet.install("claude", "native", version=version)
    row = fleet.row()
    assert row["result"] == "current"
    assert row["from"] == row["to"] == version
    assert not fleet.installs()


def test_soak_chooses_older_and_skips_prerelease(fleet):
    fleet.install("codex")
    fleet.cfg["latest"] = "3.0.0"
    fleet.cfg["times"]["3.0.0"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    fleet.cfg["times"]["4.0.0-beta.1"] = fleet.cfg["times"]["1.0.0"]
    assert fleet.row("codex")["target"] == "2.0.0"
    assert "@2.0.0" in fleet.installs()[0][4]


def test_no_soaked_version(fleet):
    fleet.install("claude", "native")
    fleet.cfg["times"] = {"2.0.0": datetime.datetime.now(datetime.timezone.utc).isoformat()}
    assert fleet.row()["result"] == "held:no_soaked_version"
    assert not fleet.installs()


@pytest.mark.parametrize("process", ["claude /tmp/claude -p hello", "codex /tmp/codex exec hi", "node node /tmp/lib/node_modules/@anthropic-ai/claude-code/cli.js -p hi", "node node /tmp/lib/node_modules/@openai/codex/bin/codex.js"])
def test_any_agent_defers_both(fleet, process):
    fleet.install("claude", "native")
    fleet.install("codex")
    fleet.cfg["processes"] = process
    assert all(row["result"] == "deferred:in_use" for row in fleet.run()["tools"])
    assert not fleet.calls.exists()


def test_process_arguments_are_not_agents(fleet):
    fleet.install("claude", "native")
    fleet.cfg["processes"] = 'python3 python3 worker.py "ask claude or codex"'
    assert fleet.row()["result"].startswith("updated")


def test_native_version_path_is_in_use(fleet):
    binary = fleet.install("claude", "native")
    fleet.cfg["processes"] = "{} {} -p hello".format(binary, binary)
    assert fleet.row()["result"] == "deferred:in_use"
    assert not fleet.calls.exists()


def test_idle_rechecked_before_install(fleet):
    fleet.install("codex")
    fleet.cfg["become_busy"] = True
    assert fleet.row("codex")["result"] == "deferred:in_use"
    assert not fleet.installs()


def test_process_check_failure_is_safe(fleet):
    fleet.install("codex")
    fleet.cfg["ps_fail"] = True
    assert fleet.row("codex", expected=1)["result"] == "error:process_check_failed"
    assert not fleet.installs()


def test_pause(fleet):
    fleet.install("claude", "native")
    fleet.install("codex")
    pause = fleet.home / ".config/fleet-update/pause-tools"
    pause.parent.mkdir(parents=True)
    pause.touch()
    assert all(row["result"] == "paused" for row in fleet.run()["tools"])
    assert not fleet.calls.exists()


@pytest.mark.parametrize("name,method", [("claude", "native"), ("codex", "npm")])
@pytest.mark.parametrize("reason", ["health_check_failed", "install_failed"])
def test_rollback(fleet, name, method, reason):
    fleet.install(name, method)
    if reason == "health_check_failed":
        fleet.cfg["bad_versions"] = {name: ["2.0.0"]}
    else:
        fleet.cfg["install_fail"] = [name]
    row = fleet.row(name)
    assert row["result"] == "rolled_back:" + reason
    assert row["from"] == row["to"] == "1.0.0" and row["target"] == "2.0.0"
    assert len(fleet.installs()) == 2


@pytest.mark.parametrize("failure", ["install", "health"])
def test_rollback_failure(fleet, failure):
    fleet.install("codex")
    fleet.cfg["bad_versions"] = {"codex": ["2.0.0"]}
    if failure == "install":
        fleet.cfg["rollback_fail"] = ["codex"]
    else:
        # Health starts failing for the old release only AFTER the update.
        executable(fleet.home / "tools/node-22/bin/npm", NPM.replace(
            "sys.exit(1 if name in cfg.get('install_fail'",
            "cfg['bad_versions']['codex'].append('1.0.0')\npathlib.Path(os.environ['TEST_CONFIG']).write_text(json.dumps(cfg))\nsys.exit(1 if name in cfg.get('install_fail'"))
    row = fleet.row("codex", expected=1)
    assert row["result"] == "error:rollback_failed" and row["to"] is None


def test_absent_status_and_log_shape(fleet):
    report = fleet.run()
    assert set(report) == {"host", "ran_at", "version", "tools"}
    assert report["host"] and len(report["version"]) == 40
    datetime.datetime.strptime(report["ran_at"], "%Y-%m-%dT%H:%M:%SZ")
    assert [row["name"] for row in report["tools"]] == ["claude", "codex"]
    for row in report["tools"]:
        assert set(row) == {"name", "path", "method", "result", "from", "to", "target"}
        assert row["result"] == "skipped:absent" and row["path"] is None
    assert json.loads((fleet.state / "log").read_text()) == report
    assert not fleet.calls.exists()
    assert not list(fleet.state.glob(".*.json.*"))


@pytest.mark.parametrize("kind", ["--formula", "--cask"])
def test_brew_held_only_when_owns_resolved_path(fleet, kind):
    target = fleet.install("claude", "brew")
    executable(fleet.bin / "brew", "#!/bin/sh\n[ \"$1 $2 $3\" = \"list " + kind + " claude-code\" ] || exit 1\nprintf '%s\\n' '" + str(target) + "'\n")
    row = fleet.row()
    assert row["method"] == "brew" and row["result"] == "held:brew_managed"
    assert not fleet.installs()


def test_unrelated_brew_does_not_hold_npm(fleet):
    fleet.install("codex")
    executable(fleet.bin / "brew", "#!/bin/sh\necho /other/brew/codex\n")
    assert fleet.row("codex")["result"].startswith("updated")


def test_unknown_install(fleet):
    fleet.install("codex", "unknown")
    assert fleet.row("codex")["result"] == "held:unknown_install"
    assert not fleet.calls.exists()


def test_one_error_does_not_stop_other(fleet):
    fleet.install("claude", "native")
    fleet.install("codex")
    fleet.cfg["registry_fail"] = ["claude"]
    rows = fleet.run(expected=1)["tools"]
    assert rows[0]["result"] == "error:registry_failed"
    assert rows[1]["result"] == "updated 1.0.0->2.0.0"


@pytest.mark.parametrize("existing_state", [False, True])
def test_dry_run_changes_nothing(fleet, existing_state):
    fleet.install("claude", "native")
    fleet.install("codex")
    if existing_state:
        fleet.state.mkdir(parents=True)
        (fleet.state / "status.json").write_text("previous status")
        (fleet.state / "log").write_text("previous log")
    before = snapshot(fleet.home)
    result = fleet.run("--dry-run")
    assert "would check" in result.stdout
    assert snapshot(fleet.home) == before
    assert not fleet.calls.exists()
    assert not (fleet.state / "lock").exists()


def test_auth_files_untouched(fleet):
    fleet.install("claude", "native")
    fleet.install("codex")
    for path in (".codex/auth.json", ".config/claude/oauth-token", "Library/Keychains/login.keychain-db"):
        target = fleet.home / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"test secret\x00")
    before = {p: (fleet.home / p).read_bytes() for p in (".codex/auth.json", ".config/claude/oauth-token", "Library/Keychains/login.keychain-db")}
    fleet.run()
    assert all((fleet.home / p).read_bytes() == content for p, content in before.items())


def test_mutex_busy(fleet):
    fleet.install("claude", "native")
    fleet.state.mkdir(parents=True)
    fleet.config.write_text(json.dumps(fleet.cfg))
    with (fleet.state / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        result = command(["bash", fleet.script], fleet.env)
        assert result.stdout.strip() == "busy"
        assert not (fleet.state / "status.json").exists()
        assert not fleet.calls.exists()


def test_log_last_500(fleet):
    fleet.state.mkdir(parents=True)
    (fleet.state / "log").write_text("old\n" * 510)
    report = fleet.run()
    lines = (fleet.state / "log").read_text().splitlines()
    assert len(lines) == 500 and json.loads(lines[-1]) == report


def test_python39_syntax():
    source = SCRIPT.read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY\n", 1)[0]
    ast.parse(source, feature_version=(3, 9))


@pytest.fixture
def module(tmp_path):
    repo = tmp_path / "repo & test"
    home = tmp_path / "home"
    bins = tmp_path / "bin"
    for path in [repo / "lib", repo / "scripts", home, bins]:
        path.mkdir(parents=True)
    for source in ["bootstrap.sh", "lib/common.sh", "lib/N0-fleet-update-tools.sh", "scripts/fleet-update-tools"]:
        shutil.copy2(ROOT / source, repo / source)
    (repo / "verify.sh").write_text("verify_human() { :; }\n")
    executable(bins / "uname", '#!/bin/sh\nif [ "$1" = -s ]; then echo "$TEST_OS"; else /usr/bin/uname "$@"; fi\n')
    executable(bins / "systemctl", '#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_CALLS"\n')
    executable(bins / "sleep", '#!/bin/sh\nexit 0\n')
    executable(bins / "plutil", "#!/usr/bin/env python3\nimport plistlib, sys\nplistlib.load(open(sys.argv[-1], 'rb'))\n")
    executable(bins / "launchctl", """#!/usr/bin/env python3
import os, pathlib, sys
a = sys.argv[1:]
s = pathlib.Path(os.environ['TEST_LOADED'])
with open(os.environ['TEST_CALLS'], 'a') as f:
    f.write(' '.join(a) + '\\n')
if a[0] == 'print':
    if s.exists() and s.read_text().startswith('draining'):
        n = int(s.read_text().split(':')[1])
        if n == 0: s.unlink()
        else: s.write_text('draining:' + str(n - 1))
    sys.exit(0 if s.exists() else 1)
if a[0] == 'bootout' and not os.environ.get('TEST_STUCK'):
    s.write_text('draining:2')
if a[0] == 'bootstrap':
    assert not s.exists(), 'bootstrap before bootout completed'
    s.write_text('loaded')
""")
    env = dict(os.environ, HOME=str(home), PATH=str(bins) + ":/usr/bin:/bin",
               HERMES_HOSTNAME="h-do1", HERMES_NONINTERACTIVE="1", TEST_OS="Darwin",
               SUDO="",
               TEST_CALLS=str(tmp_path / "calls"), TEST_LOADED=str(tmp_path / "loaded"),
               HERMES_SYSTEMD_DIR=str(tmp_path / "systemd"))
    for key in ["HERMES_SKIP", "HERMES_SKIP_KEYS", "ROLE", "TIER", "REPO_ROOT"]:
        env.pop(key, None)
    return repo, home, env


def bootstrap(module, *args):
    repo, _, env = module
    return command(["bash", repo / "bootstrap.sh", "--only=N0-fleet-update-tools", *args], env)


def test_module_mac_calendar_idempotent_reload(module):
    repo, home, env = module
    bootstrap(module)
    plist = home / "Library/LaunchAgents/com.hermes.fleet-update-tools.plist"
    data = plistlib.loads(plist.read_bytes())
    assert data["StartCalendarInterval"] == {"Hour": 3, "Minute": 41}
    assert "StartInterval" not in data and "RunAtLoad" not in data
    assert data["ProgramArguments"] == ["/bin/bash", str(repo / "scripts/fleet-update-tools")]
    state = home / ".local/state/fleet-update-tools"
    assert Path(data["StandardOutPath"]).parent == state
    assert Path(data["StandardErrorPath"]).parent == state
    assert (home / ".local/bin/fleet-update-tools").resolve() == repo / "scripts/fleet-update-tools"
    calls = Path(env["TEST_CALLS"])
    calls.write_text("")
    bootstrap(module)
    assert "bootout" not in calls.read_text() and "bootstrap" not in calls.read_text()
    plist.write_text("stale")
    bootstrap(module)
    log = calls.read_text()
    assert log.index("bootout") < log.index("bootstrap")
    assert log[log.index("bootout"):log.index("bootstrap")].count("print ") >= 3


def test_module_mac_reload_fails_if_still_loaded(module):
    _, home, env = module
    bootstrap(module)
    plist = home / "Library/LaunchAgents/com.hermes.fleet-update-tools.plist"
    plist.write_text("stale")
    env["TEST_STUCK"] = "1"
    Path(env["TEST_CALLS"]).write_text("")
    result = bootstrap(module)
    assert "still loaded after bootout" in result.stdout + result.stderr
    assert "bootstrap " not in Path(env["TEST_CALLS"]).read_text()
    assert plist.read_text() == "stale"


@pytest.mark.parametrize("mode", ["release", "timeout", "unchanged"])
def test_module_mac_waits_for_updater_before_reload(module, mode):
    repo, home, env = module
    bootstrap(module)
    plist = home / "Library/LaunchAgents/com.hermes.fleet-update-tools.plist"
    if mode != "unchanged":
        plist.write_text("stale")
    calls = Path(env["TEST_CALLS"])
    calls.write_text("")
    ready = repo.parent / "waiting"
    env.update(TEST_WAITING=str(ready), REAL_PERL=REAL_PERL)
    # Keep real blocking flock, reducing only the 300-second alarm in this test.
    executable(repo.parent / "bin/perl", '''#!/usr/bin/env python3
import os, pathlib, sys
a = sys.argv[1:]
code = a[a.index('-e') + 1]
assert 'alarm 300' in code and 'LOCK_EX' in code and 'LOCK_NB' not in code
a[a.index('-e') + 1] = code.replace('alarm 300', 'alarm 1')
pathlib.Path(os.environ['TEST_WAITING']).touch()
os.execv(os.environ['REAL_PERL'], [os.environ['REAL_PERL']] + a)
''')
    with (home / ".local/state/fleet-update-tools/lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with subprocess.Popen(["bash", str(repo / "bootstrap.sh"), "--only=N0-fleet-update-tools"],
                              env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True) as process:
            try:
                if mode == "unchanged":
                    stdout, stderr = process.communicate(timeout=10)
                    assert not ready.exists()
                else:
                    deadline = time.monotonic() + 10
                    while not ready.exists() and time.monotonic() < deadline:
                        time.sleep(.02)
                    assert ready.exists()
                    time.sleep(.1)
                    assert process.poll() is None
                    assert "bootout" not in calls.read_text()
                    assert "bootstrap " not in calls.read_text()
                    assert plist.read_text() == "stale"
                    if mode == "release":
                        fcntl.flock(lock, fcntl.LOCK_UN)
                    stdout, stderr = process.communicate(timeout=10)
                assert process.returncode == 0
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=10)
    if mode == "release":
        assert "bootout" in calls.read_text() and "bootstrap " in calls.read_text()
        assert plistlib.loads(plist.read_bytes())["Label"] == "com.hermes.fleet-update-tools"
    else:
        assert "bootout" not in calls.read_text() and "bootstrap " not in calls.read_text()
        if mode == "timeout":
            assert "skipping reload" in stdout + stderr
            assert plist.read_text() == "stale"


@pytest.mark.parametrize("args,os_name,host", [(["--skip=fleet-update-tools"], "Darwin", "h-mini"),
                                               (["--role=client"], "Linux", "h-do1")])
def test_module_gates_through_bootstrap(module, args, os_name, host):
    _, home, env = module
    env.update(TEST_OS=os_name, HERMES_HOSTNAME=host)
    bootstrap(module, *args)
    assert not (home / ".local/bin/fleet-update-tools").exists()
    assert not Path(env["TEST_CALLS"]).exists()
    assert not Path(env["HERMES_SYSTEMD_DIR"]).exists()


@pytest.mark.parametrize("role", ["client", "server", "both"])
def test_module_mac_all_roles_minimal_tier(module, role):
    _, home, _ = module
    bootstrap(module, "--role=" + role, "--tier=minimal")
    assert (home / "Library/LaunchAgents/com.hermes.fleet-update-tools.plist").exists()


def test_module_linux_units_idempotent(module):
    repo, _, env = module
    env["TEST_OS"] = "Linux"
    bootstrap(module, "--role=server")
    units = Path(env["HERMES_SYSTEMD_DIR"])
    service = units / "hermes-fleet-update-tools.service"
    timer = units / "hermes-fleet-update-tools.timer"
    assert "User=root\n" in service.read_text()
    assert str(repo / "scripts/fleet-update-tools") in service.read_text()
    assert "OnCalendar=*-*-* 03:41:00\n" in timer.read_text()
    assert "Persistent=true\n" in timer.read_text()
    calls = Path(env["TEST_CALLS"])
    assert calls.read_text().splitlines() == [
        "daemon-reload", "enable hermes-fleet-update-tools.timer"]
    before = snapshot(units)
    calls.write_text("")
    bootstrap(module, "--role=server")
    assert snapshot(units) == before and "daemon-reload" not in calls.read_text()
    assert calls.read_text().splitlines() == ["enable hermes-fleet-update-tools.timer"]
    timer.write_text("stale")
    calls.write_text("")
    bootstrap(module, "--role=server")
    assert snapshot(units) == before
    assert calls.read_text().splitlines() == [
        "daemon-reload", "enable hermes-fleet-update-tools.timer"]
    if shutil.which("systemd-analyze"):
        command(["systemd-analyze", "verify", service, timer], env)


def test_numeric_semver_order(fleet):
    fleet.install("codex")
    fleet.cfg["latest"] = "2.10.0"
    old = fleet.cfg["times"]["1.0.0"]
    fleet.cfg["times"].update({"2.9.0": old, "2.10.0": old, "2.11.0-beta": old})
    assert fleet.row("codex")["target"] == "2.10.0"


def test_no_sibling_npm_is_unknown(fleet):
    fleet.install("codex")
    (fleet.home / "tools/node-22/bin/npm").unlink()
    assert fleet.row("codex")["result"] == "held:unknown_install"
    assert not fleet.installs()


def test_npm_uses_paired_node_without_reordering_path(fleet):
    fleet.install("codex")
    prefix = fleet.home / "tools/node-22"
    npm = prefix / "bin/npm"
    npm.unlink()
    real_script = prefix / "lib/node_modules/npm/bin/npm-cli.js"
    executable(real_script, NPM)
    npm.symlink_to(real_script)
    # The fake Node forwards to our Python npm shim but checks which Node ran.
    executable(prefix / "bin/node", '''#!/usr/bin/env python3
import os, pathlib, sys
assert pathlib.Path(sys.argv[1]).name == 'npm-cli.js'
script = sys.argv[1]
source = pathlib.Path(script).read_text().replace(
    "assert pathlib.Path(__file__).parent == prefix / 'bin', 'wrong npm prefix'",
    "assert str(prefix) in __file__")
sys.argv = sys.argv[1:]
exec(compile(source, script, 'exec'), {'__file__': script, '__name__': '__main__'})
''')
    executable(fleet.bin / "node", "#!/bin/sh\nexit 91\n")
    assert fleet.row("codex")["result"].startswith("updated")


def accelerated_timeouts(fleet):
    with (fleet.tmp / "patches/sitecustomize.py").open("a") as stream:
        stream.write('''
import json, subprocess
original_communicate = subprocess.Popen.communicate
def communicate(self, input=None, timeout=None):
    if timeout is not None:
        with open(os.environ['TEST_TIMEOUTS'], 'a') as log:
            log.write(json.dumps([self.args, timeout]) + '\\n')
    return original_communicate(self, input=input, timeout=min(timeout, .3) if timeout else timeout)
subprocess.Popen.communicate = communicate
''')
    fleet.env["TEST_TIMEOUTS"] = str(fleet.tmp / "timeouts")


def test_health_timeout_kills_group_and_rolls_back(fleet):
    target = fleet.install("claude", "native")
    source = target.read_text().replace("if sys.argv[1:] == ['--version']:", '''if sys.argv[1:] == ['--version'] and version == '2.0.0':
    import signal, subprocess, time
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    child = subprocess.Popen(['sleep', '60'])
    pathlib.Path(os.environ['TEST_WORKER']).write_text(str(child.pid))
    while True: time.sleep(.05)
if sys.argv[1:] == ['--version']:''')
    executable(target, source)
    accelerated_timeouts(fleet)
    fleet.env["TEST_WORKER"] = str(fleet.tmp / "worker")
    assert fleet.row()["result"] == "rolled_back:health_check_failed"
    caps = [json.loads(line) for line in (fleet.tmp / "timeouts").read_text().splitlines()]
    assert any(args[-1] == "--version" and cap == 30 for args, cap in caps)
    assert any("install" in args and cap == 300 for args, cap in caps)
    pid = int((fleet.tmp / "worker").read_text())
    status = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
    assert status.returncode or status.stdout.strip().startswith("Z")


def test_registry_timeout_has_60_second_cap(fleet):
    fleet.install("codex")
    npm = fleet.home / "tools/node-22/bin/npm"
    executable(npm, NPM.replace("if a[0] == 'view':", "if a[0] == 'view':\n    time.sleep(60)"))
    accelerated_timeouts(fleet)
    assert fleet.row("codex", expected=1)["result"] == "error:timeout"
    caps = [json.loads(line) for line in (fleet.tmp / "timeouts").read_text().splitlines()]
    assert any("view" in args and cap == 60 for args, cap in caps)
    assert not fleet.installs()


def test_module_linux_waits_for_lock_before_writing_units(module):
    repo, home, env = module
    env["TEST_OS"] = "Linux"
    bootstrap(module, "--role=server")
    timer = Path(env["HERMES_SYSTEMD_DIR"]) / "hermes-fleet-update-tools.timer"
    timer.write_text("stale")
    calls = Path(env["TEST_CALLS"])
    calls.write_text("")
    executable(repo.parent / "bin/perl", '''#!/usr/bin/env python3
import os, sys
a = sys.argv[1:]
code = a[a.index('-e') + 1]
assert 'alarm 300' in code
a[a.index('-e') + 1] = code.replace('alarm 300', 'alarm 1')
os.execv(os.environ['REAL_PERL'], [os.environ['REAL_PERL']] + a)
''')
    env["REAL_PERL"] = REAL_PERL
    with (home / ".local/state/fleet-update-tools/lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        result = bootstrap(module, "--role=server")
    assert "skipping reload" in result.stdout + result.stderr
    assert timer.read_text() == "stale"
    assert calls.read_text() == ""


def test_npm_health_uses_paired_node_without_nvm_on_path(fleet):
    target = fleet.install("codex", flavor=".nvm/versions/node/v22.0.0")
    executable(target, CLI.replace("#!/usr/bin/env python3", "#!/usr/bin/env node", 1))
    prefix = fleet.home / ".nvm/versions/node/v22.0.0"
    executable(prefix / "bin/node", '''#!/usr/bin/env python3
import os, sys
assert sys.argv[-1] == '--version'
os.execv('/usr/bin/python3', ['/usr/bin/python3'] + sys.argv[1:])
''')
    executable(fleet.bin / "node", "#!/bin/sh\nexit 91\n")
    assert fleet.row("codex")["result"] == "updated 1.0.0->2.0.0"
