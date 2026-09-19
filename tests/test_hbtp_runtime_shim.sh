#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }

mkdir -p "$TMP/bin" "$TMP/home/hermes/.local/bin"

cat >"$TMP/bin/id" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-u hermes") printf '1000\n' ;;
  "-u") printf '0\n' ;;
  *) exit 2 ;;
esac
SH

cat >"$TMP/bin/runuser" <<SH
#!/usr/bin/env bash
RUNUSER_LOG="$TMP/runuser.json"
python3 - "\$RUNUSER_LOG" "\$@" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(sys.argv[2:], fh)
PY

args=("\$@")
for i in "\${!args[@]}"; do
  if [[ "\${args[\$i]}" == "--" ]]; then
    exec "\${args[@]:\$((i + 1))}"
  fi
done
exit 64
SH
chmod +x "$TMP/bin/id" "$TMP/bin/runuser"

fake_hermes="$TMP/fake hermes"
cat >"$fake_hermes" <<SH
#!/usr/bin/env bash
python3 - "$TMP/hermes.json" "\$@" <<'PY'
import json
import os
import sys

data = {
    "argv": sys.argv[2:],
    "cwd": os.getcwd(),
    "env": dict(os.environ),
}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, sort_keys=True)
PY
SH
chmod +x "$fake_hermes"

runuser_log="$TMP/runuser.json"
HBTP_RUNUSER_BIN="$TMP/bin/runuser" \
HBTP_ID_BIN="$TMP/bin/id" \
HBTP_HERMES_BIN="$fake_hermes" \
HBTP_HERMES_CWD="$TMP/home/hermes" \
TERM=xterm-256color \
COLORTERM=truecolor \
LANG=C.UTF-8 \
LC_CTYPE=C.UTF-8 \
TZ=UTC \
HERDR_ENV=1 \
HERDR_SESSION='ws "quoted" space' \
HERDR_PANE_ID='pane 1' \
HERDR_SOCKET_PATH='/tmp/herdr socket' \
HERDR_BIN_PATH='/root/.local/bin/herdr' \
NO_TMUX=1 \
AWS_SECRET_ACCESS_KEY=sentinel \
GOOGLE_APPLICATION_CREDENTIALS=/root/secret.json \
OPENAI_API_KEY=sentinel \
DEEPAPI_API_KEY=sentinel \
ROOT_SERVICE_TOKEN=sentinel \
SSH_AUTH_SOCK=/tmp/root-agent.sock \
HERMES_HOME=/root/.hermes \
  "$ROOT/scripts/h-btp-hermes-cli.sh" \
  chat --source 'pane:H 1' --resume 'sess "quoted"' 'semi;colon' 'two words'

python3 - "$runuser_log" "$TMP/hermes.json" "$TMP/home/hermes" <<'PY'
import json
import os
import sys

runuser_args = json.load(open(sys.argv[1], encoding="utf-8"))
data = json.load(open(sys.argv[2], encoding="utf-8"))
expected_cwd = sys.argv[3]

assert runuser_args[:3] == ["-u", "hermes", "--"], runuser_args
for forbidden in ("-", "-l", "--login", "-c", "--command", "--session-command", "-P", "--pty"):
    assert forbidden not in runuser_args[:3], runuser_args
