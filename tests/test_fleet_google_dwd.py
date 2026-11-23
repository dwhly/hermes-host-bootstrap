"""Tests for fleet-google-dwd (shared Google DWD connector). No network, no real key: a fake `op` on PATH serves a
throwaway RSA service-account key, and a fake token endpoint (the module's _urlopen hook) verifies each JWT with
the matching public key.

Run: uv run -q --no-project --with pytest --with pyyaml --with cryptography --python 3.12 \
       python -m pytest -q -p no:cacheprovider tests/test_fleet_google_dwd.py
Set REQUIRE_FLEET_GOOGLE_DWD_TESTS=1 to turn a missing dependency into a failure instead of a skip.
"""
from __future__ import annotations

import ast
import base64
import importlib
import importlib.machinery
import importlib.util
import inspect
import io
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
import time
import urllib.error
from pathlib import Path

import pytest

if os.environ.get("REQUIRE_FLEET_GOOGLE_DWD_TESTS") == "1":
    import cryptography  # noqa: F401
    import yaml
else:
    pytest.importorskip("cryptography")
    yaml = pytest.importorskip("yaml")

from cryptography.hazmat.primitives import hashes, serialization  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import padding, rsa  # noqa: E402

REPO = Path(__file__).resolve().parents[1]
PKG = REPO / "fleet-google-dwd"
FIX = REPO / "tests" / "fixtures" / "fleet-google-dwd"
CFG_SRC = REPO / "config" / "fleet-google-dwd"
TOKEN_URI = "https://oauth2.googleapis.com/token"
GMAIL = "https://mail.google.com/"
CAL = "https://www.googleapis.com/auth/calendar"
DRIVE = "https://www.googleapis.com/auth/drive"
OP_TOKEN = "ops_FAKE-test-token-7c1d"   # fictional; must never appear anywhere but its own file
ME = pwd.getpwuid(os.geteuid()).pw_name


def _b64d(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


class FakeGoogle:
    """The module's _urlopen hook: a token endpoint that verifies the RS256 assertion, plus tiny API stubs."""

    def __init__(self, pub):
        self.pub = pub
        self.mints = []          # decoded claims per successful mint
        self.requests = []       # (method, url, auth header)
        self.token_error = None  # (status, body) to return from the token endpoint
        self.api_status = {}     # url-prefix -> status
        self.drive_email = "dwhaley@btpautomation.com"
        self.n = 0

    def _resp(self, obj):
        return io.BytesIO(json.dumps(obj).encode())

    def __call__(self, req, data=None, timeout=None):
        if isinstance(req, str):
            assert req == TOKEN_URI, req
            form = dict(x.split("=", 1) for x in data.decode().split("&"))
            assert form["grant_type"] == "urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer"
            h, c, s = form["assertion"].split(".")
            self.pub.verify(_b64d(s), f"{h}.{c}".encode(), padding.PKCS1v15(), hashes.SHA256())
            claims = json.loads(_b64d(c))
            if self.token_error:
                st, body = self.token_error
                raise urllib.error.HTTPError(TOKEN_URI, st, "err", {}, io.BytesIO(json.dumps(body).encode()))
            self.mints.append(claims)
            self.n += 1
            return self._resp({"access_token": f"ya29.fake-{self.n}", "expires_in": 3600})
        url = req.full_url
        self.requests.append((req.get_method(), url, req.headers.get("Authorization")))
        for pre, st in self.api_status.items():
            if url.startswith(pre):
                raise urllib.error.HTTPError(url, st, "err", {}, io.BytesIO(b'{"error":{"message":"secret-body"}}'))
        if url.endswith("/labels"):
            return self._resp({"labels": [{"id": "INBOX"}, {"id": "SENT"}, {"id": "L1"}]})
        if "calendarList" in url:
            return self._resp({"items": [{"id": "a"}, {"id": "b"}]})
        if "drive/v3/about" in url:
            return self._resp({"user": {"emailAddress": self.drive_email}})
        if url.endswith("/drafts") and req.get_method() == "POST":
            return self._resp({"id": "r123", "message": {"id": "m123"}})
        if "/drafts/" in url:
            return self._resp({"id": "r123", "message": {"id": "m123"}})
        if url.endswith("/trash"):
            return self._resp({"id": "m123", "labelIds": ["TRASH"]})
        return self._resp({})


@pytest.fixture
def env(tmp_path, monkeypatch):
    """A throwaway host: config dir, run_as home with fake-op fixture, fake op on PATH, fresh module."""
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption()).decode()
    sa = {"type": "service_account", "project_id": "test", "private_key_id": "kid-test-1234",
          "private_key": pem, "client_email": "hermes-dwd@test.iam.gserviceaccount.com",
          "client_id": "123456789012345678901", "token_uri": TOKEN_URI}
    home = tmp_path / "home"
    fop = home / "fake-op"
    fop.mkdir(parents=True)
    (fop / "key.json").write_text(json.dumps(sa))
    (fop / "expected-token").write_text(OP_TOKEN)
    bindir = tmp_path / "bin"
    bindir.mkdir()
    shutil.copy(FIX / "fake-op", bindir / "op")
    os.chmod(bindir / "op", 0o755)
    monkeypatch.setenv("PATH", f"{bindir}:/usr/bin:/bin")
    monkeypatch.delenv("HERMES_SESSION_ID", raising=False)
    hooks = tmp_path / "hooks"
    hooks.mkdir()
    shutil.copy(FIX / "hooks" / "af_policy.py", hooks / "af_policy.py")
    cfgdir = tmp_path / "etc"
    cfgdir.mkdir(mode=0o755)
    os.chmod(cfgdir, 0o755)
    for m in ("fleet_google_dwd", "dwd", "af_policy"):
        sys.modules.pop(m, None)
    monkeypatch.syspath_prepend(str(PKG))
    mod = importlib.import_module("fleet_google_dwd")
    monkeypatch.setattr(mod, "CONFIG_DIR", cfgdir)
    monkeypatch.setattr(mod, "TRUSTED_CONFIG_UIDS", frozenset({0, os.geteuid()}))
    fake = FakeGoogle(key.public_key())
    monkeypatch.setattr(mod, "_urlopen", fake)

    class E:
        pass
    e = E()
    e.mod, e.fake, e.tmp, e.home, e.fop, e.cfgdir, e.hooks, e.sa, e.pem = mod, fake, tmp_path, home, fop, cfgdir, hooks, sa, pem

    def write_cfg(company, /, **over):
        c = yaml.safe_load((CFG_SRC / "companies" / f"{company}.yaml").read_text())
        state = tmp_path / "state" / company
        c["run_as"] = {"user": ME, "home": str(home)}
        c["op_token_file"] = str(tmp_path / "secret" / company / "op_sa_token")
        c["audit_log"] = str(state / "dwd_audit.log")
        c["draft_ledger"] = str(state / "state" / "draft_ledger.jsonl")
        if "policy" in c:
            c["policy"]["hooks_dir"] = str(hooks)
        for k, v in over.items():
            if v is None:
                c.pop(k, None)
            else:
                c[k] = v
        p = cfgdir / f"{company}.yaml"
        p.write_text(yaml.safe_dump(c))
        os.chmod(p, 0o644)
        tf = Path(c["op_token_file"])
        tf.parent.mkdir(parents=True, exist_ok=True)
        if not tf.exists():
            tf.write_text(OP_TOKEN + "\n")
            os.chmod(tf, 0o600)
        (fop / "item").write_text(str(c.get("op_item")))
        (fop / "vault").write_text(str(c.get("op_vault")))
        return c
    e.write_cfg = write_cfg
    e.op_calls = lambda: (fop / "calls.log").read_text().splitlines() if (fop / "calls.log").exists() else []
    e.audit = lambda company="btp": [json.loads(x) for x in
                                     (tmp_path / "state" / company / "dwd_audit.log").read_text().splitlines()]
    yield e
    for m in ("fleet_google_dwd", "dwd", "af_policy"):
        sys.modules.pop(m, None)


