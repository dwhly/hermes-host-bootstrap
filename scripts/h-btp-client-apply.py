import datetime, hashlib, json, os, pathlib, re, shutil, subprocess, sys, tempfile
host, mode, stage_arg = sys.argv[1:4]
expected = {"h-mini": "/Users/dan_1", "h-air": "/Users/danz"}
home = pathlib.Path.home()
assert str(home) == expected[host] and os.getuid() != 0
assert subprocess.check_output(["hostname"], text=True).strip().removesuffix(".local") == host
stage = pathlib.Path(stage_arg)
sshdir = home / ".ssh"
sshdir.mkdir(mode=0o700, exist_ok=True)
key = sshdir / ("macadm_archive_ed25519" if host == "h-mini" else "id_ed25519_hbtp")
pub = pathlib.Path(str(key) + ".pub")
if mode == "key":
    if host == "h-air" and not key.exists() and not pub.exists():
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key), "-C", "h-air-to-h-btp"], check=True)
    assert key.is_file() and pub.is_file(), "Selected keypair unavailable; no alternate key created"
    fingerprint = subprocess.check_output(["ssh-keygen", "-lf", str(pub)], text=True).split()[1]
    if host == "h-mini":
        assert fingerprint == "SHA256:XupsPNXWXhS9b588jBTbNydDNKRV9wxmRQKub1ROezY"
    check = subprocess.run(["ssh-keygen", "-y", "-P", "", "-f", str(key)], text=True, capture_output=True, timeout=10)
    assert check.returncode == 0, "Selected key needs local unlock or repair; no value printed"
    assert check.stdout.split()[:2] == pub.read_text().split()[:2]
    assert key.stat().st_mode & 0o077 == 0, "Private key permissions too broad"
    print(json.dumps({"host": host, "private_key_path": str(key), "public_key_path": str(pub), "fingerprint": fingerprint, "password_required": False}))
    raise SystemExit(0)
assert mode == "apply" and key.is_file() and pub.is_file()
payload = json.loads((stage / "payload.json").read_text())
config = home / ".hermes/config.yaml"
config_before = config.read_bytes()
backup = home / ".hermes-backups" / ("hbtp-direct-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"))
backup.mkdir(parents=True, mode=0o700)
manifest = {}
def save_write(path, data, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() or path.is_symlink():
        name = str(len(manifest))
        if path.is_symlink():
            manifest[str(path)] = {"symlink": os.readlink(path)}
        else:
            shutil.copy2(path, backup / name)
            manifest[str(path)] = {"backup": name}
    else:
        manifest[str(path)] = {"absent": True}
    (backup / "manifest.json").write_text(json.dumps(manifest, indent=2))
    fd, temporary = tempfile.mkstemp(prefix=".hbtp-stage-", dir=path.parent)
    with os.fdopen(fd, "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, mode)
    os.replace(temporary, path)
master = home / ".hermes/fleet/hosts.yaml"
old = master.read_text() if master.exists() else payload["master_full"]
pattern = r"^  - hostname: h-btp\n.*?(?=^  - hostname:|\Z)"
matches = re.findall(pattern, old, re.M | re.S)
assert len(matches) <= 1
if matches:
    updated = re.sub(pattern, lambda _: payload["master_block"], old, flags=re.M | re.S)
else:
    assert re.search(r"^hosts:\s*$", old, re.M)
    updated = old.rstrip("\n") + "\n\n" + payload["master_block"]
save_write(master, updated.encode(), 0o600)
save_write(home / ".hermes/hosts/h-btp.yaml", payload["snapshot"].encode(), 0o600)
trusted = payload["known_hosts"].strip()
assert trusted.split()[0] == "100.127.149.96,h-btp,h-btp.tailb554cd.ts.net"
known = sshdir / "known_hosts"
existing = known.read_text() if known.exists() else ""
if known.exists():
    for alias in trusted.split()[0].split(","):
        found = subprocess.run(["ssh-keygen", "-F", alias, "-f", str(known)], text=True, capture_output=True)
        for line in found.stdout.splitlines():
            if not line or line.startswith("#"):
                continue
            bits = line.split()
            if bits[1] == trusted.split()[1]:
                assert bits[2] == trusted.split()[2], "Existing target host key conflicts; manual review required"
if trusted not in existing.splitlines():
    save_write(known, (existing.rstrip("\n") + "\n" + trusted + "\n").lstrip("\n").encode(), 0o600)
sshconfig = sshdir / "config"
original = sshconfig.read_text() if sshconfig.exists() else ""
start, end = "# BEGIN HERMES H-BTP DIRECT ACCESS", "# END HERMES H-BTP DIRECT ACCESS"
assert original.count(start) == original.count(end) <= 1
clean = re.sub(re.escape(start) + r".*?" + re.escape(end) + r"\n?", "", original, flags=re.S)
block = f"{start}\nHost h-btp h-btp.tailb554cd.ts.net 100.127.149.96\n    HostName 100.127.149.96\n    User root\n    IdentityFile {key}\n    IdentitiesOnly yes\n    IdentityAgent none\n    ForwardAgent no\n    ProxyCommand none\n    ProxyJump none\n    StrictHostKeyChecking yes\nHost *\n{end}\n"
save_write(sshconfig, (block + clean).encode(), 0o600)
for name, checksum in payload["helpers"].items():
    content = (stage / name).read_bytes()
    assert hashlib.sha256(content).hexdigest() == checksum
    save_write(home / ".local/bin" / name, content, 0o755)
assert config.read_bytes() == config_before, "Concurrent runtime config change; inspect before continuing"
assert re.findall(pattern, master.read_text(), re.M | re.S) == [payload["master_block"]]
print(json.dumps({"host": host, "backup": str(backup), "runtime_config_unchanged": True, "helpers": payload["helpers"]}))
