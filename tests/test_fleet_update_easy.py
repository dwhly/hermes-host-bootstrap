"""Local bare remotes and fake schedulers only; never runs the fleet's checkouts."""
import datetime
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import time

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(os.environ.get("FLEET_EASY_TEST_SCRIPT", ROOT / "scripts/fleet-update-easy"))
REAL_GIT = shutil.which("git")


def command(args, env, check=True):
    return subprocess.run([str(a) for a in args], env=env, text=True,
                          capture_output=True, check=check, timeout=20)


def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


class Fleet:
    def __init__(self, tmp):
        self.tmp = tmp
        self.home = tmp / "home"
        self.home.mkdir()
        self.bin = tmp / "bin"
        self.bin.mkdir()
        self.calls = tmp / "git-calls"
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.bin) + ":" + os.environ["PATH"],
                        GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
                        GIT_ALLOW_PROTOCOL="file", GIT_TERMINAL_PROMPT="0",
                        GIT_AUTHOR_NAME="Test", GIT_AUTHOR_EMAIL="test@example.invalid",
                        GIT_COMMITTER_NAME="Test", GIT_COMMITTER_EMAIL="test@example.invalid",
                        TEST_ROOT=str(tmp), TEST_CALLS=str(self.calls), REAL_GIT=REAL_GIT)
        # The PATH shim both proves PATH ordering and refuses any real checkout.
        executable(self.bin / "git", """#!/usr/bin/env python3
import os, pathlib, sys, time
a = sys.argv[1:]
assert '-C' in a
p = pathlib.Path(a[a.index('-C') + 1]).resolve()
assert pathlib.Path(os.environ['TEST_ROOT']) in p.parents
with open(os.environ['TEST_CALLS'], 'a') as f:
    f.write(repr(a) + '\\n')
if 'fetch' in a and os.environ.get('TEST_BLOCK'):
    pathlib.Path(os.environ['TEST_BLOCK']).touch()
    while not pathlib.Path(os.environ['TEST_BLOCK'] + '.release').exists():
        time.sleep(.02)
os.execv(os.environ['REAL_GIT'], [os.environ['REAL_GIT']] + a)
""")
        self.repos = {}
        self.seeds = {}
        for name, path in [("hermes-config", self.home / ".hermes"),
                           ("hermes-host-bootstrap", self.home / "code/bootstrap & test"),
                           ("hermes-automation-wiki", self.home / "code/hermes-automation-wiki")]:
            seed = tmp / (name + "-seed")
            remote = tmp / (name + ".git")
            self.git(tmp, "init", "--bare", "--initial-branch=main", str(remote))
            self.git(tmp, "init", "--initial-branch=main", str(seed))
            (seed / "tracked.txt").write_text("original\n")
            (seed / "other.txt").write_text("other\n")
            if name == "hermes-host-bootstrap":
                (seed / "scripts").mkdir()
                shutil.copy2(SCRIPT, seed / "scripts/fleet-update-easy")
            self.git(seed, "add", ".")
            self.git(seed, "commit", "-m", "initial")
            self.git(seed, "remote", "add", "origin", str(remote))
            self.git(seed, "push", "-u", "origin", "main")
            path.parent.mkdir(parents=True, exist_ok=True)
            self.git(tmp, "clone", str(remote), str(path))
            self.repos[name] = path
            self.seeds[name] = seed
        self.script = self.repos["hermes-host-bootstrap"] / "scripts/fleet-update-easy"
        self.state = self.home / ".local/state/fleet-update-easy"

    def git(self, path, *args):
        return command([REAL_GIT, "-C", path, *args], self.env).stdout.strip()

    def advance(self, name="hermes-config", file="tracked.txt"):
        seed = self.seeds[name]
        (seed / file).write_text("upstream\n")
        self.git(seed, "add", ".")
        self.git(seed, "commit", "-m", "advance")
        self.git(seed, "push")
        return self.git(seed, "rev-parse", "HEAD")

    def run(self, *args):
        result = command(["bash", self.script, *args], self.env)
        if args:
            return result
        return json.loads((self.state / "status.json").read_text())

    def row(self, name="hermes-config"):
        return next(r for r in self.run()["repos"] if r["name"] == name)


@pytest.fixture
def fleet(tmp_path):
    return Fleet(tmp_path)


def test_current_status_shape(fleet):
    report = fleet.run()
    assert set(report) == {"host", "ran_at", "version", "repos"}
    assert report["host"]
    datetime.datetime.strptime(report["ran_at"], "%Y-%m-%dT%H:%M:%SZ")
    assert report["version"] == fleet.git(fleet.repos["hermes-host-bootstrap"], "rev-parse", "HEAD")
    assert len(report["repos"]) == 3
    for row in report["repos"]:
        assert set(row) == {"name", "path", "result", "from", "to", "behind_after", "files"}
        assert row["result"] == "current"
        assert row["from"] == row["to"]
        assert row["behind_after"] == 0 and row["files"] == []
    assert json.loads((fleet.state / "log").read_text()) == report
    assert "'fetch'" in fleet.calls.read_text()