# ---------------- configs in the repo ----------------
def test_repo_btp_config_is_exactly_the_brief():
    c = yaml.safe_load((CFG_SRC / "companies" / "btp.yaml").read_text())
    assert c["allowed_subjects"] == ["dwhaley@btpautomation.com"]
    assert c["smoke_subject"] == "dwhaley@btpautomation.com"
    assert c["op_vault"] == "BTP Automation Agent" and c["op_item"] == "Google Service Account BTP"
    assert c["op_token_file"] == "/home/hermes/.config/btp/op_sa_token"
    assert c["audit_log"] == "/home/hermes/.hermes/google-workspace/dwd_audit.log"
    assert c["run_as"] == {"user": "hermes", "home": "/home/hermes"}
    assert not c["allowed_domains"] and not c["docs_only_subjects"] and "policy" not in c
    assert c["scopes"] == {"gmail": GMAIL, "calendar": CAL, "drive": DRIVE}


def test_repo_host_files_are_held():
    for h in ("h-btp", "h-af"):
        t = (CFG_SRC / "hosts" / f"{h}.env").read_text()
        assert "ROLLOUT=hold" in t.splitlines() and "ROLLOUT=go" not in t.splitlines()


def test_btp_config_loads(env):
    env.write_cfg("btp")
    assert env.mod.configure("btp") == "btp"
    assert env.mod.ALLOWED_SUBJECTS == {"dwhaley@btpautomation.com"}
    assert env.mod.ALLOWED_DOMAINS == set() and env.mod.SYSTEM_READ_SUBJECTS == set()


def test_host_company_default(env):
    env.write_cfg("btp")
    p = env.cfgdir / "host-company"
    p.write_text("btp\n")
    os.chmod(p, 0o644)
    assert env.mod.configure() == "btp"


