"""Local bare remotes and fake schedulers only; never runs the fleet's checkouts."""
import ast
import datetime
import fcntl
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import time

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(os.environ.get("FLEET_EASY_TEST_SCRIPT", ROOT / "scripts/fleet-update-easy"))
REAL_GIT = shutil.which("git")
REAL_PERL = shutil.which("perl")
SNIPPETS = [
    ("dotfiles/aliases.sh", ".hermes-host-bootstrap.aliases.sh"),
    ("dotfiles/zshrc-snippet.sh", ".hermes-host-bootstrap.zshrc"),
    ("dotfiles/zshenv-snippet.sh", ".hermes-host-bootstrap.zshenv.sh"),
    ("dotfiles/tmux-autoattach.sh", ".hermes-host-bootstrap.tmux-autoattach.sh"),
    ("dotfiles/hssh.sh", ".hermes-host-bootstrap.hssh.sh"),
    ("dotfiles/mouse-heal.sh", ".hermes-host-bootstrap.mouse-heal.sh"),
    ("dotfiles/tmux-workspace-colors.conf", ".hermes-host-bootstrap.tmux-workspace-colors.conf"),
]
USER_FILES = [("dotfiles/tmux.conf", ".tmux.conf"), ("dotfiles/inputrc", ".inputrc"),
              ("dotfiles/ghostty-config", ".config/ghostty/config")]


