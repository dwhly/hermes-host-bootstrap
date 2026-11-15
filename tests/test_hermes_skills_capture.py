#!/usr/bin/env python3
"""tests/test_hermes_skills_capture.py — scripts/hermes-skills-capture against local bare repos (no network).

Covers the Codex r1 counterexamples: source immutability and overlap, scanner bypasses (binary, >4 MB prefix,
path names, symlink targets, URL userinfo, Basic auth, literal assignments), pushInsteadOf redirection, hub and
same-bytes bundled exclusion, ignore rules, mtime-preserving edits, failed first push retried, stale state rebuilt,
redacted status, a writer racing between fetch and push, and the alert command.
"""
import importlib.machinery, importlib.util, json, os, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
SCRIPT = HERE / "scripts" / "hermes-skills-capture"
loader = importlib.machinery.SourceFileLoader("hsc", str(SCRIPT))
spec = importlib.util.spec_from_loader("hsc", loader)
hsc = importlib.util.module_from_spec(spec)
loader.exec_module(hsc)
TOK = "ghp_" + "A" * 36


def sh(*args, cwd=None, check=True, env=None):
    return subprocess.run(list(args), cwd=cwd, check=check, capture_output=True, text=True, env=env)


class Capture(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.t, True)
        gcfg = self.t / "gitconfig"
        gcfg.write_text("[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n")
        self.env_patch = {"GIT_CONFIG_GLOBAL": str(gcfg), "GIT_CONFIG_NOSYSTEM": "1"}
        self.old_env = {k: os.environ.get(k) for k in self.env_patch}
        os.environ.update(self.env_patch)
        self.addCleanup(self.restore_env)
        self.remote = self.t / "remote.git"
        sh("git", "init", "-q", "--bare", "-b", "main", str(self.remote))
        self.src = self.t / "skills"
        (self.src / "alpha" / "references").mkdir(parents=True)
        (self.src / "alpha" / "SKILL.md").write_text("---\nname: alpha\n---\nUse op://Vault/item/field for the key.\n"
                                                     "api_key: ${API_KEY}\npassword = os.environ['PW']\n")
        (self.src / "alpha" / "references" / "r.md").write_text("ref\n")
        (self.src / "beta" / "__pycache__").mkdir(parents=True)
        (self.src / "beta" / "__pycache__" / "x.pyc").write_bytes(b"junk")
        (self.src / "beta" / ".env").write_text("TOKEN=abc\n")
        (self.src / "beta" / "SKILL.md").write_text("beta\n")
        (self.src / ".curator_backups").mkdir()
        (self.src / ".curator_backups" / "b").write_text("old\n")
        (self.src / ".usage.json").write_text("{}\n")
        (self.src / ".bundled_manifest").write_text("x:y\n")
        self.state = self.t / "state"

    def restore_env(self):
        for k, v in self.old_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def run_cap(self, *extra, repo=None, state=None, skills=None):
        args = ["--skills", str(skills or self.src), "--repo", str(repo or self.remote), "--state",
                str(state or self.state), "--host", "testhost", *extra]
        return hsc.main(args)

    def status(self, state=None):
        return json.loads(((state or self.state) / "status.json").read_text())

    def files(self):
        p = sh("git", "--git-dir", str(self.remote), "ls-tree", "-r", "--name-only", "main", check=False)
        return set(p.stdout.split())

    def tip(self):
        p = sh("git", "--git-dir", str(self.remote), "rev-parse", "-q", "--verify", "main", check=False)
        return p.stdout.strip() or None

    def snapshot(self):
        return {p.relative_to(self.src).as_posix(): (p.read_bytes() if p.is_file() and not p.is_symlink() else None)
                for p in sorted(self.src.rglob("*"))}

    # ── basics ──
    def test_dry_run_pushes_nothing(self):
        self.assertEqual(self.run_cap("--dry-run"), 0)
        self.assertEqual(self.status()["result"], "dry-run")
        self.assertIsNone(self.tip())

    def test_first_capture_and_exclusions(self):
        self.assertEqual(self.run_cap(), 0)
        f = self.files()
        self.assertEqual(self.status()["result"], "pushed")
        self.assertIn("skills/alpha/SKILL.md", f)
        self.assertIn("skills/alpha/references/r.md", f)
        self.assertIn("skills/.bundled_manifest", f)
        for bad in ("skills/beta/.env", "skills/beta/__pycache__/x.pyc", "skills/.curator_backups/b", "skills/.usage.json"):
            self.assertNotIn(bad, f)
        author = sh("git", "--git-dir", str(self.remote), "log", "-1", "--format=%an", "main").stdout.strip()
        self.assertEqual(author, "Hermes skills capture (testhost)")

    def test_unchanged_makes_no_commit(self):
        self.run_cap()
        tip = self.tip()
        self.assertEqual(self.run_cap(), 0)
        self.assertEqual((self.status()["result"], self.tip()), ("unchanged", tip))

    def test_edit_and_delete(self):
        self.run_cap()
        with open(self.src / "alpha" / "SKILL.md", "a") as f:
            f.write("more\n")
        shutil.rmtree(self.src / "beta")
        self.run_cap()
        self.assertEqual(self.status()["changed_paths"], 2)
        self.assertFalse(any("beta" in x for x in self.files()))

    def test_same_size_edit_with_restored_mtime(self):
        p = self.src / "alpha" / "note.txt"
        p.write_text("old\n")
        self.run_cap()
        st = p.stat()
        p.write_text("new\n")
        os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))
        self.run_cap()
        self.assertEqual(self.status()["result"], "pushed")
        self.assertEqual(sh("git", "--git-dir", str(self.remote), "show", "main:skills/alpha/note.txt").stdout, "new\n")

    def test_source_is_never_modified(self):
        before = self.snapshot()
        self.run_cap()
        (self.src / "alpha" / "leak.md").write_text(TOK)
        self.run_cap()
        (self.src / "alpha" / "leak.md").unlink()
        self.run_cap()
        self.assertEqual(self.snapshot(), before)

    # ── overlap and redirection ──
    def test_overlapping_state_is_refused_before_any_write(self):
        before = self.snapshot()
        outer = self.t / "s2"
        (outer / "work").mkdir(parents=True)
        (outer / "work" / "x").write_text("keep me\n")
        cases = ((self.src / "inner", self.src), (self.src, self.src), (outer, outer / "work"),
                 (self.src / "alpha", self.src))
        for st, sk in cases:
            self.assertEqual(self.run_cap(state=st, skills=sk), 2, (st, sk))
        self.assertEqual(self.snapshot(), before)                    # nothing created, nothing deleted
        self.assertFalse((self.src / "inner").exists())
        self.assertEqual((outer / "work" / "x").read_text(), "keep me\n")
        self.assertEqual(sorted(p.name for p in outer.iterdir()), ["work"])
        link = self.t / "alias"
        os.symlink(self.src, link)
        self.assertEqual(self.run_cap(state=link / "st"), 2)          # a symlink alias is resolved first
        self.assertEqual(self.snapshot(), before)

    def test_push_rewrite_is_refused(self):
        other = self.t / "other.git"
        sh("git", "init", "-q", "--bare", "-b", "main", str(other))
        sh("git", "config", "--global", f"url.{other}.pushInsteadOf", str(self.remote))
        self.assertEqual(self.run_cap(), 1)
        self.assertIn("rewrite", self.status()["error"])
        self.assertIsNone(self.tip())
        self.assertIsNone(sh("git", "--git-dir", str(other), "rev-parse", "-q", "--verify", "main",
                             check=False).stdout.strip() or None)

    # ── scanner ──
    def assert_blocked(self, rel, data):
        self.run_cap()
        tip = self.tip()
        p = self.src / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        rc = self.run_cap()
        st = self.status()
        self.assertEqual((rc, st["result"]), (3, "blocked-secret"), rel)
        self.assertEqual(self.tip(), tip)
        hits = (self.state / "scan-hits.txt").read_text()
        self.assertNotIn(TOK, json.dumps(st) + hits)
        self.assertNotIn("hunter2hunter2", json.dumps(st) + hits)
        p.unlink()
        self.assertEqual(self.run_cap(), 0)
        self.assertFalse((self.state / "scan-hits.txt").exists())

    def test_token_in_text(self):
        self.assert_blocked("alpha/leak.md", f"token: {TOK}\n".encode())

    def test_token_in_binary(self):
        self.assert_blocked("alpha/leak.bin", b"\0" + TOK.encode())

    def test_token_after_4mb(self):
        self.assert_blocked("alpha/big.txt", b"x" * 4194304 + b"\n" + TOK.encode())

    def test_token_in_path(self):
        self.assert_blocked(f"alpha/{TOK}.md", b"harmless\n")

    def test_url_userinfo(self):
        self.assert_blocked("alpha/cfg.txt", b"DATABASE_URL=postgresql://app:hunter2hunter2@db.internal/prod\n")

    def test_basic_auth_header(self):
        self.assert_blocked("alpha/curl.md", b"curl -H 'Authorization: Basic dXNlcjpodW50ZXIyaHVudGVyMg=='\n")

    def test_literal_assignment(self):
        self.assert_blocked("alpha/conf.yaml", b"client_secret: hunter2hunter2xyz\n")

    def test_literal_assignment_with_digits_in_words(self):
        self.assert_blocked("alpha/conf2.yaml", b"api_key = 'hunter2hunter2-prod-9f8e7d'\n")

    def test_placeholders_do_not_block(self):
        (self.src / "alpha" / "doc.md").write_text(
            "password: <your password here>\napi_key = getenv('K')\nsecret: ${{ secrets.X }}\nuse op://Fleet/x/password\n"
            "export COMFY_API_KEY=\"comfyui-xxxxxxxxxxxx\"\nENV_KEY = \"COMFY_CLOUD_API_KEY\"\n"
            "def f(self, api_key: Optional[str] = None):\nsecret: \"generate-a-long-random-string\"\n"
            "sed 's|https://[^:]*:\\([^@]*\\)@.*|\\1|'\n"
            "set `ANTHROPIC_AUTH_TOKEN=<OPENROUTER_API_KEY` first\n    api_key = os.environ.get('K')\n")
        self.assertEqual(self.run_cap(), 0)
        self.assertEqual(self.status()["result"], "pushed")

    def test_symlink_never_exported(self):
        os.symlink(TOK, self.src / "alpha" / "link")
        os.symlink("/etc", self.src / "alpha" / "dirlink")
        self.assertEqual(self.run_cap(), 0)
        st = self.status()
        self.assertEqual(sorted(st["skipped_links"]), ["alpha/dirlink", "alpha/link"])
        self.assertFalse(any("link" in x for x in self.files()))
        log = sh("git", "--git-dir", str(self.remote), "log", "-p", "main").stdout
        self.assertNotIn(TOK, log)

    def test_non_regular_file_blocks(self):
        os.mkfifo(self.src / "alpha" / "pipe")
        self.assertEqual(self.run_cap(), 3)
        self.assertEqual(self.status()["result"], "blocked-unreadable")
        self.assertIsNone(self.tip())

    def test_oversize_blocks(self):
        (self.src / "alpha" / "huge.bin").write_bytes(b"0" * (2 * 1024 * 1024))
        self.assertEqual(self.run_cap("--max-file-mb", "1"), 3)
        self.assertIn("over 1 MB", self.status()["error"])

    # ── bundled / hub classification: never under-capture ──
    def bundled_pair(self, name, files):
        b = self.t / "bundled" / "cat" / name
        s = self.src / "cat" / name
        for d in (b, s):
            d.mkdir(parents=True, exist_ok=True)
            for rel, data in files.items():
                (d / rel).write_bytes(data)
        return b, s

    def test_bundled_identical_excluded_edits_captured(self):
        self.bundled_pair("same", {"SKILL.md": b"---\nname: same\n---\n"})
        _, s = self.bundled_pair("edited", {"SKILL.md": b"---\nname: edited\n---\n"})
        (s / "SKILL.md").write_bytes(b"---\nname: edited\n---\nnode edit\n")
        b, s = self.bundled_pair("split", {"SKILL.md": b"m", "a": b"bc"})
        (s / "a").unlink(); (s / "ab").write_bytes(b"c")          # same md5 stream, different package
        b, s = self.bundled_pair("mode", {"SKILL.md": b"m", "run.sh": b"echo\n"})
        os.chmod(s / "run.sh", 0o755)
        self.assertEqual(self.run_cap("--bundled", str(self.t / "bundled")), 0)
        f = self.files()
        self.assertFalse(any("cat/same/" in x for x in f))
        for kept in ("skills/cat/edited/SKILL.md", "skills/cat/split/ab", "skills/cat/mode/run.sh"):
            self.assertIn(kept, f)
        self.assertEqual(self.status()["excluded_bundled"], 1)
        mode = sh("git", "--git-dir", str(self.remote), "ls-tree", "main", "skills/cat/mode/run.sh").stdout.split()[0]
        self.assertEqual(mode, "100755")

    def test_hub_installs_are_captured(self):
        (self.src / ".hub").mkdir()
        (self.src / ".hub" / "lock.json").write_text('{"installed":{"x":{"install_path":"*"},'
                                                     '"h":{"install_path":"cat/hubbed"}}}')
        (self.src / "cat" / "hubbed").mkdir(parents=True)
        (self.src / "cat" / "hubbed" / "SKILL.md").write_text("company customization\n")
        self.run_cap()
        f = self.files()
        self.assertIn("skills/cat/hubbed/SKILL.md", f)
        self.assertIn("skills/alpha/SKILL.md", f)
        self.assertIn("skills/.hub/lock.json", f)

    def test_gitignore_cannot_hide_files(self):
        (self.src / ".gitignore").write_text("alpha/\n*.md\n")
        self.run_cap()
        self.assertIn("skills/alpha/SKILL.md", self.files())

    # ── git failure handling ──
    def test_failed_first_push_is_retried(self):
        hook = self.remote / "hooks" / "pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n"); os.chmod(hook, 0o755)
        self.assertEqual(self.run_cap(), 1)
        self.assertEqual(self.status()["result"], "error")
        hook.unlink()
        self.assertEqual(self.run_cap(), 0)
        self.assertEqual(self.status()["result"], "pushed")
        self.assertIn("skills/alpha/SKILL.md", self.files())

    def test_stale_state_is_rebuilt(self):
        self.run_cap()
        work = self.state / "work"
        (work / ".git" / "index.lock").write_text("")
        (work / "skills" / "alpha" / "SKILL.md").write_text("dirty\n")
        self.assertEqual(self.run_cap(), 0)
        self.assertEqual(self.status()["result"], "unchanged")
        shutil.rmtree(work); work.mkdir(); (work / "junk").write_text("x")
        self.assertEqual(self.run_cap(), 0)
        self.assertEqual(self.status()["result"], "unchanged")

    def test_status_is_redacted(self):
        url = f"https://x-access-token:{TOK}@127.0.0.1:9/none.git"
        self.assertEqual(self.run_cap(repo=url), 1)
        raw = (self.state / "status.json").read_text()
        self.assertNotIn(TOK, raw)
        self.assertIn("***@", raw)

    def test_writer_racing_between_fetch_and_push(self):
        self.run_cap()
        other = self.t / "writer"
        sh("git", "clone", "-q", str(self.remote), str(other))
        real_git = hsc.git

        def racing(work, *args, check=True):
            if args and args[0] == "push":
                (other / "README.md").write_text("writer\n")
                sh("git", "add", "README.md", cwd=other); sh("git", "commit", "-qm", "w", cwd=other)
                sh("git", "push", "-q", "origin", "main", cwd=other)
                hsc.git = real_git
            return real_git(work, *args, check=check)
        hsc.git = racing
        self.addCleanup(setattr, hsc, "git", real_git)
        with open(self.src / "alpha" / "SKILL.md", "a") as f:
            f.write("racing edit\n")
        self.assertEqual(self.run_cap(), 1)
        writer_tip = sh("git", "rev-parse", "HEAD", cwd=other).stdout.strip()
        self.assertEqual(self.tip(), writer_tip)                     # rejected, never forced
        self.assertEqual(self.run_cap(), 0)                          # next run lands on top of the writer
        self.assertIn("skills/alpha/SKILL.md", self.files()); self.assertIn("README.md", self.files())
        self.assertIn("racing edit", sh("git", "--git-dir", str(self.remote), "show", "main:skills/alpha/SKILL.md").stdout)

    # ── alerts ──
    def test_alert_on_push_and_failure(self):
        out = self.t / "alerts.txt"
        cmd = f"sh -c 'cat >> {out}; echo >> {out}'"
        self.run_cap("--alert-cmd", cmd)
        self.assertIn("Skills capture (testhost): ", out.read_text())
        self.run_cap("--alert-cmd", cmd)                              # unchanged: no alert
        self.assertEqual(out.read_text().count("Skills capture"), 1)
        (self.src / "alpha" / "leak.md").write_text(TOK)
        self.run_cap("--alert-cmd", cmd)
        text = out.read_text()
        self.assertIn("FAILED, nothing pushed: blocked-secret", text)
        self.assertNotIn(TOK, text)

    def test_failed_alert_is_recorded_not_fatal(self):
        self.assertEqual(self.run_cap("--alert-cmd", "false"), 0)
        st = self.status()
        self.assertEqual(st["result"], "pushed")
        self.assertTrue(st["alert_error"])

    # ── r2 review counterexamples ──
    def test_conditional_include_rewrite_is_refused(self):
        other = self.t / "other.git"
        sh("git", "init", "-q", "--bare", "-b", "main", str(other))
        inc = self.t / "inc.cfg"
        inc.write_text(f'[url "{other}"]\n\tpushInsteadOf = {self.remote}\n')
        with open(os.environ["GIT_CONFIG_GLOBAL"], "a") as f:
            f.write(f'[includeIf "gitdir:{self.state.resolve()}/work/"]\n\tpath = {inc}\n')
        self.state.mkdir()
        self.assertEqual(self.run_cap(), 1)
        self.assertIn("rewrite", self.status()["error"])
        self.assertIsNone(self.tip())
        self.assertEqual(sh("git", "--git-dir", str(other), "rev-parse", "-q", "--verify", "main", check=False).stdout, "")

    def test_working_tree_encoding_cannot_smuggle_a_token(self):
        (self.src / ".gitattributes").write_text("*.txt working-tree-encoding=UTF-16LE\n")
        (self.src / "alpha" / "enc.txt").write_bytes(("token: " + TOK + "\n").encode("utf-16-le"))
        self.assertEqual(self.run_cap(), 3)
        self.assertEqual(self.status()["result"], "blocked-secret")
        self.assertIsNone(self.tip())
        self.assertIn("enc.txt", (self.state / "scan-hits.txt").read_text())

    def test_planted_state_symlinks_never_touch_the_source(self):
        before = self.snapshot()
        target = self.src / "alpha" / "SKILL.md"
        for name in (".lock", "status.json", "status.json.tmp", "scan-hits.txt", "scan-hits.txt.tmp"):
            with self.subTest(alias=name):
                shutil.rmtree(self.state, ignore_errors=True)
                self.state.mkdir()
                os.symlink(target, self.state / name)
                (self.src / "alpha" / "leak.md").write_text(TOK)     # reaches scanning and the hits report
                rc = self.run_cap()
                (self.src / "alpha" / "leak.md").unlink()
                self.assertEqual(self.snapshot(), before)
                if name == ".lock":
                    self.assertEqual(rc, 1)                          # refuses to follow the planted lock
                else:
                    self.assertEqual(rc, 3)
                    self.assertFalse((self.state / "status.json").is_symlink())
                    self.assertEqual(self.status()["result"], "blocked-secret")
                    self.assertFalse((self.state / "scan-hits.txt").is_symlink())

    def test_unicode_path_token_is_redacted(self):
        self.assert_blocked(f"alpha/é{TOK}.md", b"x\n")

    def test_empty_prefix_rewrite_is_refused(self):
        sh("git", "config", "--global", "url.https://other.invalid/.insteadOf", "")
        self.assertEqual(self.run_cap(), 1)
        self.assertIn("rewrite", self.status()["error"])

    def test_setup_failure_still_alerts(self):
        out = self.t / "alerts.txt"
        blocker = self.t / "file"
        blocker.write_text("x")
        rc = self.run_cap("--alert-cmd", f"sh -c 'cat >> {out}'", state=blocker / "state")
        self.assertEqual(rc, 1)
        self.assertIn("setup failed", out.read_text())

    def test_large_inventory_streams(self):
        big = self.src / "big"
        big.mkdir()
        for i in range(6):
            (big / f"f{i}.bin").write_bytes(os.urandom(3 * 1024 * 1024))
        self.assertEqual(self.run_cap(), 0)
        self.assertEqual(self.status()["result"], "pushed")

    def test_digit_secrets_are_not_placeholders(self):
        for i, line in enumerate((b'password="R4nd0m$Value9876"\n', b'password="Q7V9M2K8N4R6P3T5"\n',
                                  b"url: postgresql://app:Q7V9M2K8N4R6P3T5@db.internal/x\n",
                                  b'password="$9x7K4m2P8z6Q1r3T"\n', b'password="R4nd0m(Valu3_9876"\n',
                                  b"url: postgresql://app:$9x7K4m2P8z6Q1r3T@db/x\n")):
            with self.subTest(line=line):
                self.assert_blocked(f"alpha/s{i}.md", line)

    def test_assignment_in_a_filename_is_redacted(self):
        self.assert_blocked("alpha/password=hunter2hunter2xyz.md", b"x\n")

    def test_link_named_like_a_token_is_redacted(self):
        os.symlink("/etc/hostname", self.src / "alpha" / TOK)
        self.assertEqual(self.run_cap(), 0)
        raw = (self.state / "status.json").read_text()
        self.assertNotIn(TOK, raw)
        self.assertEqual(len(self.status()["skipped_links"]), 1)

    def test_missing_skills_dir_reports_and_alerts(self):
        out = self.t / "alerts.txt"
        rc = self.run_cap("--alert-cmd", f"sh -c 'cat >> {out}'", skills=self.t / "nope")
        self.assertEqual(rc, 1)
        self.assertIn("skills dir not found", self.status()["error"])
        self.assertIn("FAILED", out.read_text())

    def test_pull_mirrors_then_captures_and_reports_pull_failure(self):
        mirror = self.t / "mirror" / "skills"
        self.assertEqual(self.run_cap("--pull", str(self.src), skills=mirror), 0)
        self.assertIn("skills/alpha/SKILL.md", self.files())
        out = self.t / "alerts.txt"
        rc = self.run_cap("--pull", str(self.t / "no-such-src"), "--alert-cmd", f"sh -c 'cat >> {out}'", skills=mirror)
        self.assertEqual(rc, 1)
        self.assertIn("pull from", self.status()["error"])
        self.assertIn("FAILED", out.read_text())

    def test_empty_inventory_is_a_no_op_and_full_deletion_is_captured(self):
        empty = self.t / "empty"
        (empty / "x").mkdir(parents=True)
        (empty / "x" / ".env").write_text("only excluded\n")
        self.assertEqual(self.run_cap(skills=empty), 0)
        self.assertEqual(self.status()["result"], "unchanged")
        self.assertEqual(self.run_cap(), 0)
        self.assertTrue(self.files())
        self.assertEqual(self.run_cap(skills=empty), 0)
        self.assertEqual((self.status()["result"], self.files()), ("pushed", set()))


if __name__ == "__main__":
    unittest.main()