# ---------------- AmForge shim parity ----------------
def _fixture_constants():
    tree = ast.parse((FIX / "af_dwd_py_20261123.py.txt").read_text())
    out, funcs = {}, {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            name = node.targets[0].id
            v = node.value
            if isinstance(v, ast.Call) and getattr(v.func, "id", "") == "Path":
                out[name] = Path(ast.literal_eval(v.args[0]))
            else:
                try:
                    out[name] = ast.literal_eval(v)
                except ValueError:
                    pass
        elif isinstance(node, ast.FunctionDef):
            a = node.args
            funcs[node.name] = ([x.arg for x in a.args], [x.arg for x in a.kwonlyargs])
        elif isinstance(node, ast.ClassDef):
            funcs[node.name] = "class"
    return out, funcs


def test_shim_constants_equal_todays_dwd(env):
    c = env.write_cfg("amforge")
    consts, funcs = _fixture_constants()
    import dwd   # the shim: configures amforge and replaces itself with the shared module
    assert dwd is env.mod and dwd.COMPANY == "amforge"
    # Paths/ids the test had to redirect into tmp are compared against the REPO yaml, which must equal today's file.
    repo = yaml.safe_load((CFG_SRC / "companies" / "amforge.yaml").read_text())
    assert Path(repo["op_token_file"]) == consts["OP_TOKEN_FILE"]
    assert Path(repo["audit_log"]) == consts["AUDIT_LOG"]
    assert Path(repo["draft_ledger"]) == Path("/root/.hermes/google-workspace/state/draft_ledger.jsonl")
    assert repo["policy"]["hooks_dir"] == "/root/.hermes/hooks" and repo["policy"]["module"] == "af_policy"
    assert repo["run_as"] == {"user": "root", "home": "/root"}
    assert dwd.OP_VAULT == consts["OP_VAULT"]
    assert dwd.OP_ITEM_ID == consts["OP_ITEM_ID"]
    assert dwd.ALLOWED_SUBJECTS == consts["ALLOWED_SUBJECTS"]
    assert dwd.ALLOWED_DOMAINS == consts["ALLOWED_DOMAINS"]
    assert dwd.DOCS_ONLY_SUBJECTS == consts["DOCS_ONLY_SUBJECTS"]
    assert dwd.SCOPES_READ == consts["SCOPES_READ"]
    assert dwd.G == consts["G"]
    assert dwd.SYSTEM_READ_SUBJECTS == {"ncohn@amforge.com", "dhorn@amforge.com", "afedirka@amforge.com"}
    assert dwd.OP_TOKEN_FILE == Path(c["op_token_file"])
    # Every public name today's dwd.py defines exists with the same parameters.
    for name, sig in funcs.items():
        assert hasattr(dwd, name), name
        if sig == "class":
            assert inspect.isclass(getattr(dwd, name)), name
            continue
        p = inspect.signature(getattr(dwd, name)).parameters
        pos = [k for k, v in p.items() if v.kind in (v.POSITIONAL_ONLY, v.POSITIONAL_OR_KEYWORD)]
        kw = [k for k, v in p.items() if v.kind == v.KEYWORD_ONLY]
        assert (pos, kw) == sig, name
    assert issubclass(dwd.Refused, Exception)


def test_shim_tool_usage_pattern(env):
    """What h-af tools do: dwd.get(...), dwd.access_token(S, [dwd.SCOPES_READ[...]]), dwd._audit(...)."""
    env.write_cfg("amforge")
    import dwd
    r = dwd.get("dwhaley@amforge.com", "gmail", f"{dwd.G}/labels", "t.labels")
    assert len(r["labels"]) == 3
    tok = dwd.access_token("dwhaley@amforge.com", [dwd.SCOPES_READ["drive"]])
    assert tok.startswith("ya29.fake-")
    dwd._audit("drive.upload", subject="dwhaley@amforge.com", file_id="f1", name="n", parent="p")
    ev = [a["event"] for a in env.audit("amforge")]
    assert ev.count("token_minted") == 2 and "drive.upload" in ev and "api_read" in ev
    import af_policy
    assert ("check_dan_mailbox", "dwhaley@amforge.com") in af_policy.CALLS


# ---------------- allowlist ----------------
BYPASS = ["dwhaley+x@btpautomation.com", "dwhaley@btpautomation.com.evil.com", "dwhaley@evil.btpautomation.com",
          "dwhaley@btpautomation.com\n", "dwhaley@btpautomation.com\x00", '"dwhaley"@btpautomation.com',
          "Dan <dwhaley@btpautomation.com>", "dwhaley@btpautomation.com,evil@x.com", "dwhaley@btpautomation.com\u00a0",
          "dwh\u0430ley@btpautomation.com", "x@dwhaley@btpautomation.com", "dwhaley@btpautomation.com.",
          "dwhaley@btpautomation.co", "", None, 7, "dwhaley%40btpautomation.com", "\u212a@btpautomation.com"]


@pytest.mark.parametrize("subj", BYPASS)
def test_allowlist_refuses_bypass(env, subj):
    env.write_cfg("btp")
    env.mod.configure("btp")
    with pytest.raises(env.mod.Refused):
        env.mod.access_token(subj, [GMAIL])
    assert env.op_calls() == [] and env.fake.mints == []
    assert env.audit()[-1]["event"] == "refused"


def test_allowlist_control_case_and_space(env):
    env.write_cfg("btp")
    env.mod.configure("btp")
    for s in ("dwhaley@btpautomation.com", "DWhaley@BTPAutomation.com", "  dwhaley@btpautomation.com\t"):
        env.mod.access_token(s, [GMAIL])
    assert {m["sub"] for m in env.fake.mints} == {"dwhaley@btpautomation.com"}
    assert len(env.fake.mints) == 1   # one cache entry for every spelling


@pytest.mark.parametrize("subj,ok", [("a@ghi.gl", True), ("A.B-c_d@GHI.GL", True), ("evil@sub.ghi.gl", False),
                                     ("a@ghi.gl.evil.com", False), ("a+b@ghi.gl", False), ("a@x@ghi.gl", False),
                                     ("@ghi.gl", False), ("a@ghi.gl\n", False), ("a@evilghi.gl", False),
                                     ("bec\u212ai@amforge.com", False), ("becki@amforge.com", True)])
def test_domain_allowlist(env, subj, ok):
    env.write_cfg("amforge")
    env.mod.configure("amforge")
    assert env.mod.subject_allowed(subj) is ok
    if ok:
        env.mod.access_token(subj, [GMAIL])
    else:
        with pytest.raises(env.mod.Refused):
            env.mod.access_token(subj, [GMAIL])


@pytest.mark.parametrize("scopes", ["https://mail.google.com/", [], ["https://www.googleapis.com/auth/gmail.send"],
                                    [GMAIL, "https://www.googleapis.com/auth/admin.directory.user"], [None]])
def test_scopes_must_be_configured(env, scopes):
    env.write_cfg("btp")
    env.mod.configure("btp")
    with pytest.raises(env.mod.Refused):
        env.mod.access_token("dwhaley@btpautomation.com", scopes)
    assert env.fake.mints == [] and env.op_calls() == []


def test_unconfigured_service_scope_refused(env):
    env.write_cfg("btp", scopes={"gmail": GMAIL})
    env.mod.configure("btp")
    with pytest.raises(env.mod.Refused):
        env.mod.access_token("dwhaley@btpautomation.com", [DRIVE])
    with pytest.raises(env.mod.Refused):
        env.mod.get("dwhaley@btpautomation.com", "drive", "https://www.googleapis.com/drive/v3/about", "x")


# ---------------- AmForge policy paths (faithful port) ----------------
def test_docs_only_and_system_read(env):
    env.write_cfg("amforge")
    m = env.mod
    m.configure("amforge")
    import af_policy
    m.access_token("ncohn@amforge.com", [DRIVE])                          # Neil: Drive under docs-only grant
    assert ("check_docs_only_subject", "ncohn@amforge.com") in af_policy.CALLS
    with pytest.raises(m.Refused):
        m.access_token("ncohn@amforge.com", [GMAIL])                      # system-read, not read_only
    m.access_token("dhorn@amforge.com", [GMAIL], read_only=True)
    assert ("check_system_read_subject", "dhorn@amforge.com") in af_policy.CALLS
    with pytest.raises(m.Refused):
        m.access_token("dhorn@amforge.com", [GMAIL])
    with pytest.raises(m.Refused):
        m.gmail_create_draft("dhorn@amforge.com", to=["x@y.com"], cc=[], subj="s", body="b")
    af_policy.DENY.add("check_dan_mailbox")
    with pytest.raises(m.Refused):
        m.access_token("dwhaley@amforge.com", [GMAIL])
    assert "af_policy: PermissionError" in m_last_reason(env)


def m_last_reason(env):
    return env.audit("amforge")[-1].get("reason", "")


def test_policy_module_must_come_from_hooks_dir(env, tmp_path):
    env.write_cfg("amforge")
    other = tmp_path / "elsewhere"
    other.mkdir()
    shutil.copy(FIX / "hooks" / "af_policy.py", other / "af_policy.py")
    sys.path.insert(0, str(other))
    try:
        importlib.import_module("af_policy")          # a shadowing copy already imported
        with pytest.raises(env.mod.ConfigError):
            env.mod.configure("amforge")
    finally:
        sys.path.remove(str(other))


# ---------------- token cache keying ----------------
def test_token_cache_keying(env, monkeypatch):
    env.write_cfg("amforge")
    m = env.mod
    m.configure("amforge")
    a = m.access_token("dwhaley@amforge.com", [GMAIL])
    assert m.access_token("DWHALEY@amforge.com", [GMAIL]) == a            # same key
    b = m.access_token("dwhaley@amforge.com", [DRIVE])
    c = m.access_token("becki@amforge.com", [GMAIL])
    assert len({a, b, c}) == 3
    d1 = m.access_token("dwhaley@amforge.com", [GMAIL, DRIVE])
    assert m.access_token("dwhaley@amforge.com", [DRIVE, GMAIL, DRIVE]) == d1   # order/dupes don't matter
    assert len(env.fake.mints) == 4
    assert env.fake.mints[-1]["scope"] == f"{GMAIL} {DRIVE}"
    assert len(env.op_calls()) == 1                                         # key fetched once per process
    # near expiry -> re-mint
    for k in list(m._tok_cache):
        m._tok_cache[k] = (m._tok_cache[k][0], time.time() + 30)
    assert m.access_token("dwhaley@amforge.com", [GMAIL]) != a
    # another company: no token or key crosses over
    env.write_cfg("btp")
    m.configure("btp")
    assert m._tok_cache == {} and m._key_cache is None
    m.access_token("dwhaley@btpautomation.com", [GMAIL])
    assert len(env.op_calls()) == 2
    with pytest.raises(m.Refused):
        m.access_token("dwhaley@amforge.com", [GMAIL])


# ---------------- key / token never on disk or in logs ----------------
def _all_bytes(root: Path, skip: set):
    for p in root.rglob("*"):
        if p.is_file() and not p.is_symlink() and p not in skip:
            yield p, p.read_bytes()


def test_key_and_op_token_never_written(env, capfd):
    c = env.write_cfg("btp")
    m = env.mod
    m.configure("btp")
    m.get("dwhaley@btpautomation.com", "gmail", f"{m.G}/labels", "t")
    m.gmail_create_draft("dwhaley@btpautomation.com", to=["a@b.com"], cc=[], subj="s", body="b")
    env.fake.token_error = (401, {"error": "unauthorized_client", "error_description": "no"})
    with pytest.raises(m.TokenError):
        m.access_token("dwhaley@btpautomation.com", [CAL])
    out = capfd.readouterr()
    body = env.pem.split("-----")[2].replace("\n", "")[:40]
    skip = {env.fop / "key.json", env.fop / "expected-token", Path(c["op_token_file"])}
    for p, data in _all_bytes(env.tmp, skip):
        for needle in (b"PRIVATE KEY", body.encode(), OP_TOKEN.encode(), b"kid-test-1234"):
            assert needle not in data, (p, needle)
    for s in (out.out, out.err):
        assert OP_TOKEN not in s and "PRIVATE KEY" not in s
    # only PATH, HOME and the token reach op
    assert (env.fop / "env-names").read_text().split() == ["HOME", "OP_SERVICE_ACCOUNT_TOKEN", "PATH"]


def test_op_failure_and_bad_item_messages_hold_no_secret(env):
    env.write_cfg("btp")
    m = env.mod
    m.configure("btp")
    (env.fop / "key.json").write_text('{"type": "service_account", "private_key": "-----BEGIN PRIVATE KEY----- AAAA')
    with pytest.raises(RuntimeError) as ei:
        m.access_token("dwhaley@btpautomation.com", [GMAIL])
    assert "PRIVATE" not in str(ei.value) and ei.value.__suppress_context__
    (env.fop / "key.json").write_text(json.dumps({**env.sa, "token_uri": "https://evil.example/token"}))
    with pytest.raises(RuntimeError, match="unexpected token_uri"):
        m.access_token("dwhaley@btpautomation.com", [GMAIL])
    assert env.fake.mints == []
    (env.fop / "fail").write_text("[ERROR] could not find item")
    with pytest.raises(RuntimeError) as ei:
        m.access_token("dwhaley@btpautomation.com", [GMAIL])
    assert "1Password fetch failed" in str(ei.value) and OP_TOKEN not in str(ei.value)


@pytest.mark.parametrize("bad", ["mode", "symlink", "missing", "empty"])
def test_op_token_file_must_be_private(env, bad):
    c = env.write_cfg("btp")
    tf = Path(c["op_token_file"])
    if bad == "mode":
        os.chmod(tf, 0o640)
    elif bad == "symlink":
        real = tf.with_name("real")
        tf.rename(real)
        tf.symlink_to(real)
    elif bad == "missing":
        tf.unlink()
    else:
        tf.write_text("")
    env.mod.configure("btp")
    with pytest.raises(RuntimeError, match="1Password token file"):
        env.mod.access_token("dwhaley@btpautomation.com", [GMAIL])
    assert env.op_calls() == []


# ---------------- audit log / ledger permissions ----------------
def test_audit_log_created_0600_and_fixed(env):
    c = env.write_cfg("btp")
    m = env.mod
    m.configure("btp")
    m._audit("x")
    p = Path(c["audit_log"])
    assert stat.S_IMODE(p.stat().st_mode) == 0o600
    assert stat.S_IMODE(p.parent.stat().st_mode) == 0o700
    os.chmod(p, 0o644)
    m._audit("y")
    assert stat.S_IMODE(p.stat().st_mode) == 0o600
    assert [a["event"] for a in env.audit()] == ["x", "y"]


def test_audit_log_symlink_refused(env):
    c = env.write_cfg("btp")
    m = env.mod
    m.configure("btp")
    p = Path(c["audit_log"])
    p.parent.mkdir(parents=True)
    victim = env.tmp / "victim"
    victim.write_text("keep\n")
    p.symlink_to(victim)
    with pytest.raises(OSError):
        m._audit("x")
    assert victim.read_text() == "keep\n"


@pytest.mark.skipif(os.geteuid() != 0, reason="needs root to chown")
def test_audit_log_foreign_owner_refused(env):
    c = env.write_cfg("btp")
    m = env.mod
    m.configure("btp")
    p = Path(c["audit_log"])
    p.parent.mkdir(parents=True)
    p.write_text("")
    os.chown(p, 65534, 65534)
    with pytest.raises(RuntimeError, match="owned by the running user"):
        m._audit("x")
    assert p.read_text() == ""


# ---------------- drafts + ledger ----------------
def test_draft_create_and_trash_guard(env, monkeypatch):
    c = env.write_cfg("btp")
    m = env.mod
    m.configure("btp")
    monkeypatch.setenv("HERMES_SESSION_ID", "sess-1")
    m.gmail_create_draft("DWhaley@btpautomation.com", to=["a@b.com"], cc=[], subj="hello", body="b")
    led = Path(c["draft_ledger"])
    assert stat.S_IMODE(led.stat().st_mode) == 0o600
    rec = json.loads(led.read_text().splitlines()[-1])
    assert rec["subject"] == "dwhaley@btpautomation.com" and rec["draft_id"] == "r123"
    assert ("POST", f"{m.G}/drafts") == env.fake.requests[-1][:2]
    with pytest.raises(m.Refused):
        m.gmail_trash_draft("dwhaley@btpautomation.com", "other")
    monkeypatch.setenv("HERMES_SESSION_ID", "sess-2")
    with pytest.raises(m.Refused):
        m.gmail_trash_draft("dwhaley@btpautomation.com", "r123")
    monkeypatch.setenv("HERMES_SESSION_ID", "sess-1")
    with pytest.raises(m.Refused):
        m.gmail_trash_draft("dwhaley@btpautomation.com", "r123/../../messages/x")
    m.gmail_trash_draft("dwhaley@btpautomation.com", "r123")
    assert env.fake.requests[-1][:2] == ("POST", f"{m.G}/messages/m123/trash")
    assert not any(method == "DELETE" for method, _, _ in env.fake.requests)


# ---------------- no send path (structural) ----------------
ALLOWED_SEND_NAMES = {"calendar_send_invites", "send_updates", "updates"}
SEND_URL = re.compile(r"/send\b|:send\b|\bdrafts\.send\b|\bmessages\.send\b|gmail\.send|sendAs|/send-?as", re.I)
SEND_PIECE = re.compile(r"(^|/)send($|[/?:])", re.I)


def _flat_strings(n) -> str:
    """Constant text of a string-building expression (a + b, f-strings, '...'.join([...])), joined."""
    if isinstance(n, ast.Constant) and isinstance(n.value, str):
        return n.value
    if isinstance(n, ast.BinOp) and isinstance(n.op, (ast.Add, ast.Mod)):
        return _flat_strings(n.left) + _flat_strings(n.right)
    if isinstance(n, ast.JoinedStr):
        return "".join(_flat_strings(v) if isinstance(v, ast.Constant) else "{}" for v in n.values)
    if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute) and n.func.attr in ("join", "format"):
        parts = [_flat_strings(a) for a in n.args]
        for a in n.args:
            if isinstance(a, (ast.List, ast.Tuple)):
                parts += [_flat_strings(e) for e in a.elts]
        return _flat_strings(n.func.value) + "/".join(parts)
    return ""


