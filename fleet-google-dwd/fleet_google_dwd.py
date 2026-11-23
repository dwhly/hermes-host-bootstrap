#!/usr/bin/env python3
"""Fleet Google domain-wide-delegation (DWD) connector, shared by every company.

One code path for every company; each company is a reviewed YAML file under CONFIG_DIR
(installed root-owned by bootstrap module 63-fleet-google-dwd). Ported from AmForge's
h-af /root/.hermes/google-workspace/dwd.py (2026-11-23) with the same API:
access_token, get, _audit, Refused, the Gmail read helpers, drafts + ledger, calendar
event creation/invites and people-only Drive sharing.

- The service-account key lives ONLY in the company's 1Password vault. It is fetched per
  process with the op CLI into memory and never written to disk or to the audit log.
- Impersonation is restricted to the config's allowlists (Google itself would allow any user
  in the domain; this allowlist is the Hermes-side limit). Subjects are ASCII-only, exact
  matches after lower-casing; plus-addressing and sub-domains are refused.
- Every token mint and API call is appended to the company's audit log (metadata only).
- There is NO Gmail send in this module, by design. Sending needs an explicit owner "send"
  instruction and a separate reviewed code path (a test fails if one appears here).
  Note: access_token() hands its caller a token for the configured scope; what the caller does
  with it is that caller's code, exactly as in the AmForge original.
- Draft removal: ONLY via gmail_trash_draft(), which trashes (never hard-deletes) a single
  draft that this same Hermes session created (see DRAFT_LEDGER).

Use: `import fleet_google_dwd as dwd; dwd.configure("btp")` (or configure() to use the host's
company from CONFIG_DIR/host-company). The `dwd` shim next to this file does
configure("amforge") for h-af's existing `import dwd` callers.
"""
from __future__ import annotations

import base64
import importlib
import json
import os
import pwd
import re
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

CONFIG_DIR = Path("/etc/fleet-google-dwd")
TRUSTED_CONFIG_UIDS = frozenset({0})
# The only token endpoint a key may name (a tampered 1Password item can't redirect the signed assertion).
ALLOWED_TOKEN_URIS = frozenset({"https://oauth2.googleapis.com/token"})
# DWD only mints tokens for the EXACT scope strings authorized in Admin. These are the authorized (full)
# scopes; this module's code paths are still read-only except drafts/calendar/share helpers below.
KNOWN_SCOPES = {
    "gmail": "https://mail.google.com/",
    "calendar": "https://www.googleapis.com/auth/calendar",
    "drive": "https://www.googleapis.com/auth/drive",
}
G = "https://gmail.googleapis.com/gmail/v1/users/me"

_CONFIG_KEYS = {"company", "op_vault", "op_item", "op_token_file", "run_as", "allowed_subjects",
                "allowed_domains", "docs_only_subjects", "scopes", "audit_log", "draft_ledger",
                "smoke_subject", "policy"}
_REQUIRED_KEYS = {"company", "op_vault", "op_item", "op_token_file", "run_as", "allowed_subjects",
                  "scopes", "audit_log", "draft_ledger", "smoke_subject"}
_NAME_RE = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")
_EMAIL_RE = re.compile(r"[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?@(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}")
_DOMAIN_RE = re.compile(r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}")

# ---- configured state (set only by configure()) ----
COMPANY: str | None = None
CONFIG_PATH: Path | None = None
OP_TOKEN_FILE: Path | None = None
OP_VAULT: str | None = None
OP_ITEM_ID: str | None = None
AUDIT_LOG: Path | None = None
DRAFT_LEDGER: Path | None = None
RUN_AS_USER: str | None = None
RUN_AS_HOME: str | None = None
SMOKE_SUBJECT: str | None = None
ALLOWED_SUBJECTS: set = set()
ALLOWED_DOMAINS: set = set()
DOCS_ONLY_SUBJECTS: set = set()
SYSTEM_READ_SUBJECTS: set = set()
SCOPES_READ: dict = {}
_policy = None

_key_cache: dict | None = None
_tok_cache: dict[tuple, tuple[str, float]] = {}
_urlopen = urllib.request.urlopen   # the one HTTP entry point (tests replace it)


class Refused(Exception):
    pass