assert data["argv"] == [
    "chat",
    "--source",
    "pane:H 1",
    "--resume",
    'sess "quoted"',
    "semi;colon",
    "two words",
]
assert data["cwd"] == expected_cwd
env = data["env"]
assert env["HOME"] == "/home/hermes"
assert env["USER"] == "hermes"
assert env["LOGNAME"] == "hermes"
assert env["HERMES_HOME"] == "/home/hermes/.hermes"
assert env["HERDR_BIN_PATH"] == "/home/hermes/.local/bin/herdr"
assert env["PATH"] == "/home/hermes/.local/bin:/usr/local/bin:/usr/bin:/bin"
assert env["TERM"] == "xterm-256color"
assert env["COLORTERM"] == "truecolor"
assert env["LANG"] == "C.UTF-8"
assert env["LC_CTYPE"] == "C.UTF-8"
assert env["TZ"] == "UTC"
assert env["HERDR_ENV"] == "1"
assert env["HERDR_SESSION"] == 'ws "quoted" space'
assert env["HERDR_PANE_ID"] == "pane 1"
assert env["HERDR_SOCKET_PATH"] == "/tmp/herdr socket"
assert env["NO_TMUX"] == "1"
for forbidden in (
    "AWS_SECRET_ACCESS_KEY",
    "GOOGLE_APPLICATION_CREDENTIALS",
    "OPENAI_API_KEY",
    "DEEPAPI_API_KEY",
    "ROOT_SERVICE_TOKEN",
    "SSH_AUTH_SOCK",
):
    assert forbidden not in env, forbidden
assert not any(key.startswith("HBTP_") for key in env), sorted(env)
PY

root_shim="$TMP/root-bin/hermes"
mkdir -p "$(dirname "$root_shim")"
cat >"$root_shim" <<'SH'
#!/usr/bin/env bash
printf 'root shim should not be used\n' >&2
exit 99
SH
chmod +x "$root_shim"

cat >"$TMP/home/hermes/.local/bin/hermes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP/home/hermes/.local/bin/hermes"

generic_pane="$TMP/generic hermes-pane"
cat >"$generic_pane" <<SH
#!/usr/bin/env bash
python3 - "$TMP/pane.json" "\$@" <<'PY'
import json
import os
import shutil
import sys

data = {
    "argv": sys.argv[2:],
    "cwd": os.getcwd(),
    "home": os.environ.get("HOME"),
    "hermes_home": os.environ.get("HERMES_HOME"),
    "path": os.environ.get("PATH"),
    "resolved_hermes": shutil.which("hermes"),
}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(data, fh, sort_keys=True)
PY
SH
chmod +x "$generic_pane"

runuser_log="$TMP/runuser.json"
HBTP_RUNUSER_BIN="$TMP/bin/runuser" \
HBTP_ID_BIN="$TMP/bin/id" \
HBTP_GENERIC_HERMES_PANE="$generic_pane" \
HBTP_HERMES_PATH="$TMP/home/hermes/.local/bin:/usr/local/bin:/usr/bin:/bin" \
HBTP_HERMES_CWD="$TMP/home/hermes" \
PATH="$TMP/root-bin:/usr/local/bin:/usr/bin:/bin" \
HERDR_SESSION=ws \
HERDR_PANE_ID=pane-2 \
  "$ROOT/scripts/h-btp-hermes-pane" 'H 1' 'fresh arg'

python3 - "$runuser_log" "$TMP/pane.json" "$generic_pane" "$TMP/home/hermes/.local/bin/hermes" "$TMP/home/hermes" <<'PY'
import json
import sys

runuser_args = json.load(open(sys.argv[1], encoding="utf-8"))
data = json.load(open(sys.argv[2], encoding="utf-8"))
generic_pane = sys.argv[3]
expected_hermes = sys.argv[4]
expected_cwd = sys.argv[5]

assert runuser_args[:3] == ["-u", "hermes", "--"], runuser_args
assert generic_pane in runuser_args, runuser_args
for forbidden in ("-", "-l", "--login", "-c", "--command", "--session-command", "-P", "--pty"):
    assert forbidden not in runuser_args[:3], runuser_args
assert data["argv"] == ["H 1", "fresh arg"]
assert data["cwd"] == expected_cwd
assert data["home"] == "/home/hermes"
assert data["hermes_home"] == "/home/hermes/.hermes"
assert data["resolved_hermes"] == expected_hermes
assert data["path"].startswith(expected_hermes.rsplit("/", 1)[0] + ":")
PY

bash -n "$ROOT/scripts/h-btp-hermes-cli.sh"
bash -n "$ROOT/scripts/h-btp-hermes-pane"

pass "h-btp runtime bridge preserves argv, safe environment, and pane delegation"