def send_findings(src: str) -> list[str]:
    tree = ast.parse(src)
    bad = []
    for n in ast.walk(tree):
        names = []
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.append(n.name)
        elif isinstance(n, ast.Name):
            names.append(n.id)
        elif isinstance(n, ast.Attribute):
            names.append(n.attr)
        elif isinstance(n, ast.arg):
            names.append(n.arg)
        elif isinstance(n, ast.keyword) and n.arg:
            names.append(n.arg)
        elif isinstance(n, ast.alias):
            names.append(n.asname or n.name)
        if isinstance(n, ast.Constant) and isinstance(n.value, str) and (SEND_URL.search(n.value)
                                                                          or SEND_PIECE.search(n.value)):
            bad.append(f"string: {n.value[:60]!r}")
        if isinstance(n, (ast.BinOp, ast.JoinedStr, ast.Call)):
            flat = _flat_strings(n)
            if flat and SEND_URL.search(flat.replace("//", "/")):
                bad.append(f"composed: {flat[:60]!r}")
        for nm in names:
            if "send" in nm.lower() and nm not in ALLOWED_SEND_NAMES:
                bad.append(f"name: {nm}")
    if re.search(r"messages/send|drafts/send|users\.messages\.send|users\.drafts\.send", src):
        bad.append("raw: send endpoint text")
    return bad