def age(path):
    old = time.time() - 600
    os.utime(path, (old, old))


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
        self.env.pop("GIT_SSH_COMMAND", None)
        # The PATH shim both proves PATH ordering and refuses any real checkout.
        executable(self.bin / "git", """#!/usr/bin/env python3
import os, pathlib, signal, sys, time
a = sys.argv[1:]
assert '-C' in a
p = pathlib.Path(a[a.index('-C') + 1]).resolve()
assert pathlib.Path(os.environ['TEST_ROOT']) in p.parents
with open(os.environ['TEST_CALLS'], 'a') as f:
    f.write(repr(a) + '\\n')
if 'fetch' in a and str(p) == os.environ.get('TEST_HANG'):
    lock = p / '.git/fake-fetch.lock'
    lock.touch()
    pathlib.Path(os.environ['TEST_PID']).write_text(str(os.getpid()))
    def term(signum, frame):
        pathlib.Path(os.environ['TEST_TERM']).touch()
        if not os.environ.get('TEST_IGNORE_TERM'):
            lock.unlink()
            sys.exit(0)
    signal.signal(signal.SIGTERM, term)
    while True:
        time.sleep(.02)
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
                (seed / "lib").mkdir()
                shutil.copy2(ROOT / "lib/30-shell.sh", seed / "lib/30-shell.sh")
                (seed / "dotfiles").mkdir()
                for source, _ in SNIPPETS + USER_FILES:
                    (seed / source).write_text("# original " + source + "\n")
            self.git(seed, "add", ".")
            self.git(seed, "commit", "-m", "initial")
            self.git(seed, "remote", "add", "origin", str(remote))
            self.git(seed, "push", "-u", "origin", "main")
            path.parent.mkdir(parents=True, exist_ok=True)
            self.git(tmp, "clone", str(remote), str(path))
            age(path / "tracked.txt")
            age(path / "other.txt")
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

    def install_snippet(self, index=0):
        source, target = SNIPPETS[index]
        installed = self.home / target
        shutil.copyfile(self.repos["hermes-host-bootstrap"] / source, installed)
        return installed


@pytest.fixture
def fleet(tmp_path):
    return Fleet(tmp_path)


def test_current_status_shape(fleet):
    report = fleet.run()
    assert set(report) == {"host", "ran_at", "version", "repos"}
    assert report["host"]
    datetime.datetime.strptime(report["ran_at"], "%Y-%m-%dT%H:%M:%SZ")
    assert report["version"] == fleet.git(fleet.repos["hermes-host-bootstrap"], "rev-parse", "HEAD")
    assert len(report["repos"]) == 4
    for row in report["repos"][:3]:
        assert set(row) == {"name", "path", "result", "from", "to", "behind_after", "files"}
        assert row["result"] == "current"
        assert row["from"] == row["to"]
        assert row["behind_after"] == 0 and row["files"] == []
    snippets = report["repos"][3]
    assert snippets["name"] == "shell-snippets" and snippets["result"] == "current"
    assert snippets["files"] == [dict(source=source, path=str(fleet.home / target), result="skipped:absent")
                                 for source, target in SNIPPETS]
    assert all(not (fleet.home / target).exists() for _, target in SNIPPETS)
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
    age(repo / "tracked.txt")
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
    age(repo / "new.txt")
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
    row = fleet.row()
    assert row["result"] == "held:fetch_failed"
    assert row["behind_after"] is None


def test_ignored_collision_preserves_bytes(fleet):
    repo = fleet.repos["hermes-config"]
    (repo / ".git/info/exclude").write_text("secret.txt\n")
    secret = repo / "secret.txt"
    secret.write_bytes(b"local secret\x00\xff\n")
    age(secret)
    before = secret.read_bytes()
    fleet.advance(file="secret.txt")
    row = fleet.row()
    assert row["result"] == "held:local_edits"
    assert row["files"] == ["secret.txt"]
    assert row["from"] == row["to"] and row["behind_after"] == 1
    assert secret.read_bytes() == before


def test_index_lock_error_isolated_and_status_rewritten(fleet):
    fleet.run()
    previous = (fleet.state / "status.json").read_bytes()
    for name in fleet.repos:
        fleet.advance(name)
    repo = fleet.repos["hermes-config"]
    (repo / ".git/index.lock").write_text("another git owns this\n")
    result = command(["bash", fleet.script], fleet.env, check=False)
    assert result.returncode == 1
    assert (fleet.state / "status.json").read_bytes() != previous
    report = json.loads((fleet.state / "status.json").read_text())
    error, *others = report["repos"][:3]
    assert error["result"] == "error" and "index.lock" in error["message"]
    assert len(error["message"]) <= 300 and "\n" not in error["message"]
    assert all(row["result"].startswith("updated ") for row in others)
    assert (repo / "tracked.txt").read_text() == "original\n"
    assert (repo / ".git/index.lock").read_text() == "another git owns this\n"
    assert json.loads((fleet.state / "log").read_text().splitlines()[-1]) == report


@pytest.mark.parametrize("ignore_term", [False, True])
def test_hanging_fetch_terminates_then_kills_if_needed(fleet, ignore_term):
    # Accelerate only the real fetch process's waits; record the production caps.
    patches = fleet.tmp / "python-patches"
    patches.mkdir()
    (patches / "sitecustomize.py").write_text('''import os, subprocess
original = subprocess.Popen.communicate
def communicate(self, input=None, timeout=None):
    if isinstance(self.args, list) and "fetch" in self.args:
        with open(os.environ["TEST_TIMEOUTS"], "a") as stream:
            stream.write(str(timeout) + "\\n")
        timeout = {120: .3, 10: .3}.get(timeout, timeout)
    return original(self, input=input, timeout=timeout)
subprocess.Popen.communicate = communicate
''')
    repo = fleet.repos["hermes-config"]
    term = fleet.tmp / "term"
    pid = fleet.tmp / "pid"
    timeouts = fleet.tmp / "timeouts"
    fleet.env.update(PYTHONPATH=str(patches), TEST_HANG=str(repo), TEST_TERM=str(term),
                     TEST_PID=str(pid), TEST_TIMEOUTS=str(timeouts))
    if ignore_term:
        fleet.env["TEST_IGNORE_TERM"] = "1"
    fleet.advance("hermes-automation-wiki")
    report = fleet.run()
    row = report["repos"][0]
    assert row["result"] == "held:fetch_failed" and row["behind_after"] is None
    assert report["repos"][2]["result"].startswith("updated ")
    assert term.exists()
    assert timeouts.read_text().splitlines()[:2] == ["120", "10"]
    if ignore_term:
        assert timeouts.read_text().splitlines()[2] == "None"
    else:
        assert not (repo / ".git/fake-fetch.lock").exists()
    with pytest.raises(ProcessLookupError):
        os.kill(int(pid.read_text()), 0)


def test_updater_can_replace_its_own_script(fleet):
    name = "hermes-host-bootstrap"
    seed = fleet.seeds[name]
    replacement = '#!/bin/bash\necho "replacement executed unexpectedly"\nexit 91\n'
    (seed / "scripts/fleet-update-easy").write_text(replacement)
    fleet.git(seed, "add", "scripts/fleet-update-easy")
    fleet.git(seed, "commit", "-m", "replace updater")
    fleet.git(seed, "push")
    fleet.advance("hermes-automation-wiki")
    report = fleet.run()
    assert report["repos"][1]["result"].startswith("updated ")
    assert report["repos"][2]["result"].startswith("updated ")
    assert fleet.script.read_text() == replacement
    assert json.loads((fleet.state / "log").read_text()) == report


@pytest.mark.parametrize("name", ["hermes-config", "hermes-host-bootstrap", "hermes-automation-wiki"])
def test_recently_written_hold_only_hermes(fleet, name):
    fleet.advance(name)
    repo = fleet.repos[name]
    os.utime(repo / "tracked.txt", None)  # Clean, but recently written by Hermes.
    row = fleet.row(name)
    if name == "hermes-config":
        assert row["result"] == "held:recently_written"
        assert row["files"] == ["tracked.txt"]
        assert (repo / "tracked.txt").read_text() == "original\n"
        age(repo / "tracked.txt")
        assert fleet.row(name)["result"].startswith("updated ")
    else:
        assert row["result"].startswith("updated ")


@pytest.mark.parametrize("setting", ["true", "false"])
@pytest.mark.parametrize("behind", [False, True])
def test_lfs_required_set_holds(fleet, setting, behind):
    repo = fleet.repos["hermes-config"]
    if behind:
        fleet.advance()
    fleet.git(repo, "config", "filter.lfs.required", setting)
    row = fleet.row()
    assert row["result"] == "held:lfs" and row["from"] == row["to"]
    assert "'merge', '--ff-only'" not in fleet.calls.read_text()


def test_dry_run_missing_remote_head(fleet):
    fleet.git(fleet.repos["hermes-config"], "symbolic-ref", "--delete", "refs/remotes/origin/HEAD")
    result = fleet.run("--dry-run")
    assert "hermes-config: unknown_default" in result.stdout
    assert "'ls-remote'" not in fleet.calls.read_text()


def test_unicode_collision_filename(fleet):
    repo = fleet.repos["hermes-config"]
    filename = "mémoire.txt"
    fleet.advance(file=filename)
    (repo / filename).write_text("local\n")
    age(repo / filename)
    row = fleet.row()
    assert row["result"] == "held:local_edits" and row["files"] == [filename]


def test_mac_without_clt_never_invokes_git(fleet):
    executable(fleet.bin / "uname", '#!/bin/sh\necho Darwin\n')
    executable(fleet.bin / "xcode-select", '#!/bin/sh\nexit 1\n')
    executable(fleet.bin / "git", '#!/bin/sh\necho "git invoked" >> "$TEST_CALLS"\nexit 91\n')
    report = fleet.run()
    assert all(row["result"] == "skipped:no_git" for row in report["repos"])
    assert report["version"] == "unknown"
    assert not fleet.calls.exists()


@pytest.mark.parametrize("setting", ["unset", "config", "env", "empty_env"])
def test_ssh_batch_mode_preserves_user_command(fleet, setting):
    repo = fleet.repos["hermes-config"]
    if setting == "config":
        fleet.git(repo, "config", "core.sshCommand", "ssh -o CustomOption=yes")
    elif setting in ("env", "empty_env"):
        fleet.env["GIT_SSH_COMMAND"] = "ssh -o CustomOption=yes" if setting == "env" else ""
    fleet.run()
    calls = [ast.literal_eval(line) for line in fleet.calls.read_text().splitlines()]
    fetch = next(call for call in calls if "fetch" in call and str(repo) in call)
    assert ("core.sshCommand=ssh -o BatchMode=yes" in fetch) == (setting == "unset")


@pytest.mark.parametrize("name", ["hermes-config", "hermes-host-bootstrap", "hermes-automation-wiki"])
def test_foreign_owner_never_invokes_git_or_writes_tree(fleet, name):
    repo = fleet.repos[name]
    fleet.advance(name)
    before = snapshot(repo)
    # Simulate a foreign UID even in containers that cannot chown to another UID.
    patches = fleet.tmp / "python-patches"
    patches.mkdir()
    (patches / "sitecustomize.py").write_text('''import os, pathlib
original = pathlib.Path.stat
def stat(self, *args, **kwargs):
    result = original(self, *args, **kwargs)
    if str(self) == os.environ["TEST_FOREIGN_OWNER"]:
        fields = list(result)
        fields[4] = result.st_uid + 1
        return os.stat_result(fields)
    return result
pathlib.Path.stat = stat
''')
    fleet.env.update(PYTHONPATH=str(patches), TEST_FOREIGN_OWNER=str(repo))
    row = fleet.row(name)
    assert row["result"] == "held:not_owner"
    assert str(repo) not in fleet.calls.read_text()
    assert snapshot(repo) == before


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



def test_preserved_host_leaves_hermes_config_alone(fleet):
    fleet.advance()
    marker = fleet.home / ".config/fleet-update/preserve-hermes-config"
    marker.parent.mkdir(parents=True)
    marker.touch()
    repo = fleet.repos["hermes-config"]
    before = snapshot(repo)
    fleet.advance("hermes-host-bootstrap")
    rows = {r["name"]: r for r in fleet.run()["repos"]}
    assert rows["hermes-config"]["result"] == "skipped:preserved"
    assert str(repo) not in fleet.calls.read_text()
    assert snapshot(repo) == before
    assert rows["hermes-host-bootstrap"]["result"].startswith("updated")

def snapshot(path):
    return {str(p.relative_to(path)): p.read_bytes() for p in path.rglob("*") if p.is_file()}


def copy_state(path):
    content = path.read_bytes()
    info = path.stat()
    # Reading may update atime; all content, identity and write metadata must stay put.
    return content, tuple(getattr(info, key) for key in (
        "st_dev", "st_ino", "st_mode", "st_uid", "st_gid", "st_nlink",
        "st_size", "st_mtime_ns", "st_ctime_ns"))


def test_snippets_identical_without_history_lookups(fleet):
    installed = [fleet.install_snippet(i) for i in range(len(SNIPPETS))]
    before = [(path.stat().st_ino, path.stat().st_mtime_ns) for path in installed]
    row = fleet.row("shell-snippets")
    assert row["result"] == "current"
    assert all(entry["result"] == "current" for entry in row["files"])
    assert [(path.stat().st_ino, path.stat().st_mtime_ns) for path in installed] == before
    calls = [ast.literal_eval(line) for line in fleet.calls.read_text().splitlines()]
    assert not any("log" in call or "hash-object" in call for call in calls)


@pytest.mark.parametrize("source,target", SNIPPETS)
def test_snippets_refresh_historical_copy_after_fast_forward(fleet, source, target):
    name = "hermes-host-bootstrap"
    installed = fleet.install_snippet(SNIPPETS.index((source, target)))
    installed.chmod(0o751)
    before = installed.stat()
    # The installed bytes are two revisions old, including the root commit.
    fleet.advance(name, file=source)
    seed = fleet.seeds[name]
    latest = b"# latest snippet\n# byte-preserving: \xff\x00\n"
    (seed / source).write_bytes(latest)
    fleet.git(seed, "add", source)
    fleet.git(seed, "commit", "-m", "latest snippet")
    fleet.git(seed, "push")
    row = fleet.row("shell-snippets")
    assert row["result"] == "refreshed 1"
    entry = next(entry for entry in row["files"] if entry["source"] == source)
    assert entry["result"] == "refreshed" and entry["path"] == str(installed)
    assert installed.read_bytes() == latest
    assert installed.stat().st_mode == before.st_mode
    assert installed.stat().st_ino != before.st_ino  # Atomic replacement, not an in-place write.
    assert not list(fleet.home.glob("..hermes-host-bootstrap.*"))
    calls = [ast.literal_eval(line) for line in fleet.calls.read_text().splitlines()]
    history = [call for call in calls if "log" in call]
    assert len(history) == 1
    assert history[0][history[0].index("--") + 1:] == [source for source, _ in SNIPPETS]


@pytest.mark.parametrize("edited_index", [0, 6])
@pytest.mark.parametrize("dry", [False, True])
def test_snippets_local_edits_hold_entire_set(fleet, edited_index, dry):
    installed = [fleet.install_snippet(i) for i in range(len(SNIPPETS))]
    secret = b"private local alias\x00\xff\n"
    installed[edited_index].write_bytes(secret)
    before = [copy_state(path) for path in installed]
    for source, _ in SNIPPETS:
        fleet.advance("hermes-host-bootstrap", file=source)
    if dry:
        repo = fleet.repos["hermes-host-bootstrap"]
        fleet.git(repo, "fetch", "origin")
        fleet.git(repo, "merge", "--ff-only", "@{u}")
    result = command(["bash", fleet.script] + (["--dry-run"] if dry else []), fleet.env)
    if dry:
        output = result.stdout.split("shell-snippets: held:local_edits ")[1]
        entries = json.loads(output)
        assert "would refresh" not in result.stdout
        assert not fleet.state.exists()
    else:
        row = json.loads((fleet.state / "status.json").read_text())["repos"][-1]
        assert row["result"] == "held:local_edits"
        entries = row["files"]
        assert "private local alias" not in (fleet.state / "log").read_text()
    assert entries[edited_index]["result"] == "held:local_edits"
    assert all(entry["result"] == "skipped:set_held" for i, entry in enumerate(entries)
               if i != edited_index)
    assert [copy_state(path) for path in installed] == before
    assert "private local alias" not in result.stdout + result.stderr
    assert not list(fleet.home.glob("..hermes-host-bootstrap.*"))


def test_snippets_history_is_specific_to_source_path(fleet):
    installed = fleet.install_snippet()
    other = (fleet.repos["hermes-host-bootstrap"] / SNIPPETS[4][0]).read_bytes()
    installed.write_bytes(other)
    fleet.advance("hermes-host-bootstrap", file=SNIPPETS[0][0])
    assert fleet.row("shell-snippets")["result"] == "held:local_edits"
    assert installed.read_bytes() == other


@pytest.mark.parametrize("history", ["renamed_away", "merged_branch"])
def test_snippets_include_older_path_and_merge_history(fleet, history):
    name = "hermes-host-bootstrap"
    seed = fleet.seeds[name]
    source = SNIPPETS[0][0]
    installed = fleet.install_snippet()
    if history == "renamed_away":
        fleet.git(seed, "mv", source, "dotfiles/old-aliases.sh")
        fleet.git(seed, "commit", "-m", "rename aliases")
    else:
        fleet.git(seed, "checkout", "-b", "side")
        (seed / source).write_text("# side branch copy\n")
        installed.write_bytes((seed / source).read_bytes())
        fleet.git(seed, "add", source)
        fleet.git(seed, "commit", "-m", "side aliases")
        fleet.git(seed, "checkout", "main")
        fleet.git(seed, "merge", "--no-ff", "-s", "ours", "side", "-m", "merge side")
    fleet.advance(name, file=source)
    assert fleet.row("shell-snippets")["result"] == "refreshed 1"
    assert installed.read_text() == "upstream\n"


@pytest.mark.parametrize("failure", ["concurrent_edit", "replace_error"])
def test_snippets_preserve_bytes_and_clean_temp_on_interrupted_refresh(fleet, failure):
    installed = fleet.install_snippet()
    other = fleet.install_snippet(4)
    before = installed.read_bytes()
    other_before = copy_state(other)
    for source, _ in (SNIPPETS[0], SNIPPETS[4]):
        fleet.advance("hermes-host-bootstrap", file=source)
    patches = fleet.tmp / "python-patches"
    patches.mkdir()
    (patches / "sitecustomize.py").write_text('''import os, pathlib, tempfile
path = pathlib.Path(os.environ["TEST_SNIPPET"])
if os.environ["TEST_FAILURE"] == "concurrent_edit":
    original = tempfile.mkstemp
    def mkstemp(*args, **kwargs):
        result = original(*args, **kwargs)
        if kwargs.get("prefix") == "." + path.name + ".":
            path.write_bytes(b"private concurrent edit\\n")
        return result
    tempfile.mkstemp = mkstemp
else:
    original = os.replace
    def replace(source, destination):
        if str(destination) == str(path):
            raise OSError("private error details")
        return original(source, destination)
    os.replace = replace
''')
    fleet.env.update(PYTHONPATH=str(patches), TEST_SNIPPET=str(installed), TEST_FAILURE=failure)
    result = command(["bash", fleet.script], fleet.env, check=False)
    assert result.returncode == (1 if failure == "replace_error" else 0)
    row = json.loads((fleet.state / "status.json").read_text())["repos"][-1]
    assert row["result"] == ("held:error" if failure == "replace_error" else "held:local_edits")
    assert row["files"][0]["result"] == ("error" if failure == "replace_error" else "held:local_edits")
    assert row["files"][4]["result"] == "skipped:set_held"
    assert copy_state(other) == other_before
    assert installed.read_bytes() == (before if failure == "replace_error" else b"private concurrent edit\n")
    assert not list(fleet.home.glob("..hermes-host-bootstrap.*"))
    assert "private" not in result.stdout + result.stderr + (fleet.state / "log").read_text()


def test_snippets_dry_run_does_not_write(fleet):
    installed = fleet.install_snippet()
    fleet.advance("hermes-host-bootstrap", file=SNIPPETS[0][0])
    repo = fleet.repos["hermes-host-bootstrap"]
    fleet.git(repo, "fetch", "origin")
    fleet.git(repo, "merge", "--ff-only", "@{u}")
    before = snapshot(fleet.home)
    mode = installed.stat().st_mode
    result = fleet.run("--dry-run")
    assert "shell-snippets: would refresh ~/" + installed.name in result.stdout
    assert '"result": "would_refresh"' in result.stdout
    assert "preview against the current (pre-merge) checkout" in result.stdout
    assert snapshot(fleet.home) == before and installed.stat().st_mode == mode
    assert not fleet.state.exists()


@pytest.mark.parametrize("reason", ["held:local_edits", "error", "skipped:absent"])
def test_snippets_skip_untrusted_bootstrap(fleet, reason):
    installed = fleet.install_snippet()
    before = installed.read_bytes()
    repo = fleet.repos["hermes-host-bootstrap"]
    fleet.advance("hermes-host-bootstrap", file=SNIPPETS[0][0])
    if reason == "held:local_edits":
        (repo / SNIPPETS[0][0]).write_text("local source edit\n")
    elif reason == "error":
        (repo / ".git/index.lock").touch()
    else:
        shutil.rmtree(repo / ".git")
    result = command(["bash", fleet.script], fleet.env, check=False)
    assert result.returncode == (1 if reason == "error" else 0)
    report = json.loads((fleet.state / "status.json").read_text())
    assert report["repos"][1]["result"] == reason
    row = report["repos"][-1]
    skipped = reason if reason.startswith("skipped:") else "skipped:" + reason
    assert row["result"] == skipped
    assert all(entry["result"] == skipped for entry in row["files"])
    assert installed.read_bytes() == before
    assert "'hash-object'" not in fleet.calls.read_text() and "'log'" not in fleet.calls.read_text()


def test_snippets_never_touch_user_owned_files(fleet):
    repo = fleet.repos["hermes-host-bootstrap"]
    originals = {}
    for source, target in USER_FILES:
        path = fleet.home / target
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(repo / source, path)
        path.chmod(0o640)
        originals[path] = (path.read_bytes(), path.stat())
        fleet.advance("hermes-host-bootstrap", file=source)
    managed = fleet.install_snippet()
    fleet.advance("hermes-host-bootstrap", file=SNIPPETS[0][0])
    assert fleet.row("shell-snippets")["result"] == "refreshed 1"
    assert managed.read_text() == "upstream\n"
    for path, (content, before) in originals.items():
        assert path.read_bytes() == content
        after = path.stat()
        keys = ("st_ino", "st_mode", "st_mtime_ns", "st_ctime_ns")
        assert all(getattr(after, key) == getattr(before, key) for key in keys)


@pytest.mark.parametrize("kind", ["symlink", "dangling_symlink", "directory", "fifo"])
def test_snippets_preserve_custom_file_types(fleet, kind):
    path = fleet.home / SNIPPETS[0][1]
    target = fleet.home / ".tmux.conf"
    if kind == "directory":
        path.mkdir()
    elif kind == "fifo":
        os.mkfifo(path)
    else:
        if kind == "symlink":
            shutil.copyfile(fleet.repos["hermes-host-bootstrap"] / SNIPPETS[0][0], target)
        path.symlink_to(target)
    fleet.advance("hermes-host-bootstrap", file=SNIPPETS[0][0])
    before = snapshot(fleet.home) if kind != "dangling_symlink" else None
    row = fleet.row("shell-snippets")
    assert row["result"] == row["files"][0]["result"] == "held:not_regular"
    if kind == "directory":
        assert path.is_dir()
    elif kind == "fifo":
        assert stat.S_ISFIFO(path.lstat().st_mode)
    else:
        assert path.is_symlink() and os.readlink(path) == str(target)
        if kind == "symlink":
            assert target.read_bytes() == before[".tmux.conf"]
        else:
            assert not target.exists()


def patch_snippet_python(fleet, code, **env):
    patches = fleet.tmp / "snippet-patches"
    patches.mkdir()
    (patches / "sitecustomize.py").write_text(code)
    fleet.env.update(PYTHONPATH=str(patches), **{key: str(value) for key, value in env.items()})


def test_snippets_mapping_matches_verbatim_bootstrap_copies():
    module = (ROOT / "lib/30-shell.sh").read_text().replace("\\\n", " ")
    copies = re.findall(r'\bcp "\$REPO_ROOT/(dotfiles/[^"\n]+)"\s+"\$HOME/(\.hermes-host-bootstrap\.[^"\n]+)"', module)
    assert len(copies) == len(SNIPPETS) and set(copies) == set(SNIPPETS)
    # Also compare the runner's mapping; adding a bootstrap copy must update both.
    python = SCRIPT.read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY\n", 1)[0]
    mapping = next(node.value for node in ast.parse(python).body if isinstance(node, ast.Assign)
                   and any(isinstance(target, ast.Name) and target.id == "SNIPPETS"
                           for target in node.targets))
    assert ast.literal_eval(mapping) == SNIPPETS


@pytest.mark.parametrize("change", ["added", "removed", "renamed_source", "renamed_target", "duplicate"])
def test_snippets_mapping_drift_at_head_holds_all(fleet, change):
    paths = [fleet.install_snippet(i) for i in range(len(SNIPPETS))]
    before = [copy_state(path) for path in paths]
    seed = fleet.seeds["hermes-host-bootstrap"]
    module = seed / "lib/30-shell.sh"
    original = module.read_text()
    source, target = SNIPPETS[0]
    copy = 'cp "$REPO_ROOT/{}" "$HOME/{}"'.format(source, target)
    if change == "added":
        changed = original + '\ncp "$REPO_ROOT/dotfiles/new.sh" "$HOME/.hermes-host-bootstrap.new.sh"\n'
        (seed / "dotfiles/new.sh").write_text("# new dependency\n")
    elif change == "removed":
        changed = original.replace(copy, ":")
    elif change == "duplicate":
        changed = original + "\n" + copy + "\n"
    else:
        changed = original.replace(source if change == "renamed_source" else target,
                                   "dotfiles/renamed.sh" if change == "renamed_source" else ".renamed.sh")
    module.write_text(changed)
    for source, _ in SNIPPETS:
        (seed / source).write_text('. "$HOME/.hermes-host-bootstrap.new.sh"\n')
    fleet.git(seed, "add", ".")
    fleet.git(seed, "commit", "-m", "change bootstrap copy mapping")
    fleet.git(seed, "push")
    repo = fleet.repos["hermes-host-bootstrap"]
    if change != "added":
        fleet.git(repo, "pull", "--ff-only")
        # Only HEAD's mapping is authoritative, even if the worktree still looks old.
        (repo / "lib/30-shell.sh").write_text(original)
    row = fleet.row("shell-snippets")
    assert row["result"] == "held:mapping_changed"
    assert [copy_state(path) for path in paths] == before
    assert not (fleet.home / ".hermes-host-bootstrap.new.sh").exists()
    assert not list(fleet.home.glob("..hermes-host-bootstrap.*"))


@pytest.mark.parametrize("historical", [False, True])
def test_snippets_current_bootstrap_uses_head_despite_dirty_worktree(fleet, historical):
    path = fleet.install_snippet()
    before = copy_state(path)
    repo = fleet.repos["hermes-host-bootstrap"]
    source = SNIPPETS[0][0]
    if historical:
        fleet.advance("hermes-host-bootstrap", file=source)
        fleet.git(repo, "pull", "--ff-only")
    expected = (repo / source).read_bytes()
    (repo / source).write_bytes(b"private uncommitted source\n")
    # A dirty mapping must not hold an otherwise valid HEAD mapping either.
    with (repo / "lib/30-shell.sh").open("a") as stream:
        stream.write('\ncp "$REPO_ROOT/dotfiles/new.sh" "$HOME/.hermes-host-bootstrap.new.sh"\n')
    report = fleet.run()
    rows = {row["name"]: row for row in report["repos"]}
    assert rows["hermes-host-bootstrap"]["result"] == "current"
    assert rows["shell-snippets"]["result"] == ("refreshed 1" if historical else "current")
    assert path.read_bytes() == expected
    if not historical:
        assert copy_state(path) == before


def test_snippets_missing_bootstrap_row_skips(fleet):
    path = fleet.install_snippet()
    before = copy_state(path)
    text = fleet.script.read_text()
    original = '\n                       ("hermes-host-bootstrap", root),'
    assert original in text
    fleet.script.write_text(text.replace(original, ""))
    row = fleet.row("shell-snippets")
    assert row["result"] == "skipped:no_bootstrap_row"
    assert copy_state(path) == before


@pytest.mark.parametrize("descendant_bytes", [False, True])
def test_snippets_history_ignores_former_directory_children(fleet, descendant_bytes):
    path = fleet.install_snippet()
    seed = fleet.seeds["hermes-host-bootstrap"]
    source = SNIPPETS[0][0]
    fleet.git(seed, "rm", source)
    (seed / source).mkdir()
    (seed / source / "child").write_bytes(b"former directory child\n")
    fleet.git(seed, "add", ".")
    fleet.git(seed, "commit", "-m", "source becomes directory")
    fleet.git(seed, "rm", "-r", source)
    (seed / source).write_bytes(b"# latest source\n")
    fleet.git(seed, "add", ".")
    fleet.git(seed, "commit", "-m", "source becomes file again")
    fleet.git(seed, "push")
    if descendant_bytes:
        path.write_bytes(b"former directory child\n")
    before = copy_state(path)
    row = fleet.row("shell-snippets")
    assert row["result"] == ("held:local_edits" if descendant_bytes else "refreshed 1")
    if descendant_bytes:
        assert copy_state(path) == before
    else:
        assert path.read_bytes() == b"# latest source\n"


@pytest.mark.parametrize("change", ["delete", "rename", "untracked_recreation"])
def test_snippets_absent_head_source_holds_all_without_error(fleet, change):
    paths = [fleet.install_snippet(i) for i in range(len(SNIPPETS))]
    before = [copy_state(path) for path in paths]
    seed = fleet.seeds["hermes-host-bootstrap"]
    source = SNIPPETS[-1][0]
    if change == "rename":
        fleet.git(seed, "mv", source, "dotfiles/renamed.conf")
    else:
        fleet.git(seed, "rm", source)
    for other, _ in SNIPPETS[:-1]:
        (seed / other).write_text("# updated dependency\n")
    fleet.git(seed, "add", ".")
    fleet.git(seed, "commit", "-m", "retire source")
    fleet.git(seed, "push")
    if change == "untracked_recreation":
        repo = fleet.repos["hermes-host-bootstrap"]
        fleet.git(repo, "pull", "--ff-only")
        (repo / source).write_text("# recreated outside HEAD\n")
    row = fleet.row("shell-snippets")  # check=True asserts exit 0.
    assert row["result"] == row["files"][-1]["result"] == "held:source_absent"
    assert all(entry["result"] == "skipped:set_held" for entry in row["files"][:-1])
    assert [copy_state(path) for path in paths] == before


def test_snippets_find_bootstrap_by_name_after_row_reorder(fleet):
    path = fleet.install_snippet()
    fleet.advance("hermes-host-bootstrap", file=SNIPPETS[0][0])
    text = fleet.script.read_text()
    original = '\n                       ("hermes-host-bootstrap", root),'
    assert original in text
    text = text.replace(original, '')
    text = text.replace('[("hermes-config", home / ".hermes"),',
                        '[("hermes-host-bootstrap", root), ("hermes-config", home / ".hermes"),')
    fleet.script.write_text(text)
    # The row at the old bootstrap position is deliberately untrusted.
    fleet.git(fleet.repos["hermes-config"], "branch", "--unset-upstream")
    assert fleet.row("shell-snippets")["result"] == "refreshed 1"
    assert path.read_text() == "upstream\n"


@pytest.mark.parametrize("same_checkout", [False, True])
def test_snippets_use_bootstrap_row_path_only_for_same_checkout(fleet, same_checkout):
    path = fleet.install_snippet()
    before = copy_state(path)
    fleet.advance("hermes-host-bootstrap", file=SNIPPETS[0][0])
    alias = fleet.home / "bootstrap-alias"
    alias.symlink_to(fleet.repos["hermes-host-bootstrap"] if same_checkout
                     else fleet.repos["hermes-automation-wiki"])
    text = fleet.script.read_text()
    fleet.script.write_text(text.replace('    snippets = inspect_snippets(bootstrap)',
        '    bootstrap["path"] = str(home / "bootstrap-alias")\n    snippets = inspect_snippets(bootstrap)'))
    row = fleet.row("shell-snippets")
    calls = [ast.literal_eval(line) for line in fleet.calls.read_text().splitlines()]
    snippet_calls = [call for call in calls if any(arg in call for arg in
                     ("show", "ls-tree", "log", "hash-object", "--is-shallow-repository"))]
    if same_checkout:
        assert row["result"] == "refreshed 1" and path.read_text() == "upstream\n"
        assert snippet_calls and all(call[call.index("-C") + 1] == str(alias) for call in snippet_calls)
    else:
        assert row["result"] == "skipped:checkout_mismatch"
        assert all(entry["result"] == row["result"] for entry in row["files"])
        assert not snippet_calls
        assert copy_state(path) == before


@pytest.mark.parametrize("failure", ["unreadable", "foreign_owner", "foreign_group", "hardlinked", "read_error", "source_error", "stage_error"])
def test_snippets_one_unsafe_copy_or_error_blocks_entire_set(fleet, failure):
    paths = [fleet.install_snippet(i) for i in range(len(SNIPPETS))]
    problem = paths[-1]  # Last copy must block all earlier refreshable copies.
    if failure == "hardlinked":
        os.link(problem, fleet.home / "user-hardlink")
    before = [copy_state(path) for path in paths]
    for source, _ in SNIPPETS:
        fleet.advance("hermes-host-bootstrap", file=source)
    patch_snippet_python(fleet, '''import os, pathlib, subprocess, tempfile
path = pathlib.Path(os.environ["TEST_SNIPPET"])
failure = os.environ["TEST_FAILURE"]
original_open = os.open
def open_copy(name, flags, *args, **kwargs):
    if str(name) == str(path) and failure in ("unreadable", "read_error"):
        error = PermissionError if failure == "unreadable" else OSError
        raise error("private failure details")
    return original_open(name, flags, *args, **kwargs)
os.open = open_copy
original_fstat = os.fstat
def fstat(fd):
    info = original_fstat(fd)
    if failure in ("foreign_owner", "foreign_group") and info.st_ino == path.stat().st_ino:
        fields = list(info)
        index = 4 if failure == "foreign_owner" else 5
        fields[index] += 1
        return os.stat_result(fields)
    return info
os.fstat = fstat
original_run = subprocess.run
def run(args, *positional, **kwargs):
    if failure == "source_error" and "HEAD:" + os.environ["TEST_SOURCE"] in args:
        raise OSError("private source details")
    return original_run(args, *positional, **kwargs)
subprocess.run = run
original_temp = tempfile.mkstemp
def mkstemp(*args, **kwargs):
    if failure == "stage_error" and kwargs.get("prefix") == "." + path.name + ".":
        raise OSError("private staging details")
    return original_temp(*args, **kwargs)
tempfile.mkstemp = mkstemp
''', TEST_SNIPPET=problem, TEST_FAILURE=failure, TEST_SOURCE=SNIPPETS[-1][0])
    result = command(["bash", fleet.script], fleet.env, check=False)
    error = failure.endswith("error")
    assert result.returncode == (1 if error else 0)
    row = json.loads((fleet.state / "status.json").read_text())["repos"][-1]
    reason = "error" if error else "held:" + failure
    assert row["result"] == ("held:error" if error else reason)
    assert row["files"][-1]["result"] == reason
    assert all(entry["result"] == "skipped:set_held" for entry in row["files"][:-1])
    assert [copy_state(path) for path in paths] == before
    if failure == "hardlinked":
        assert (fleet.home / "user-hardlink").stat().st_ino == problem.stat().st_ino
    assert not list(fleet.home.glob("..hermes-host-bootstrap.*"))
    assert "private" not in result.stdout + result.stderr + (fleet.state / "log").read_text()


@pytest.mark.parametrize("kind", ["symlink", "fifo", "directory", "unreadable"])
@pytest.mark.parametrize("opening", [1, 2, 3])
def test_snippets_safe_open_even_when_path_changes(fleet, kind, opening):
    installed = fleet.install_snippet()
    other = fleet.install_snippet(4)
    other_before = copy_state(other)
    target = fleet.home / "private-target"
    target.write_bytes(b"private target data\n")
    for source, _ in (SNIPPETS[0], SNIPPETS[4]):
        fleet.advance("hermes-host-bootstrap", file=source)
    patch_snippet_python(fleet, '''import os, pathlib
path = pathlib.Path(os.environ["TEST_SNIPPET"])
kind = os.environ["TEST_KIND"]
original_open = os.open
count = 0
def open_copy(name, flags, *args, **kwargs):
    global count
    if str(name) == str(path):
        assert flags & os.O_NOFOLLOW and flags & os.O_NONBLOCK
        assert flags & os.O_ACCMODE == os.O_RDONLY
        count += 1
        if count == int(os.environ["TEST_OPENING"]):
            if kind == "unreadable":
                raise PermissionError("private access details")
            path.unlink()
            if kind == "symlink":
                path.symlink_to(os.environ["TEST_TARGET"])
            elif kind == "fifo":
                os.mkfifo(path)
            else:
                path.mkdir()
    return original_open(name, flags, *args, **kwargs)
os.open = open_copy
original_read = pathlib.Path.read_bytes
def read_bytes(self):
    assert str(self) not in (str(path), os.environ["TEST_TARGET"]), "unsafe pathname read"
    return original_read(self)
pathlib.Path.read_bytes = read_bytes
''', TEST_SNIPPET=installed, TEST_KIND=kind, TEST_OPENING=opening, TEST_TARGET=target)
    result = command(["bash", fleet.script], fleet.env)
    row = json.loads((fleet.state / "status.json").read_text())["repos"][-1]
    assert row["result"] == row["files"][0]["result"] == (
        "held:unreadable" if kind == "unreadable" else "held:not_regular")
    assert row["files"][4]["result"] == "skipped:set_held"
    assert copy_state(other) == other_before
    assert target.read_bytes() == b"private target data\n"
    assert "private" not in result.stdout + result.stderr + (fleet.state / "log").read_text()
    assert not list(fleet.home.glob("..hermes-host-bootstrap.*"))


@pytest.mark.parametrize("opening", [1, 3])
def test_snippets_path_swapped_after_open_keeps_new_inode(fleet, opening):
    path = fleet.install_snippet()
    other = fleet.install_snippet(4)
    other_before = copy_state(other)
    for source, _ in (SNIPPETS[0], SNIPPETS[4]):
        fleet.advance("hermes-host-bootstrap", file=source)
    patch_snippet_python(fleet, '''import os, pathlib
path = pathlib.Path(os.environ["TEST_SNIPPET"])
original = os.open
count = 0
def open_copy(name, flags, *args, **kwargs):
    global count
    fd = original(name, flags, *args, **kwargs)
    if str(name) == str(path):
        count += 1
        if count == int(os.environ["TEST_OPENING"]):
            replacement = path.with_name("user-replacement")
            replacement.write_bytes(b"private replacement\\n")
            os.replace(replacement, path)
    return fd
os.open = open_copy
''', TEST_SNIPPET=path, TEST_OPENING=opening)
    row = fleet.row("shell-snippets")
    assert row["result"] == row["files"][0]["result"] == "held:local_edits"
    assert row["files"][4]["result"] == "skipped:set_held"
    assert path.read_bytes() == b"private replacement\n"
    assert copy_state(other) == other_before


def test_snippets_removed_before_replace_stays_absent(fleet):
    path = fleet.install_snippet()
    other = fleet.install_snippet(4)
    before = copy_state(other)
    for source, _ in (SNIPPETS[0], SNIPPETS[4]):
        fleet.advance("hermes-host-bootstrap", file=source)
    patch_snippet_python(fleet, '''import os, pathlib
path = pathlib.Path(os.environ["TEST_SNIPPET"])
original = os.open
count = 0
def open_copy(name, flags, *args, **kwargs):
    global count
    if str(name) == str(path):
        count += 1
        if count == 3:
            path.unlink()
    return original(name, flags, *args, **kwargs)
os.open = open_copy
''', TEST_SNIPPET=path)
    row = fleet.row("shell-snippets")
    assert row["result"] == row["files"][0]["result"] == "held:local_edits"
    assert not path.exists()
    assert copy_state(other) == before


def test_snippets_error_exits_one_even_when_earlier_file_is_held(fleet):
    edited = fleet.install_snippet()
    edited.write_text("private local edit\n")
    other = fleet.install_snippet(6)
    before = [copy_state(path) for path in (edited, other)]
    patch_snippet_python(fleet, '''import os, subprocess
original = subprocess.run
def run(args, *positional, **kwargs):
    if "HEAD:" + os.environ["TEST_SOURCE"] in args:
        raise OSError("private source details")
    return original(args, *positional, **kwargs)
subprocess.run = run
''', TEST_SOURCE=SNIPPETS[-1][0])
    result = command(["bash", fleet.script], fleet.env, check=False)
    row = json.loads((fleet.state / "status.json").read_text())["repos"][-1]
    assert result.returncode == 1
    assert row["result"] == row["files"][0]["result"] == "held:local_edits"
    assert row["files"][-1]["result"] == "error"
    assert [copy_state(path) for path in (edited, other)] == before
    assert "private" not in result.stdout + result.stderr + (fleet.state / "log").read_text()


def test_snippets_current_copy_edited_during_staging_blocks_refresh(fleet):
    current = fleet.install_snippet(6)
    old = fleet.install_snippet()
    before = copy_state(old)
    fleet.advance("hermes-host-bootstrap", file=SNIPPETS[0][0])
    patch_snippet_python(fleet, '''import os, pathlib, tempfile
original = tempfile.mkstemp
def mkstemp(*args, **kwargs):
    result = original(*args, **kwargs)
    if kwargs.get("prefix", "").startswith("..hermes-host-bootstrap."):
        pathlib.Path(os.environ["TEST_CURRENT"]).write_bytes(b"private concurrent edit\\n")
    return result
tempfile.mkstemp = mkstemp
''', TEST_CURRENT=current)
    row = fleet.row("shell-snippets")
    assert row["result"] == row["files"][-1]["result"] == "held:local_edits"
    assert row["files"][0]["result"] == "skipped:set_held"
    assert copy_state(old) == before
    assert current.read_bytes() == b"private concurrent edit\n"


@pytest.mark.parametrize("depth,expected", [(1, "held:no_history"), (2, "refreshed 1")])
def test_snippets_shallow_history(fleet, depth, expected):
    path = fleet.install_snippet()
    before = copy_state(path)
    fleet.advance("hermes-host-bootstrap", file=SNIPPETS[0][0])
    repo = fleet.repos["hermes-host-bootstrap"]
    remote = fleet.tmp / "hermes-host-bootstrap.git"
    shutil.rmtree(repo)
    fleet.git(fleet.tmp, "clone", "--depth", str(depth), remote.as_uri(), str(repo))
    # depth=2 has the original bytes in retained history; make it shallow too.
    assert fleet.git(repo, "rev-parse", "--is-shallow-repository") == "true"
    row = fleet.row("shell-snippets")
    assert row["result"] == expected
    if depth == 1:
        assert row["files"][0]["result"] == expected
        assert copy_state(path) == before
    else:
        assert path.read_text() == "upstream\n"


def test_snippets_one_history_walk_for_all_seven_paths(fleet):
    paths = [fleet.install_snippet(i) for i in range(len(SNIPPETS))]
    for source, _ in SNIPPETS:
        fleet.advance("hermes-host-bootstrap", file=source)
    row = fleet.row("shell-snippets")
    assert row["result"] == "refreshed 7"
    assert all(entry["result"] == "refreshed" for entry in row["files"])
    assert all(path.read_text() == "upstream\n" for path in paths)
    calls = [ast.literal_eval(line) for line in fleet.calls.read_text().splitlines()]
    logs = [call for call in calls if "log" in call]
    assert len(logs) == 1
    assert logs[0][logs[0].index("--") + 1:] == [source for source, _ in SNIPPETS]


def test_snippets_dry_preview_is_explicitly_pre_merge(fleet):
    installed = fleet.install_snippet()
    fleet.advance("hermes-host-bootstrap", file=SNIPPETS[0][0])
    fleet.git(fleet.repos["hermes-host-bootstrap"], "fetch", "origin")
    before = snapshot(fleet.home)
    result = fleet.run("--dry-run")
    assert "would_update (+1)" in result.stdout
    assert "preview against the current (pre-merge) checkout" in result.stdout
    assert "shell-snippets: current\n" in result.stdout
    assert "would refresh" not in result.stdout
    assert snapshot(fleet.home) == before and installed.exists()
    assert not fleet.state.exists()


def test_snippets_first_hold_reason_in_mapping_order(fleet):
    edited = fleet.install_snippet()
    edited.write_text("private local edit\n")
    linked = fleet.home / SNIPPETS[-1][1]
    linked.symlink_to(edited)
    row = fleet.row("shell-snippets")
    assert row["result"] == row["files"][0]["result"] == "held:local_edits"
    assert row["files"][-1]["result"] == "held:not_regular"


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
    state = home / ".local/state/fleet-update-easy"
    assert Path(data["StandardOutPath"]).parent == state
    assert Path(data["StandardErrorPath"]).parent == state
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


@pytest.mark.parametrize("mode", ["release", "timeout", "unchanged"])
def test_module_mac_waits_for_updater_before_reload(module, mode):
    repo, home, env = module
    bootstrap(module)
    plist = home / "Library/LaunchAgents/com.hermes.fleet-update-easy.plist"
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
    with (home / ".local/state/fleet-update-easy/lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        with subprocess.Popen(["bash", str(repo / "bootstrap.sh"), "--only=M9-fleet-update-easy"],
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
        assert plistlib.loads(plist.read_bytes())["Label"] == "com.hermes.fleet-update-easy"
    else:
        assert "bootout" not in calls.read_text() and "bootstrap " not in calls.read_text()
        if mode == "timeout":
            assert "skipping reload" in stdout + stderr
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
    calls = Path(env["TEST_CALLS"])
    assert calls.read_text().splitlines() == [
        "daemon-reload", "enable --now hermes-fleet-update-easy.timer",
        "restart hermes-fleet-update-easy.timer"]
    before = snapshot(units)
    calls.write_text("")
    bootstrap(module, "--role=server")
    assert snapshot(units) == before and "daemon-reload" not in calls.read_text()
    assert calls.read_text().splitlines() == ["enable --now hermes-fleet-update-easy.timer"]
    timer.write_text("stale")
    calls.write_text("")
    bootstrap(module, "--role=server")
    assert snapshot(units) == before
    assert calls.read_text().splitlines() == [
        "daemon-reload", "enable --now hermes-fleet-update-easy.timer",
        "restart hermes-fleet-update-easy.timer"]
    if shutil.which("systemd-analyze"):
        command(["systemd-analyze", "verify", service, timer], env)


@pytest.mark.parametrize("host", ["h-btp", "h-af"])
@pytest.mark.parametrize("marked", [False, True])
def test_module_preserved_hosts_need_marker(module, host, marked):
    _, home, env = module
    env.update(TEST_OS="Linux", HERMES_HOSTNAME=host)
    if marked:
        marker = home / ".config/fleet-update/preserve-hermes-config"
        marker.parent.mkdir(parents=True)
        marker.touch()
    bootstrap(module, "--role=server")
    installed = (Path(env["HERMES_SYSTEMD_DIR"]) / "hermes-fleet-update-easy.timer").exists()
    assert installed == marked