@pytest.mark.parametrize("name", ["hermes-config", "hermes-host-bootstrap", "hermes-automation-wiki"])
def test_updated(fleet, name):
    before = fleet.git(fleet.repos[name], "rev-parse", "HEAD")
    after = fleet.advance(name)
    row = fleet.row(name)
    assert row["result"] == "updated {}..{} (+1)".format(before[:12], after[:12])
    assert row["from"] == before and row["to"] == after and row["behind_after"] == 0
    assert (fleet.repos[name] / "tracked.txt").read_text() == "upstream\n"


@pytest.mark.parametrize("staged", [False, True])
@pytest.mark.parametrize("autostash", [False, True])
def test_held_local_edits_unchanged(fleet, staged, autostash):
    repo = fleet.repos["hermes-config"]
    fleet.advance()
    fleet.git(repo, "config", "merge.autoStash", str(autostash).lower())
    (repo / "tracked.txt").write_text("local work\n")
    if staged:
        fleet.git(repo, "add", "tracked.txt")
    before = fleet.git(repo, "status", "--porcelain")
    row = fleet.row()
    assert row["result"] == "held:local_edits" and row["files"] == ["tracked.txt"]
    assert row["from"] == row["to"] and row["behind_after"] == 1
    assert (repo / "tracked.txt").read_text() == "local work\n"
    assert fleet.git(repo, "status", "--porcelain") == before


def test_unrelated_local_edits_allow_update(fleet):
    repo = fleet.repos["hermes-config"]
    fleet.advance()
    (repo / "other.txt").write_text("local work\n")
    assert fleet.row()["result"].startswith("updated ")
    assert (repo / "other.txt").read_text() == "local work\n"


def test_untracked_collision_preserved(fleet):
    repo = fleet.repos["hermes-config"]
    fleet.advance(file="new.txt")
    (repo / "new.txt").write_text("untracked local work\n")
    row = fleet.row()
    assert row["result"] == "held:local_edits" and row["files"] == ["new.txt"]
    assert (repo / "new.txt").read_text() == "untracked local work\n"


@pytest.mark.parametrize("upstream_moves", [False, True])
def test_held_diverged(fleet, upstream_moves):
    repo = fleet.repos["hermes-config"]
    (repo / "other.txt").write_text("local commit\n")
    fleet.git(repo, "add", ".")
    fleet.git(repo, "commit", "-m", "local")
    before = fleet.git(repo, "rev-parse", "HEAD")
    if upstream_moves:
        fleet.advance()
    row = fleet.row()
    assert row["result"] == "held:diverged"
    assert row["from"] == row["to"] == before


@pytest.mark.parametrize("mode", ["tracks_main", "tracks_feature", "detached"])
def test_held_not_on_default(fleet, mode):
    repo = fleet.repos["hermes-config"]
    if mode == "detached":
        fleet.git(repo, "checkout", "--detach")
    else:
        fleet.git(repo, "checkout", "-b", "feature", "--track", "origin/main")
        if mode == "tracks_feature":
            fleet.git(repo, "push", "-u", "origin", "feature")
    fleet.advance()
    assert fleet.row()["result"] == "held:not_on_default"


def test_missing_cached_default(fleet):
    repo = fleet.repos["hermes-config"]
    fleet.git(repo, "symbolic-ref", "--delete", "refs/remotes/origin/HEAD")
    fleet.advance()
    assert fleet.row()["result"].startswith("updated ")


def test_fetch_failure(fleet):
    repo = fleet.repos["hermes-config"]
    fleet.git(repo, "remote", "set-url", "origin", str(fleet.tmp / "missing.git"))
    assert fleet.row()["result"] == "held:fetch_failed"


@pytest.mark.parametrize("mode", ["absent", "no_git", "no_upstream"])
def test_absent(fleet, mode):
    repo = fleet.repos["hermes-config"]
    if mode == "no_upstream":
        fleet.git(repo, "branch", "--unset-upstream")
    else:
        shutil.rmtree(repo)
        if mode == "no_git":
            repo.mkdir()
    assert fleet.row()["result"] == "skipped:absent"


def snapshot(path):
    return {str(p.relative_to(path)): p.read_bytes() for p in path.rglob("*") if p.is_file()}


def test_dry_run_changes_nothing(fleet):
    fleet.advance()
    before = snapshot(fleet.home)
    result = fleet.run("--dry-run")
    assert "would fetch" in result.stdout and "rev-list --count" in result.stdout
    assert snapshot(fleet.home) == before
    assert not fleet.state.exists()
    assert "'fetch'" not in fleet.calls.read_text()