@pytest.mark.parametrize("f", ["fleet_google_dwd.py", "dwd.py", "bin/fleet-google-dwd-check"])
def test_no_send_path(f):
    assert send_findings((PKG / f).read_text()) == []


@pytest.mark.parametrize("mutant", [
    "def gmail_send(subject, raw):\n    pass\n",
    "u = G + '/messages/send'\n",
    "u = f'{G}/drafts/send'\n",
    "x = obj.send(1)\n",
    "def f(sendit=1):\n    pass\n",
    "S = 'https://www.googleapis.com/auth/gmail.send'\n",
    # r1 #9: composed endpoints
    "def deliver(subject, raw):\n    u = G + '/messages/' + 'send'\n    return u\n",
    "def deliver(subject, raw):\n    return '/'.join([G, 'drafts', 'send'])\n",
    "def deliver(mid):\n    return f'{G}/messages/{mid}' + '/se' + 'nd'\n",
    "VERB = 'send'\n",
])
def test_no_send_checker_bites(mutant):
    src = (PKG / "fleet_google_dwd.py").read_text() + "\n" + mutant
    assert send_findings(src), mutant


def test_module_exposes_no_send_function(env):
    assert not [n for n in dir(env.mod) if "send" in n.lower() and n != "calendar_send_invites"]