class ConfigError(Exception):
    pass


class TokenError(RuntimeError):
    """Token mint refused by the token endpoint. .status (HTTP code) and .error (OAuth error code)."""

    def __init__(self, msg: str, status: int, error: str):
        super().__init__(msg)
        self.status, self.error = status, error


class ApiError(RuntimeError):
    def __init__(self, msg: str, service: str, status: int):
        super().__init__(msg)
        self.service, self.status = service, status


# ---------------- configuration ----------------
def _trusted_file(p: Path) -> bytes:
    """Read a config file only if it and its directory are root-owned and not group/other-writable."""
    for d in (p.parent,):
        st = os.lstat(d)
        if not stat.S_ISDIR(st.st_mode) or st.st_uid not in TRUSTED_CONFIG_UIDS or st.st_mode & 0o022:
            raise ConfigError(f"config dir {d} must be a root-owned directory, not group/other-writable")
    fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid not in TRUSTED_CONFIG_UIDS or st.st_mode & 0o022:
            raise ConfigError(f"config {p} must be a root-owned regular file, not group/other-writable")
        if st.st_size > 65536:
            raise ConfigError(f"config {p} is too large")
        return os.read(fd, 65536)
    finally:
        os.close(fd)


def normalize_subject(subject) -> str:
    """'' unless `subject` is a plain ASCII mailbox address (no plus-addressing, no quoting)."""
    if not isinstance(subject, str):
        return ""
    s = subject.strip(" \t")
    if not s.isascii():            # before lower(): e.g. KELVIN SIGN lower-cases to ASCII 'k'
        return ""
    s = s.lower()
    return s if _EMAIL_RE.fullmatch(s) else ""


def _str(cfg, key, *, path=False) -> str:
    v = cfg.get(key)
    if not isinstance(v, str) or not v or v != v.strip() or any(c in v for c in "\r\n\0"):
        raise ConfigError(f"{key}: must be a non-empty single-line string")
    if path and not (v.startswith("/") and "/../" not in v + "/" and not v.endswith("/")):
        raise ConfigError(f"{key}: must be an absolute normalised path")
    return v


def _emails(cfg, key, required=False) -> set:
    v = cfg.get(key, [])
    if v is None:
        v = []
    if not isinstance(v, list) or (required and not v):
        raise ConfigError(f"{key}: must be a {'non-empty ' if required else ''}list")
    out = set()
    for e in v:
        n = normalize_subject(e) if isinstance(e, str) else ""
        if not n or n != e:
            raise ConfigError(f"{key}: {e!r} is not a lower-case plain address")
        out.add(n)
    return out