def test_symlink_resolves_checkout(fleet):
    link = fleet.home / "shortcut"
    link.symlink_to(fleet.script)
    fleet.script = link
    assert fleet.row("hermes-host-bootstrap")["path"] == str(fleet.repos["hermes-host-bootstrap"])


def test_mutex_busy(fleet):
    ready = fleet.tmp / "fetch-ready"
    env = dict(fleet.env, TEST_BLOCK=str(ready))
    with subprocess.Popen(["bash", str(fleet.script)], env=env, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True) as first:
        try:
            deadline = time.monotonic() + 10
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(.02)
            assert ready.exists()
            second = command(["bash", fleet.script], fleet.env)
            assert second.stdout.strip() == "busy"
            assert not (fleet.state / "status.json").exists()
        finally:
            Path(str(ready) + ".release").touch()
            first.communicate(timeout=15)
        assert first.returncode == 0


def test_log_keeps_last_500(fleet):
    fleet.state.mkdir(parents=True)
    (fleet.state / "log").write_text("old\n" * 510)
    fleet.run()
    lines = (fleet.state / "log").read_text().splitlines()
    assert len(lines) == 500 and json.loads(lines[-1])["repos"]


@pytest.fixture
def module(tmp_path):
    repo = tmp_path / "repo & test"
    home = tmp_path / "home"
    bins = tmp_path / "bin"
    for path in [repo / "lib", repo / "scripts", home, bins]:
        path.mkdir(parents=True)
    for source in ["bootstrap.sh", "lib/common.sh", "lib/M9-fleet-update-easy.sh", "scripts/fleet-update-easy"]:
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
    return command(["bash", repo / "bootstrap.sh", "--only=M9-fleet-update-easy", *args], env)


def test_module_mac_calendar_idempotent_reload(module):
    repo, home, env = module
    bootstrap(module)
    plist = home / "Library/LaunchAgents/com.hermes.fleet-update-easy.plist"
    data = plistlib.loads(plist.read_bytes())
    assert data["StartCalendarInterval"] == [{"Hour": h, "Minute": 17} for h in range(0, 24, 2)]
    assert "StartInterval" not in data and data["RunAtLoad"] is True
    assert data["ProgramArguments"] == ["/bin/bash", str(repo / "scripts/fleet-update-easy")]
    assert (home / ".local/bin/fleet-update-easy").resolve() == repo / "scripts/fleet-update-easy"
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
    plist = home / "Library/LaunchAgents/com.hermes.fleet-update-easy.plist"
    plist.write_text("stale")
    env["TEST_STUCK"] = "1"
    Path(env["TEST_CALLS"]).write_text("")
    result = bootstrap(module)
    assert "still loaded after bootout" in result.stdout + result.stderr
    assert "bootstrap " not in Path(env["TEST_CALLS"]).read_text()
    assert plist.read_text() == "stale"


@pytest.mark.parametrize("args,os_name,host", [(["--skip=fleet-update-easy"], "Darwin", "h-mini"),
                                               (["--role=client"], "Linux", "h-do1"),
                                               (["--role=server"], "Linux", "other")])
def test_module_gates_through_bootstrap(module, args, os_name, host):
    _, home, env = module
    env.update(TEST_OS=os_name, HERMES_HOSTNAME=host)
    bootstrap(module, *args)
    assert not (home / ".local/bin/fleet-update-easy").exists()
    assert not Path(env["TEST_CALLS"]).exists()
    assert not Path(env["HERMES_SYSTEMD_DIR"]).exists()


@pytest.mark.parametrize("role", ["client", "server", "both"])
def test_module_mac_all_roles_minimal_tier(module, role):
    _, home, _ = module
    bootstrap(module, "--role=" + role, "--tier=minimal")
    assert (home / "Library/LaunchAgents/com.hermes.fleet-update-easy.plist").exists()


def test_module_linux_units_idempotent(module):
    repo, _, env = module
    env["TEST_OS"] = "Linux"
    bootstrap(module, "--role=server")
    units = Path(env["HERMES_SYSTEMD_DIR"])
    service = units / "hermes-fleet-update-easy.service"
    timer = units / "hermes-fleet-update-easy.timer"
    assert "User=root\n" in service.read_text()
    assert str(repo / "scripts/fleet-update-easy") in service.read_text()
    assert "OnCalendar=*-*-* 00/2:17:00\n" in timer.read_text()
    assert "Persistent=true\n" in timer.read_text()
    before = snapshot(units)
    calls = Path(env["TEST_CALLS"])
    calls.write_text("")
    bootstrap(module, "--role=server")
    assert snapshot(units) == before and "daemon-reload" not in calls.read_text()
    assert "restart hermes-fleet-update-easy.service hermes-fleet-update-easy.timer" in calls.read_text()
    if shutil.which("systemd-analyze"):
        command(["systemd-analyze", "verify", service, timer], env)