# ---------------- config trust ----------------
def test_config_trust_and_schema(env):
    m = env.mod
    env.write_cfg("btp")
    p = env.cfgdir / "btp.yaml"
    os.chmod(p, 0o666)
    with pytest.raises(m.ConfigError):
        m.configure("btp")
    os.chmod(p, 0o644)
    os.chmod(env.cfgdir, 0o777)
    with pytest.raises(m.ConfigError):
        m.configure("btp")
    os.chmod(env.cfgdir, 0o755)
    for over in ({"extra": 1}, {"scopes": {"gmail": "https://www.googleapis.com/auth/gmail.readonly"}},
                 {"scopes": {"gmail": GMAIL, "admin": DRIVE}}, {"smoke_subject": "x@btpautomation.com"},
                 {"allowed_subjects": ["DWhaley@btpautomation.com"]}, {"allowed_subjects": "dwhaley@btpautomation.com"},
                 {"allowed_subjects": []}, {"docs_only_subjects": ["n@btpautomation.com"]},
                 {"allowed_domains": ["btpautomation.com\n"]}, {"audit_log": "relative/log"},
                 {"run_as": {"user": "nobody-else-x", "home": "/home/x"}}, {"company": "amforge"},
                 {"op_vault": None}, {"policy": {"hooks_dir": "/x", "module": "os.path"}}):
        env.write_cfg("btp", **over)
        with pytest.raises(m.ConfigError):
            m.configure("btp")
    for name in ("../btp", "BTP", "b/t", "", "a" * 40):
        with pytest.raises(m.ConfigError):
            m.configure(name)
    env.write_cfg("btp")
    assert m.configure("btp") == "btp"     # control: the same file, fixed, loads