def _load_config(company: str) -> dict:
    raw = _trusted_file(CONFIG_DIR / f"{company}.yaml")
    import yaml
    cfg = yaml.safe_load(raw)
    if not isinstance(cfg, dict) or not all(isinstance(k, str) for k in cfg):
        raise ConfigError("config must be a mapping")
    unknown = set(cfg) - _CONFIG_KEYS
    missing = _REQUIRED_KEYS - set(cfg)
    if unknown or missing:
        raise ConfigError(f"config keys: unknown {sorted(unknown)}, missing {sorted(missing)}")
    if cfg["company"] != company:
        raise ConfigError(f"config company {cfg['company']!r} != file name {company!r}")
    out = {"company": company, "op_vault": _str(cfg, "op_vault"), "op_item": _str(cfg, "op_item"),
           "op_token_file": Path(_str(cfg, "op_token_file", path=True)),
           "audit_log": Path(_str(cfg, "audit_log", path=True)),
           "draft_ledger": Path(_str(cfg, "draft_ledger", path=True)),
           "allowed_subjects": _emails(cfg, "allowed_subjects", required=True),
           "docs_only_subjects": _emails(cfg, "docs_only_subjects")}
    ra = cfg["run_as"]
    if not isinstance(ra, dict) or set(ra) != {"user", "home"}:
        raise ConfigError("run_as: must be {user, home}")
    out["run_as_user"] = _str(ra, "user")
    out["run_as_home"] = _str(ra, "home", path=True)
    doms = cfg.get("allowed_domains", []) or []
    if not isinstance(doms, list) or not all(isinstance(d, str) and _DOMAIN_RE.fullmatch(d) for d in doms):
        raise ConfigError("allowed_domains: must be a list of lower-case domains")
    out["allowed_domains"] = set(doms)
    sc = cfg["scopes"]
    if (not isinstance(sc, dict) or not sc or set(sc) - set(KNOWN_SCOPES)
            or any(sc[k] != KNOWN_SCOPES[k] for k in sc)):
        raise ConfigError(f"scopes: must map a subset of {sorted(KNOWN_SCOPES)} to their exact scope URLs")
    out["scopes"] = dict(sc)
    smoke = cfg["smoke_subject"]
    if not isinstance(smoke, str) or smoke not in out["allowed_subjects"]:
        raise ConfigError("smoke_subject: must be one of allowed_subjects")
    out["smoke_subject"] = smoke
    pol = cfg.get("policy")
    if pol is not None:
        if not isinstance(pol, dict) or set(pol) != {"hooks_dir", "module"}:
            raise ConfigError("policy: must be {hooks_dir, module}")
        _str(pol, "hooks_dir", path=True)
        if not isinstance(pol["module"], str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", pol["module"]):
            raise ConfigError("policy.module: must be a module name")
    elif out["docs_only_subjects"]:
        raise ConfigError("docs_only_subjects need a policy module (who may ask is gated there)")
    out["policy"] = pol
    return out


def _load_policy(pol: dict):
    hooks = os.path.realpath(pol["hooks_dir"])
    if pol["hooks_dir"] not in sys.path:
        sys.path.insert(0, pol["hooks_dir"])
    mod = importlib.import_module(pol["module"])
    f = getattr(mod, "__file__", None)
    if not f or os.path.dirname(os.path.realpath(f)) != hooks:
        raise ConfigError(f"policy module {pol['module']} must be loaded from {hooks}")
    for fn in ("check_dan_mailbox", "check_ghi_mailbox", "check_docs_only_subject", "check_system_read_subject"):
        if not callable(getattr(mod, fn, None)):
            raise ConfigError(f"policy module {pol['module']} lacks {fn}()")
    return mod


def configure(company: str | None = None) -> str:
    """Load CONFIG_DIR/<company>.yaml (default: the name in CONFIG_DIR/host-company). Fails closed."""
    global COMPANY, CONFIG_PATH, OP_TOKEN_FILE, OP_VAULT, OP_ITEM_ID, AUDIT_LOG, DRAFT_LEDGER, RUN_AS_USER
    global RUN_AS_HOME, SMOKE_SUBJECT, ALLOWED_SUBJECTS, ALLOWED_DOMAINS, DOCS_ONLY_SUBJECTS
    global SYSTEM_READ_SUBJECTS, SCOPES_READ, _policy, _key_cache, _tok_cache
    if company is None:
        company = _trusted_file(CONFIG_DIR / "host-company").decode("ascii", "strict").strip()
    if not isinstance(company, str) or not _NAME_RE.fullmatch(company):
        raise ConfigError(f"company name {company!r} is not valid")
    c = _load_config(company)
    me = pwd.getpwuid(os.geteuid()).pw_name
    if me != c["run_as_user"]:
        raise ConfigError(f"{company} runs as {c['run_as_user']}, not {me}")
    pol = _load_policy(c["policy"]) if c["policy"] else None
    sys_read = set()
    if pol is not None:
        for e in getattr(pol, "SYSTEM_READ_SUBJECTS", set()):
            n = normalize_subject(e)
            if not n:
                raise ConfigError(f"policy SYSTEM_READ_SUBJECTS has a bad address {e!r}")
            sys_read.add(n)
    if company != COMPANY:
        _key_cache, _tok_cache = None, {}
    COMPANY, CONFIG_PATH = company, CONFIG_DIR / f"{company}.yaml"
    OP_TOKEN_FILE, OP_VAULT, OP_ITEM_ID = c["op_token_file"], c["op_vault"], c["op_item"]
    AUDIT_LOG, DRAFT_LEDGER = c["audit_log"], c["draft_ledger"]
    RUN_AS_USER, RUN_AS_HOME, SMOKE_SUBJECT = c["run_as_user"], c["run_as_home"], c["smoke_subject"]
    ALLOWED_SUBJECTS, ALLOWED_DOMAINS = c["allowed_subjects"], c["allowed_domains"]
    DOCS_ONLY_SUBJECTS, SYSTEM_READ_SUBJECTS = c["docs_only_subjects"], sys_read
    SCOPES_READ, _policy = c["scopes"], pol
    return company


def _ensure():
    if COMPANY is None:
        configure()


# ---------------- private files (audit log, ledger) ----------------
def _open_private(path: Path, flags: int) -> int:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(path, flags | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid():
        os.close(fd)
        raise RuntimeError(f"{path} must be a regular file owned by the running user")
    if st.st_mode & 0o077:
        os.fchmod(fd, 0o600)
    return fd


def _append_private(path: Path, rec: dict):
    fd = _open_private(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND)
    try:
        os.write(fd, (json.dumps(rec) + "\n").encode())
    finally:
        os.close(fd)


def _audit(event: str, **kw):
    _ensure()
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "event": event,
           "requester": os.environ.get("HERMES_REQUESTER", "cli-session"), **kw}
    _append_private(AUDIT_LOG, rec)


def _refuse_system_write(subject: str, action: str, drive: bool = False):
    s = (subject or "").lower().strip()
    if s in SYSTEM_READ_SUBJECTS and not (drive and s in DOCS_ONLY_SUBJECTS):
        _audit("refused", subject=s, action=action, reason="system-read subject: writes are not allowed")
        raise Refused(f"{s} is delegated to the system for reading only; {action} refused")
    if s in SYSTEM_READ_SUBJECTS:
        _audit("allowed", subject=s, action=action, reason="Drive write under the owner's Docs-only grant")


def subject_allowed(subject: str) -> bool:
    _ensure()
    s = normalize_subject(subject)
    return bool(s) and (s in ALLOWED_SUBJECTS or s in DOCS_ONLY_SUBJECTS or s in SYSTEM_READ_SUBJECTS
                        or s.rsplit("@", 1)[1] in ALLOWED_DOMAINS)


# ---------------- key + token ----------------
def _read_op_token() -> str:
    try:
        fd = os.open(OP_TOKEN_FILE, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as e:
        raise RuntimeError(f"1Password token file {OP_TOKEN_FILE} not readable ({e.strerror})") from None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or st.st_mode & 0o077:
            raise RuntimeError(f"1Password token file {OP_TOKEN_FILE} must be a 0600 file owned by the running user")
        tok = os.read(fd, 8192).decode("ascii", "strict").strip()
    finally:
        os.close(fd)
    if not tok:
        raise RuntimeError(f"1Password token file {OP_TOKEN_FILE} is empty")
    return tok


def _load_key() -> dict:
    global _key_cache
    _ensure()
    if _key_cache is None:
        tok = _read_op_token()
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": RUN_AS_HOME,
               "OP_SERVICE_ACCOUNT_TOKEN": tok}
        r = subprocess.run(["op", "document", "get", OP_ITEM_ID, "--vault", OP_VAULT],
                           env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=60)
        del tok, env
        if r.returncode != 0:
            raise RuntimeError("1Password fetch failed: " + r.stderr.decode(errors="replace")[:200])
        try:
            k = json.loads(r.stdout)
        except ValueError:
            raise RuntimeError("1Password item is not a JSON service-account key") from None
        if not isinstance(k, dict) or k.get("type") != "service_account":
            raise RuntimeError("1Password item is not a service-account key")
        for f in ("private_key", "private_key_id", "client_email", "client_id", "token_uri"):
            if not isinstance(k.get(f), str) or not k[f]:
                raise RuntimeError(f"service-account key lacks {f}")
        if k["token_uri"] not in ALLOWED_TOKEN_URIS:
            raise RuntimeError("service-account key names an unexpected token_uri")
        _key_cache = k
    return _key_cache


def service_account_client_id() -> str:
    """The SA's numeric client ID (what Google Admin's DWD entry needs). Not a secret."""
    return _load_key()["client_id"]


def _b64(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def access_token(subject: str, scopes: list[str], *, read_only: bool = False) -> str:
    _ensure()
    raw = subject
    subject = normalize_subject(subject)
    if not subject or not subject_allowed(subject):
        shown = subject or (raw[:200] if isinstance(raw, str) else type(raw).__name__)
        _audit("refused", subject=shown, reason="subject not in allowlist")
        raise Refused(f"impersonation of {shown!r} is not allowed")
    if (not isinstance(scopes, (list, tuple)) or not scopes
            or not all(isinstance(s, str) and s in SCOPES_READ.values() for s in scopes)):
        _audit("refused", subject=subject, reason="scope not configured for this company")
        raise Refused(f"scopes must be a non-empty list of {sorted(SCOPES_READ.values())}")
    scopes = list(dict.fromkeys(scopes))
    # AmForge (af_policy): from Slack, acting as Dan is allowed only when Dan asks; @ghi.gl only for Dan/Becki/Al;
    # Docs-only and system-read subjects gated by who/what is asking. All fail closed.
    try:
        if _policy is not None:
            _policy.check_dan_mailbox(subject)
            _policy.check_ghi_mailbox(subject)
        bad = [s for s in scopes if s != KNOWN_SCOPES["drive"]]
        if subject in DOCS_ONLY_SUBJECTS and not bad:
            _policy.check_docs_only_subject(subject)           # owner's own Drive/Docs
        elif subject in SYSTEM_READ_SUBJECTS:
            # read-only by default: a token for these accounts goes only to a caller that declares it reads
            if not read_only:
                raise Refused(f"{subject} is delegated to the system for reading only; ask with read_only=True")
            _policy.check_system_read_subject(subject)        # system jobs only (their own systemd unit)
        elif subject in DOCS_ONLY_SUBJECTS:
            raise Refused(f"{subject} is delegated for Drive/Docs/Sheets only; refused scopes: {bad}")
    except Exception as exc:
        _audit("refused", subject=subject, reason="af_policy: " + type(exc).__name__ + ": " + str(exc)[:200])
        raise Refused(str(exc)) from None
    ck = (COMPANY, OP_VAULT, OP_ITEM_ID, subject, tuple(sorted(scopes)))
    hit = _tok_cache.get(ck)
    if hit and hit[1] - 60 > time.time():
        return hit[0]
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding, rsa
    k = _load_key()
    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT", "kid": k["private_key_id"]}
    claims = {"iss": k["client_email"], "sub": subject, "scope": " ".join(scopes),
              "aud": k["token_uri"], "iat": now, "exp": now + 3600}
    signing_input = f"{_b64(json.dumps(header).encode())}.{_b64(json.dumps(claims).encode())}".encode()
    try:
        pk = serialization.load_pem_private_key(k["private_key"].encode(), password=None)
    except Exception:
        raise RuntimeError("service-account private key does not load") from None
    if not isinstance(pk, rsa.RSAPrivateKey):
        raise RuntimeError("service-account private key is not RSA")
    sig = pk.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
    assertion = signing_input.decode() + "." + _b64(sig)
    data = urllib.parse.urlencode({"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                                   "assertion": assertion}).encode()
    try:
        resp = json.load(_urlopen(k["token_uri"], data, timeout=30))
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")[:300]
        try:
            err = str(json.loads(body).get("error", ""))[:60]
        except Exception:
            err = ""
        _audit("token_error", subject=subject, scopes=scopes, status=e.code, detail=body)
        raise TokenError(f"token mint failed ({e.code}): {body}", e.code, err) from None
    if not isinstance(resp, dict) or not isinstance(resp.get("access_token"), str):
        raise RuntimeError("token endpoint returned no access_token")
    _audit("token_minted", subject=subject, scopes=scopes)
    _tok_cache[ck] = (resp["access_token"], time.time() + int(resp.get("expires_in", 3600)))
    return resp["access_token"]


def get(subject: str, service: str, url: str, action: str, target: str = "") -> dict:
    _ensure()
    if service not in SCOPES_READ:
        raise Refused(f"service {service!r} is not configured for {COMPANY}")
    tok = access_token(subject, [SCOPES_READ[service]], read_only=True)   # GET only, below
    _audit("api_read", subject=normalize_subject(subject), service=service, action=action, target=target[:200])
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + tok})
    try:
        return json.load(_urlopen(req, timeout=60))
    except urllib.error.HTTPError as e:
        raise ApiError(f"{service} API {e.code}: {e.read().decode(errors='replace')[:300]}", service, e.code) from None


# ---------------- Gmail helpers (read-only) ----------------
def gmail_search(subject: str, q: str, n: int = 20) -> list[dict]:
    r = get(subject, "gmail", f"{G}/messages?maxResults={n}&q=" + urllib.parse.quote(q), "gmail.search", q)
    out = []
    for m in r.get("messages", []):
        md = get(subject, "gmail", f"{G}/messages/{m['id']}?format=metadata&metadataHeaders=From"
                 "&metadataHeaders=To&metadataHeaders=Cc&metadataHeaders=Subject&metadataHeaders=Date",
                 "gmail.metadata", m["id"])
        h = {x["name"]: x["value"] for x in md["payload"]["headers"]}
        out.append({"id": m["id"], "threadId": md["threadId"], "date": h.get("Date", ""),
                    "from": h.get("From", ""), "to": h.get("To", ""), "cc": h.get("Cc", ""),
                    "subject": h.get("Subject", ""), "snippet": md.get("snippet", ""),
                    "labels": md.get("labelIds", [])})
    return out


def _walk_parts(p, texts, atts):
    mt = p.get("mimeType", "")
    if p.get("filename"):
        atts.append({"filename": p["filename"], "mimeType": mt, "size": p.get("body", {}).get("size"),
                     "attachmentId": p.get("body", {}).get("attachmentId")})
    elif mt == "text/plain" and p.get("body", {}).get("data"):
        texts.append(base64.urlsafe_b64decode(p["body"]["data"]).decode("utf-8", "ignore"))
    for c in p.get("parts", []) or []:
        _walk_parts(c, texts, atts)


def gmail_thread(subject: str, thread_id: str) -> list[dict]:
    t = get(subject, "gmail", f"{G}/threads/{thread_id}?format=full", "gmail.thread", thread_id)
    msgs = []
    for m in t.get("messages", []):
        h = {x["name"]: x["value"] for x in m["payload"]["headers"]}
        texts, atts = [], []
        _walk_parts(m["payload"], texts, atts)
        msgs.append({"id": m["id"], "date": h.get("Date", ""), "from": h.get("From", ""),
                     "to": h.get("To", ""), "cc": h.get("Cc", ""), "subject": h.get("Subject", ""),
                     "body": "\n".join(texts), "attachments": atts})
    return msgs


# ---------------- Gmail DRAFT creation (write, reversible; never sends) ----------------
def gmail_create_draft(subject: str, *, to: list[str], cc: list[str], subj: str, body: str,
                       thread_id: str | None = None, in_reply_to: str | None = None,
                       attachments: list[tuple[str, str]] | None = None) -> dict:
    """Create a Gmail DRAFT in `subject`'s mailbox. Does NOT send.
    attachments: list of (local_path, filename_to_show)."""
    _ensure()
    _refuse_system_write(subject, "gmail.draft.create")
    from email.message import EmailMessage
    msg = EmailMessage()
    msg["To"] = ", ".join(to)
    if cc:
        msg["Cc"] = ", ".join(cc)
    msg["Subject"] = subj
    if in_reply_to:
        msg["In-Reply-To"] = in_reply_to
        msg["References"] = in_reply_to
    msg.set_content(body)
    import mimetypes
    for path, name in attachments or []:
        mt = mimetypes.guess_type(name)[0] or "application/octet-stream"
        maintype, subtype = mt.split("/", 1)
        with open(path, "rb") as f:
            msg.add_attachment(f.read(), maintype=maintype, subtype=subtype, filename=name)
    raw = base64.urlsafe_b64encode(msg.as_bytes()).decode()
    payload = {"message": {"raw": raw}}
    if thread_id:
        payload["message"]["threadId"] = thread_id
    tok = access_token(subject, [SCOPES_READ["gmail"]])
    subject = normalize_subject(subject)
    _audit("gmail.draft.create", subject=subject, to=to, cc=cc, subj=subj[:150],
           thread=thread_id or "", attachments=[n for _, n in attachments or []])
    req = urllib.request.Request(f"{G}/drafts", data=json.dumps(payload).encode(), method="POST",
                                 headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
    try:
        res = json.load(_urlopen(req, timeout=60))
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"gmail draft create {e.code}: {e.read().decode(errors='replace')[:300]}") from None
    _ledger_add(subject, res["id"], res.get("message", {}).get("id", ""), to, subj)
    return res


# ---------------- Draft cleanup guard (AmForge incident 2026-10-01) ----------------
# An ad-hoc cleanup once called DELETE /drafts/{id} for every draft matching a recipient query, permanently
# destroying drafts Hermes had not created. Rules enforced here:
#   1. Only drafts recorded in DRAFT_LEDGER as created by THIS Hermes session can be removed.
#   2. Removal is by exact draft id only (no query/recipient-based bulk removal).
#   3. Removal TRASHES the underlying message (recoverable for 30 days); it never hard-deletes.
def _session_id() -> str:
    return os.environ.get("HERMES_SESSION_ID", "")


def _ledger_add(subject: str, draft_id: str, message_id: str, to, subj: str):
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "session": _session_id(),
           "subject": subject, "draft_id": draft_id, "message_id": message_id,
           "to": to, "subj": subj[:150]}
    _append_private(DRAFT_LEDGER, rec)


def _ledger_lookup(subject: str, draft_id: str) -> dict | None:
    if not DRAFT_LEDGER.exists():
        return None
    fd = _open_private(DRAFT_LEDGER, os.O_RDONLY)
    with os.fdopen(fd, "r") as f:
        text = f.read()
    hit = None
    for line in text.splitlines():
        try:
            r = json.loads(line)
        except Exception:
            continue
        if isinstance(r, dict) and r.get("draft_id") == draft_id and r.get("subject") == subject:
            hit = r
    return hit


def gmail_trash_draft(subject: str, draft_id: str) -> dict:
    """Move ONE Hermes-created draft to Trash (recoverable). Refuses anything else."""
    _ensure()
    _refuse_system_write(subject, "gmail.draft.trash")
    subject = normalize_subject(subject) or subject
    if not isinstance(draft_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", draft_id):
        raise Refused("draft id must be a plain Gmail draft id")
    rec = _ledger_lookup(subject, draft_id)
    sid = _session_id()
    if not rec:
        _audit("refused", subject=subject, action="gmail.draft.trash", draft_id=draft_id,
               reason="draft not created by Hermes (not in ledger)")
        raise Refused(f"draft {draft_id} was not created by Hermes; refusing to remove it")
    if not sid or rec.get("session") != sid:
        _audit("refused", subject=subject, action="gmail.draft.trash", draft_id=draft_id,
               reason="draft created in a different session")
        raise Refused(f"draft {draft_id} was created in another session; ask the user to remove it")
    tok = access_token(subject, [SCOPES_READ["gmail"]])
    H = {"Authorization": "Bearer " + tok}
    d = json.load(_urlopen(urllib.request.Request(f"{G}/drafts/{draft_id}?format=minimal", headers=H), timeout=60))
    mid = d["message"]["id"]
    _audit("gmail.draft.trash", subject=subject, draft_id=draft_id, message_id=mid, subj=rec.get("subj", ""))
    req = urllib.request.Request(f"{G}/messages/{mid}/trash", data=b"", method="POST", headers=H)
    return json.load(_urlopen(req, timeout=60))


# ---------------- Calendar event creation (write) ----------------
def calendar_create_event(subject: str, *, summary: str, start: str, end: str, tz: str,
                          attendees: list[str], description: str = "", with_meet: bool = True,
                          send_updates: str = "none", visibility: str = "default") -> dict:
    """Create an event on `subject`'s primary calendar. send_updates: none|externalOnly|all.
    Default 'none' = no invitation emails go out (a separate explicit step issues them)."""
    _ensure()
    _refuse_system_write(subject, "calendar.event.create")
    if send_updates not in ("none", "externalOnly", "all"):
        raise Refused("send_updates must be none|externalOnly|all")
    import uuid
    ev = {"summary": summary, "description": description, "visibility": visibility,
          "start": {"dateTime": start, "timeZone": tz}, "end": {"dateTime": end, "timeZone": tz},
          "attendees": [{"email": a} for a in attendees], "guestsCanSeeOtherGuests": True}
    if with_meet:
        ev["conferenceData"] = {"createRequest": {"requestId": uuid.uuid4().hex,
                                                  "conferenceSolutionKey": {"type": "hangoutsMeet"}}}
    tok = access_token(subject, [SCOPES_READ["calendar"]])
    _audit("calendar.event.create", subject=normalize_subject(subject), summary=summary[:150], start=start,
           attendees=attendees, send_updates=send_updates)
    url = ("https://www.googleapis.com/calendar/v3/calendars/primary/events?conferenceDataVersion=1"
           f"&sendUpdates={send_updates}")
    req = urllib.request.Request(url, data=json.dumps(ev).encode(), method="POST",
                                 headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
    try:
        return json.load(_urlopen(req, timeout=60))
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"calendar create {e.code}: {e.read().decode(errors='replace')[:300]}") from None


def calendar_send_invites(subject: str, event_id: str) -> dict:
    """Issue invitations for an event created with send_updates='none'.
    Removes guests silently, then re-adds them with sendUpdates=all so each
    receives a real invitation (a no-op PATCH does not reliably notify)."""
    _ensure()
    _refuse_system_write(subject, "calendar.invites.send")
    tok = access_token(subject, [SCOPES_READ["calendar"]])
    base = "https://www.googleapis.com/calendar/v3/calendars/primary/events/" + urllib.parse.quote(event_id, safe="")
    hdr = {"Authorization": "Bearer " + tok, "Content-Type": "application/json"}
    ev = json.load(_urlopen(urllib.request.Request(base, headers=hdr), timeout=60))
    guests = [{"email": a["email"]} for a in ev.get("attendees", []) if not a.get("self")]
    _audit("calendar.invites.send", subject=normalize_subject(subject), event_id=event_id,
           attendees=[g["email"] for g in guests])

    def _patch(body, updates):
        r = urllib.request.Request(f"{base}?sendUpdates={updates}&conferenceDataVersion=1",
                                   data=json.dumps(body).encode(), method="PATCH", headers=hdr)
        try:
            return json.load(_urlopen(r, timeout=60))
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"calendar patch {e.code}: {e.read().decode(errors='replace')[:300]}") from None
    _patch({"attendees": []}, "none")
    return _patch({"attendees": guests}, "all")


# ---------------- Drive sharing (write) ----------------
def drive_share(subject: str, file_id: str, emails: list[str], role: str = "writer",
                notify: bool = False) -> list[dict]:
    """Share a Drive file with specific people (never 'anyone'/domain links)."""
    _ensure()
    _refuse_system_write(subject, "drive.share", drive=True)
    if role not in ("reader", "commenter", "writer"):
        raise Refused("role must be reader|commenter|writer")
    tok = access_token(subject, [KNOWN_SCOPES["drive"]])
    out = []
    for e in emails:
        body = json.dumps({"type": "user", "role": role, "emailAddress": e}).encode()
        url = (f"https://www.googleapis.com/drive/v3/files/{urllib.parse.quote(file_id, safe='')}/permissions"
               f"?sendNotificationEmail={'true' if notify else 'false'}&supportsAllDrives=true"
               f"&fields=id,emailAddress,role")
        req = urllib.request.Request(url, data=body, method="POST",
                                     headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
        out.append(json.load(_urlopen(req, timeout=60)))
    _audit("drive.share", subject=normalize_subject(subject), file_id=file_id, emails=emails, role=role,
           notify=notify)
    return out


def main(argv=None):
    import argparse
    _ensure()
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["search", "thread", "whoami"])
    ap.add_argument("arg", nargs="?", default="")
    ap.add_argument("--as", dest="subject", default=SMOKE_SUBJECT)
    ap.add_argument("-n", type=int, default=20)
    a = ap.parse_args(argv)
    if a.cmd == "whoami":
        print(json.dumps(get(a.subject, "gmail", f"{G}/profile", "gmail.profile"), indent=1))
    elif a.cmd == "search":
        print(json.dumps(gmail_search(a.subject, a.arg, a.n), indent=1))
    else:
        print(json.dumps(gmail_thread(a.subject, a.arg), indent=1))


if __name__ == "__main__":
    main()