def test_config_symlink_refused(env, tmp_path):
    env.write_cfg("btp")
    real = tmp_path / "real.yaml"
    shutil.move(env.cfgdir / "btp.yaml", real)
    (env.cfgdir / "btp.yaml").symlink_to(real)
    with pytest.raises(OSError):
        env.mod.configure("btp")


# ---------------- smoke tool ----------------
def _check_tool(env):
    loader = importlib.machinery.SourceFileLoader("fgd_check", str(PKG / "bin" / "fleet-google-dwd-check"))
    spec = importlib.util.spec_from_loader("fgd_check", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    assert mod.d is env.mod
    return mod


def test_check_ok(env, capsys):
    env.write_cfg("btp")
    rc = _check_tool(env).main(["--company", "btp"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "gmail: OK labels=3" in out and "calendar: OK calendars=2" in out and "drive: OK user=matches-subject" in out
    assert len(env.fake.mints) == 3 and {m["scope"] for m in env.fake.mints} == {GMAIL, CAL, DRIVE}
    assert all(method == "GET" for method, _, _ in env.fake.requests)


def test_check_unauthorized_client(env, capsys):
    env.write_cfg("btp")
    env.fake.token_error = (401, {"error": "unauthorized_client",
                                  "error_description": "Client is unauthorized to retrieve access tokens"})
    rc = _check_tool(env).main(["--company", "btp"])
    out = capsys.readouterr().out
    assert rc == 3
    assert out.count("NOT AUTHORISED YET") == 3 and "client ID 123456789012345678901" in out
    assert "Traceback" not in out


def test_check_other_failures(env, capsys):
    env.write_cfg("btp")
    env.fake.drive_email = "someone-else@btpautomation.com"
    env.fake.api_status["https://gmail.googleapis.com"] = 403
    rc = _check_tool(env).main(["--company", "btp"])
    out = capsys.readouterr().out
    assert rc == 1
    assert "gmail: FAILED (gmail API 403)" in out and "DOES-NOT-MATCH" in out
    assert "secret-body" not in out and "someone-else" not in out


def test_check_config_error(env, capsys):
    rc = _check_tool(env).main(["--company", "btp"])     # no config written
    assert rc == 2 and "config: FAILED" in capsys.readouterr().out


# ---------------- r1 regression tests ----------------
def test_r1_1_op_stderr_never_shown(env, capsys):
    env.write_cfg("btp")
    (env.fop / "fail").write_text(f"[ERROR] token {OP_TOKEN} -----BEGIN PRIVATE KEY----- isn't an item\n")
    m = env.mod
    m.configure("btp")
    with pytest.raises(RuntimeError) as ei:
        m.access_token("dwhaley@btpautomation.com", [GMAIL])
    assert OP_TOKEN not in str(ei.value) and "PRIVATE" not in str(ei.value)
    assert "item or vault not found" in str(ei.value)
    rc = _check_tool(env).main(["--company", "btp"])
    out = capsys.readouterr()
    assert rc == 1 and OP_TOKEN not in out.out + out.err and "PRIVATE" not in out.out + out.err


def test_r1_3_parent_symlink_refused(env):
    c = env.write_cfg("btp")
    m = env.mod
    m.configure("btp")
    led = Path(c["draft_ledger"])
    led.parent.parent.mkdir(parents=True)
    elsewhere = env.tmp / "elsewhere"
    elsewhere.mkdir()
    led.parent.symlink_to(elsewhere)                 # .../state -> elsewhere
    with pytest.raises(OSError):
        m._ledger_add("dwhaley@btpautomation.com", "r1", "m1", ["a@b.com"], "s")
    assert list(elsewhere.iterdir()) == []
    led.parent.unlink()
    led.parent.mkdir()
    os.chmod(led.parent, 0o777)                      # group/other-writable parent
    with pytest.raises(RuntimeError, match="not group/other-writable"):
        m._ledger_add("dwhaley@btpautomation.com", "r1", "m1", ["a@b.com"], "s")
    os.chmod(led.parent, 0o700)
    m._ledger_add("dwhaley@btpautomation.com", "r1", "m1", ["a@b.com"], "s")   # control
    assert led.exists()


def test_r1_3_op_token_parent_symlink_refused(env):
    c = env.write_cfg("btp")
    tf = Path(c["op_token_file"])
    real = env.tmp / "realsecret"
    shutil.move(tf.parent, real)
    tf.parent.symlink_to(real)
    env.mod.configure("btp")
    with pytest.raises(RuntimeError, match="1Password token file"):
        env.mod.access_token("dwhaley@btpautomation.com", [GMAIL])
    assert env.op_calls() == []


def test_r1_4_rotated_item_clears_key(env):
    env.write_cfg("btp")
    m = env.mod
    m.configure("btp")
    m.access_token("dwhaley@btpautomation.com", [GMAIL])
    env.write_cfg("btp", op_item="Rotated Google Service Account BTP")
    m.configure("btp")
    assert m._key_cache is None and m._tok_cache == {}
    m.access_token("dwhaley@btpautomation.com", [GMAIL])
    assert env.op_calls()[-1].split()[2:4] == ["Rotated", "Google"]
    assert len(env.op_calls()) == 2
    m.configure("btp")                                 # same identity: caches kept
    assert m._key_cache is not None and m._tok_cache


def test_r1_5_drive_roles_as_original(env):
    env.write_cfg("amforge")
    m = env.mod
    m.configure("amforge")
    for role in ("organizer", "fileOrganizer", "writer"):
        m.drive_share("dwhaley@amforge.com", "drive1", ["amendez@amforge.com"], role=role)
    assert sum(1 for meth, u, _ in env.fake.requests if meth == "POST" and "/permissions" in u) == 3


def test_r1_6_legacy_mixed_case_ledger(env, monkeypatch):
    c = env.write_cfg("amforge")
    m = env.mod
    m.configure("amforge")
    led = Path(c["draft_ledger"])
    led.parent.mkdir(parents=True)
    led.write_text(json.dumps({"subject": "DWHALEY@amforge.com", "draft_id": "r123", "session": "sess-1"}) + "\n")
    os.chmod(led, 0o600)
    monkeypatch.setenv("HERMES_SESSION_ID", "sess-1")
    m.gmail_trash_draft("DWHALEY@amforge.com", "r123")
    assert env.fake.requests[-1][:2] == ("POST", f"{m.G}/messages/m123/trash")
    with pytest.raises(m.Refused):
        m.gmail_trash_draft("becki@amforge.com", "r123")          # subject still must match


def test_r1_7_audit_0700_repaired(env):
    c = env.write_cfg("btp")
    m = env.mod
    m.configure("btp")
    p = Path(c["audit_log"])
    p.parent.mkdir(parents=True)
    p.write_text("")
    os.chmod(p, 0o700)
    m._audit("x")
    assert stat.S_IMODE(p.stat().st_mode) == 0o600


def test_r1_8_long_unauthorized_body(env, capsys):
    env.write_cfg("btp")
    env.fake.token_error = (400, {"error": "unauthorized_client", "error_description": "x" * 300})
    rc = _check_tool(env).main(["--company", "btp"])
    assert rc == 3 and capsys.readouterr().out.count("NOT AUTHORISED YET") == 3


@pytest.mark.parametrize("run_as,msg", [("root", "does not match run_as.user"),
                                        ("hermes-nonexistent-x", "does not match run_as.user")])
def test_r1_2_installer_run_as_must_match(tmp_path, run_as, msg):
    cfg = tmp_path / "cfg"
    shutil.copytree(CFG_SRC, cfg)
    (cfg / "hosts" / "h-test.env").write_text(f"ROLLOUT=go\nCOMPANY=btp\nRUN_AS={run_as}\nPYTHON=/usr/bin/python3\n")
    before = Path("/usr/local/lib/fleet-google-dwd").exists(), Path("/etc/fleet-google-dwd").exists()
    r = subprocess.run(["bash", str(REPO / "lib" / "63-fleet-google-dwd.sh")], cwd=REPO,
                       env={**os.environ, "FLEET_HOST_ID": "h-test", "REPO_ROOT": str(REPO), "FGD_CONFIG_DIR": str(cfg)},
                       capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    assert r.returncode != 0 and msg in r.stdout + r.stderr
    assert (Path("/usr/local/lib/fleet-google-dwd").exists(), Path("/etc/fleet-google-dwd").exists()) == before


# ---------------- installer module ----------------
def test_installer_lint():
    f = REPO / "lib" / "63-fleet-google-dwd.sh"
    subprocess.run(["bash", "-n", str(f)], check=True)
    if shutil.which("shellcheck"):
        subprocess.run(["shellcheck", "-S", "warning", "-x", str(f)], check=True, cwd=REPO / "lib")
    assert re.fullmatch(r"[0-9A-Z][0-9A-Z]-.*\.sh", f.name)


def test_installer_holds_without_go(tmp_path):
    """Every shipped host file is ROLLOUT=hold, so the module writes nothing (it skips before require_sudo)."""
    for host in ("h-btp", "h-af", "h-unknown"):
        r = subprocess.run(["bash", str(REPO / "lib" / "63-fleet-google-dwd.sh")], cwd=REPO,
                           env={**os.environ, "FLEET_HOST_ID": host, "REPO_ROOT": str(REPO)},
                           capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
        assert r.returncode == 0, r.stderr
        assert ("ROLLOUT is not go" in r.stdout + r.stderr) or ("not a Google DWD node" in r.stdout + r.stderr)
        assert "installed" not in r.stdout
