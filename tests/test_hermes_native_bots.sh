#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER="$ROOT/scripts/hermes-native-bots"
MODULE="$ROOT/lib/98-hermes-native-bots.sh"
VERIFY="$ROOT/verify.sh"
TMP="$(mktemp -d)"
VERIFY_API_FIXTURE_PIDS=()
cleanup() {
  if ((${#VERIFY_API_FIXTURE_PIDS[@]})); then
    kill "${VERIFY_API_FIXTURE_PIDS[@]}" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}
start_verify_api_fixture() {
  local mode port_file pid
  mode="$1"
  port_file="$TMP/verify-api-${mode}.port"
  rm -f "$port_file"
  python3 - "$port_file" "$mode" <<'PY' &
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port_file, mode = sys.argv[1:3]
key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, status, body):
        if isinstance(body, dict):
            body = json.dumps(body, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.headers.get("Authorization") != f"Bearer {key}":
            self._send(401, {"error": "unauthorized"})
            return
        if self.path == "/v1/capabilities":
            if mode == "large_caps":
                self._send(200, {"object": "hermes.api_server.capabilities", "padding": "x" * 8192})
            elif mode == "wrong_caps_object":
                self._send(200, {"object": "not.hermes.capabilities"})
            elif mode == "overlength_caps":
                body = b'{"object":"hermes.api_server.capabilities","padding":"' + (b"x" * (1024 * 1024 + 1)) + b'"}'
                self._send(200, body)
            else:
                self._send(200, {"object": "hermes.api_server.capabilities"})
            return
        if self.path == "/v1/models":
            if mode == "wrong_models_object":
                self._send(200, {"object": "not-a-list"})
            else:
                self._send(200, {"object": "list", "data": []})
            return
        self._send(404, {"error": "not_found"})

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="utf-8") as fh:
    fh.write(str(server.server_port))
server.serve_forever()
PY
  pid="$!"
  VERIFY_API_FIXTURE_PIDS+=("$pid")
  for _ in {1..50}; do
    [[ -s "$port_file" ]] && return 0
    sleep 0.1
  done
  fail "verify-api fixture did not start for $mode"
}

bash -n "$HELPER" "$MODULE" "$VERIFY" "$ROOT/lib/99-register-host.sh"

grep -q 'role_includes client' "$MODULE" || fail "Desktop role gate missing"
grep -q 'find_tailscale' "$MODULE" || fail "module must use common tailscale resolver"
grep -q 'configure-api --host "$tailscale_ip" --port 8642' "$MODULE" || fail "module must pass explicit tailnet bind to helper"
grep -q '<string>/usr/bin/open</string>' "$HELPER" || fail "Desktop LaunchAgent must use exact /usr/bin/open"
! grep -q '<key>KeepAlive</key>' "$HELPER" || fail "Desktop LaunchAgent must not use KeepAlive"
grep -q 'API_SERVER_CORS_ORIGINS' "$HELPER" && fail "helper must not expand CORS"

home="$TMP/home"
hermes_home="$home/.hermes"
mkdir -p "$hermes_home"
cat >"$hermes_home/.env" <<'ENV'
UNRELATED=keep-me
API_SERVER_KEY=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SLACK_BOT_TOKEN=preserve
ENV
chmod 600 "$hermes_home/.env"

out="$(HOME="$home" HERMES_HOME="$hermes_home" HERMES_NATIVE_BOTS_TAILSCALE_IP=100.64.1.2 "$HELPER" configure-api --host 100.64.1.2 --port 8642)"
key="$(awk -F= '/^API_SERVER_KEY=/ {print $2}' "$hermes_home/.env")"
[[ "$key" == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]] || fail "existing valid API key was not preserved"
grep -qx 'UNRELATED=keep-me' "$hermes_home/.env" || fail "unrelated .env value lost"
grep -qx 'SLACK_BOT_TOKEN=preserve' "$hermes_home/.env" || fail "unrelated token lost"
grep -qx 'API_SERVER_ENABLED=true' "$hermes_home/.env" || fail "API server was not enabled"
grep -qx 'API_SERVER_HOST=100.64.1.2' "$hermes_home/.env" || fail "API server host not set to tailnet IP"
grep -qx 'API_SERVER_PORT=8642' "$hermes_home/.env" || fail "API server port not set"
! grep -q "$key" <<<"$out" || fail "configure receipt leaked API key"
grep -q '"restart_pending":true' <<<"$out" || fail "configure receipt did not report pending restart"
grep -q 'hermes-native-bots apply-api' <<<"$out" || fail "configure receipt missing safe reapply path"

before="$(cat "$hermes_home/.env")"
out2="$(HOME="$home" HERMES_HOME="$hermes_home" HERMES_NATIVE_BOTS_TAILSCALE_IP=100.64.1.2 "$HELPER" configure-api --host 100.64.1.2 --port 8642)"
after="$(cat "$hermes_home/.env")"
[[ "$before" == "$after" ]] || fail "configure-api is not idempotent"
grep -q '"config_changed":false' <<<"$out2" || fail "idempotent receipt did not report unchanged config"

chmod 0644 "$hermes_home/.env"
out_mode="$(HOME="$home" HERMES_HOME="$hermes_home" HERMES_NATIVE_BOTS_TAILSCALE_IP=100.64.1.2 "$HELPER" configure-api --host 100.64.1.2 --port 8642)"
grep -q '"config_changed":false' <<<"$out_mode" || fail "mode-only idempotent configure reported content changed"
[[ "$(file_mode "$hermes_home/.env")" == "600" ]] || fail "idempotent configure did not tighten .env mode"
[[ -z "$(find "$hermes_home" -maxdepth 1 -name '.env.*' -print -quit)" ]] || fail "secure env rewrite left temporary files"

quoted_home="$TMP/quoted"
mkdir -p "$quoted_home/.hermes"
printf 'UNRELATED=no-newline' >"$quoted_home/.hermes/.env"
outq="$(HOME="$quoted_home" HERMES_HOME="$quoted_home/.hermes" HERMES_NATIVE_BOTS_TAILSCALE_IP=100.64.1.8 "$HELPER" configure-api --host 100.64.1.8 --port 8642)"
grep -qx 'UNRELATED=no-newline' "$quoted_home/.hermes/.env" || fail "non-managed unterminated line was not preserved"
grep -qx 'API_SERVER_HOST=100.64.1.8' "$quoted_home/.hermes/.env" || fail "managed block merged onto unterminated line"
! grep -q "$(awk -F= '/^API_SERVER_KEY=/ {print $2}' "$quoted_home/.hermes/.env")" <<<"$outq" || fail "generated API key leaked"

export_home="$TMP/export"
mkdir -p "$export_home/.hermes"
cat >"$export_home/.hermes/.env" <<'ENV'
export API_SERVER_KEY="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" # preserve parsed key
OTHER_VALUE="kept # literally"
ENV
HOME="$export_home" HERMES_HOME="$export_home/.hermes" HERMES_NATIVE_BOTS_TAILSCALE_IP=100.64.1.9 "$HELPER" configure-api --host 100.64.1.9 --port 8642 >/tmp/native-bots-export.out
grep -qx 'API_SERVER_KEY=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$export_home/.hermes/.env" || fail "export/quoted API key was not parsed and preserved"
grep -qx 'OTHER_VALUE="kept # literally"' "$export_home/.hermes/.env" || fail "quoted unrelated dotenv value changed"

dup_home="$TMP/dup"
mkdir -p "$dup_home/.hermes"
cat >"$dup_home/.hermes/.env" <<'ENV'
API_SERVER_KEY=cccccccccccccccccccccccccccccccc
export API_SERVER_KEY="dddddddddddddddddddddddddddddddd"
ENV
if HOME="$dup_home" HERMES_HOME="$dup_home/.hermes" HERMES_NATIVE_BOTS_TAILSCALE_IP=100.64.1.10 "$HELPER" configure-api --host 100.64.1.10 --port 8642 >/tmp/native-bots-dup.out 2>&1; then
  fail "conflicting duplicate API_SERVER_KEY did not block"
fi
grep -q 'duplicate_managed_key' /tmp/native-bots-dup.out || fail "duplicate key refusal did not identify ambiguity"

config_fallback="$TMP/config-fallback"
mkdir -p "$config_fallback/.hermes"
cat >"$config_fallback/.hermes/config.yaml" <<'YAML'
api_server:
  key: eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
YAML
HOME="$config_fallback" HERMES_HOME="$config_fallback/.hermes" HERMES_NATIVE_BOTS_TAILSCALE_IP=100.64.1.11 "$HELPER" configure-api --host 100.64.1.11 --port 8642 >/tmp/native-bots-config-fallback.out
grep -qx 'API_SERVER_KEY=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' "$config_fallback/.hermes/.env" || fail "gateway config API key fallback not preserved"

config_conflict="$TMP/config-conflict"
mkdir -p "$config_conflict/.hermes"
printf 'API_SERVER_KEY=ffffffffffffffffffffffffffffffff\n' >"$config_conflict/.hermes/.env"
cat >"$config_conflict/.hermes/config.yaml" <<'YAML'
api_server:
  key: 99999999999999999999999999999999
YAML
if HOME="$config_conflict" HERMES_HOME="$config_conflict/.hermes" HERMES_NATIVE_BOTS_TAILSCALE_IP=100.64.1.12 "$HELPER" configure-api --host 100.64.1.12 --port 8642 >/tmp/native-bots-config-conflict.out 2>&1; then
  fail "conflicting gateway config API key did not block"
fi
grep -q 'key_conflict' /tmp/native-bots-config-conflict.out || fail "config key conflict refusal missing"

blank_home="$TMP/blank"
mkdir -p "$blank_home/.hermes"
printf 'API_SERVER_KEY=\n' >"$blank_home/.hermes/.env"
chmod 600 "$blank_home/.hermes/.env"
if HOME="$blank_home" HERMES_NATIVE_BOTS_TAILSCALE_IP=100.64.1.3 "$HELPER" configure-api --host 100.64.1.3 --port 8642 >/tmp/native-bots-blank.out 2>&1; then
  fail "blank existing API_SERVER_KEY did not block"
fi
grep -q 'insecure_key' /tmp/native-bots-blank.out || fail "blank key refusal did not identify insecure_key"

symlink_home="$TMP/symlink"
mkdir -p "$symlink_home/.hermes"
ln -s "$TMP/not-real-env" "$symlink_home/.hermes/.env"
if HOME="$symlink_home" HERMES_NATIVE_BOTS_TAILSCALE_IP=100.64.1.4 "$HELPER" configure-api --host 100.64.1.4 --port 8642 >/tmp/native-bots-symlink.out 2>&1; then
  fail "symlink .env was edited"
fi
grep -q 'unsafe_env' /tmp/native-bots-symlink.out || fail "symlink refusal did not identify unsafe_env"

bad_host_home="$TMP/bad-host"
mkdir -p "$bad_host_home/.hermes"
if HOME="$bad_host_home" "$HELPER" configure-api --host 0.0.0.0 --port 8642 >/tmp/native-bots-bad-host.out 2>&1; then
  fail "wildcard API bind accepted"
fi
[[ ! -e "$bad_host_home/.hermes/.env" ]] || fail "bad host path created .env"
grep -q 'invalid_host' /tmp/native-bots-bad-host.out || fail "bad host refusal missing"

wrong_host_home="$TMP/wrong-host"
mkdir -p "$wrong_host_home/.hermes"
if HOME="$wrong_host_home" HERMES_NATIVE_BOTS_TAILSCALE_IP=100.64.1.99 "$HELPER" configure-api --host 100.64.1.98 --port 8642 >/tmp/native-bots-wrong-host.out 2>&1; then
  fail "non-local tailnet API bind accepted"
fi
grep -q 'must match the local Tailscale IPv4' /tmp/native-bots-wrong-host.out || fail "local tailscale validation refusal missing"

lock_home="$TMP/lock"
mkdir -p "$lock_home/.hermes/.native-bots-env.lock"
if HOME="$lock_home" HERMES_NATIVE_BOTS_TAILSCALE_IP=100.64.1.13 "$HELPER" configure-api --host 100.64.1.13 --port 8642 >/tmp/native-bots-lock.out 2>&1; then
  fail "existing env edit lock did not block"
fi
grep -q 'env_locked' /tmp/native-bots-lock.out || fail "lock refusal missing"

symlink_runtime_parent="$TMP/symlink-parent"
mkdir -p "$symlink_runtime_parent/real-parent"
ln -s "$symlink_runtime_parent/real-parent" "$symlink_runtime_parent/linked-parent"
if HOME="$symlink_runtime_parent/home" HERMES_HOME="$symlink_runtime_parent/linked-parent/.hermes" HERMES_NATIVE_BOTS_TAILSCALE_IP=100.64.1.14 "$HELPER" configure-api --host 100.64.1.14 --port 8642 >/tmp/native-bots-symlink-parent.out 2>&1; then
  fail "symlink runtime parent did not block"
fi
grep -q 'unsafe_home' /tmp/native-bots-symlink-parent.out || fail "symlink parent refusal missing"

owner_home="$TMP/wrong-owner"
mkdir -p "$owner_home/home/.hermes"
if chown 65534 "$owner_home/home/.hermes" 2>/dev/null; then
  if HOME="$owner_home/home" HERMES_NATIVE_BOTS_TAILSCALE_IP=100.64.1.16 "$HELPER" configure-api --host 100.64.1.16 --port 8642 >/tmp/native-bots-owner.out 2>&1; then
    fail "wrong-owned runtime home did not block"
  fi
  grep -q 'unsafe_home' /tmp/native-bots-owner.out || fail "wrong-owner refusal missing"
fi

restart="$TMP/restart"
mkdir -p "$restart/home/.hermes" "$restart/bin"
cat >"$restart/bin/hermes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "hermes $*" >>"$HERMES_RESTART_LOG"
case "$*" in
  "gateway status") exit 0 ;;
  "gateway restart") exit 0 ;;
  *) exit 91 ;;
esac
SH
chmod +x "$restart/bin/hermes"
HERMES_RESTART_LOG="$restart/log" HOME="$restart/home" HERMES_HOME="$restart/home/.hermes" HERMES_NATIVE_BOTS_HERMES_BIN="$restart/bin/hermes" HERMES_NATIVE_BOTS_TAILSCALE_IP=100.64.1.15 HERMES_NATIVE_BOTS_API_VERIFY_ATTEMPTS=1 HERMES_NATIVE_BOTS_API_PROBE_TIMEOUT=0.1 "$HELPER" configure-api --host 100.64.1.15 --port 8642 --restart-gateway >/tmp/native-bots-restart.out
grep -qx 'hermes gateway status' "$restart/log" || fail "restart did not check native gateway status"
grep -qx 'hermes gateway restart' "$restart/log" || fail "restart did not use native hermes gateway restart"
grep -q '"restart_pending":true' /tmp/native-bots-restart.out || fail "restart receipt cleared pending before live verification"
grep -q '"restart_status":"restart-requested"' /tmp/native-bots-restart.out || fail "restart receipt did not report restart-requested"

apply_restart="$TMP/apply-restart"
mkdir -p "$apply_restart/home/.hermes" "$apply_restart/bin"
cat >"$apply_restart/bin/hermes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "hermes $*" >>"$HERMES_RESTART_LOG"
case "$*" in
  "gateway status") exit 0 ;;
  "gateway restart") printf 'restart requested\n'; exit 0 ;;
  *) exit 91 ;;
esac
SH
chmod +x "$apply_restart/bin/hermes"
HOME="$apply_restart/home" HERMES_HOME="$apply_restart/home/.hermes" HERMES_NATIVE_BOTS_TAILSCALE_IP=100.64.1.17 "$HELPER" configure-api --host 100.64.1.17 --port 8642 >/tmp/native-bots-apply-configure.out
HERMES_RESTART_LOG="$apply_restart/log" HOME="$apply_restart/home" HERMES_HOME="$apply_restart/home/.hermes" HERMES_NATIVE_BOTS_HERMES_BIN="$apply_restart/bin/hermes" HERMES_NATIVE_BOTS_TAILSCALE_IP=100.64.1.17 HERMES_NATIVE_BOTS_API_VERIFY_ATTEMPTS=1 HERMES_NATIVE_BOTS_API_PROBE_TIMEOUT=0.1 "$HELPER" apply-api >/tmp/native-bots-apply.out
grep -qx 'hermes gateway status' "$apply_restart/log" || fail "apply-api did not check native gateway status"
grep -qx 'hermes gateway restart' "$apply_restart/log" || fail "apply-api did not use native hermes gateway restart"
grep -q '"restart_pending":true' /tmp/native-bots-apply.out || fail "apply-api cleared pending before live verification"
grep -q '"status":"restart-requested"' /tmp/native-bots-apply.out || fail "apply-api claimed applied before live verification"
grep -q '"restart_pending":true' "$apply_restart/home/.hermes/runtime/native-bots-api-state.json" || fail "apply-api persisted cleared pending before live verification"

verify_live="$TMP/verify-live"
mkdir -p "$verify_live/home/.hermes"
start_verify_api_fixture large_caps
cat >"$verify_live/home/.hermes/.env" <<ENV
API_SERVER_HOST=127.0.0.1
API_SERVER_PORT=$(cat "$TMP/verify-api-large_caps.port")
API_SERVER_KEY=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ENV
verify_large_out="$(HOME="$verify_live/home" HERMES_HOME="$verify_live/home/.hermes" HERMES_NATIVE_BOTS_API_PROBE_TIMEOUT=1 "$HELPER" verify-api)" \
  || fail "verify-api rejected large valid capabilities response"
grep -q '"ok":true' <<<"$verify_large_out" || fail "large capabilities verification was not ok"
grep -q '"capabilities_authenticated":true' <<<"$verify_large_out" || fail "large capabilities contract was not accepted"
grep -q '"models_authenticated":true' <<<"$verify_large_out" || fail "models contract was not accepted with large capabilities"

start_verify_api_fixture wrong_caps_object
cat >"$verify_live/home/.hermes/.env" <<ENV
API_SERVER_HOST=127.0.0.1
API_SERVER_PORT=$(cat "$TMP/verify-api-wrong_caps_object.port")
API_SERVER_KEY=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ENV
if wrong_caps_out="$(HOME="$verify_live/home" HERMES_HOME="$verify_live/home/.hermes" HERMES_NATIVE_BOTS_API_PROBE_TIMEOUT=1 "$HELPER" verify-api 2>/tmp/native-bots-wrong-caps.err)"; then
  fail "verify-api accepted wrong capabilities object"
fi
grep -q '"ok":false' <<<"$wrong_caps_out" || fail "wrong capabilities object did not mark receipt failed"
grep -q '"capabilities_authenticated":false' <<<"$wrong_caps_out" || fail "wrong capabilities object did not fail contract"
grep -q '"models_authenticated":true' <<<"$wrong_caps_out" || fail "wrong capabilities fixture should keep models valid"

start_verify_api_fixture wrong_models_object
cat >"$verify_live/home/.hermes/.env" <<ENV
API_SERVER_HOST=127.0.0.1
API_SERVER_PORT=$(cat "$TMP/verify-api-wrong_models_object.port")
API_SERVER_KEY=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ENV
if wrong_models_out="$(HOME="$verify_live/home" HERMES_HOME="$verify_live/home/.hermes" HERMES_NATIVE_BOTS_API_PROBE_TIMEOUT=1 "$HELPER" verify-api 2>/tmp/native-bots-wrong-models.err)"; then
  fail "verify-api accepted wrong models object"
fi
grep -q '"ok":false' <<<"$wrong_models_out" || fail "wrong models object did not mark receipt failed"
grep -q '"capabilities_authenticated":true' <<<"$wrong_models_out" || fail "wrong models fixture should keep capabilities valid"
grep -q '"models_authenticated":false' <<<"$wrong_models_out" || fail "wrong models object did not fail contract"

start_verify_api_fixture overlength_caps
cat >"$verify_live/home/.hermes/.env" <<ENV
API_SERVER_HOST=127.0.0.1
API_SERVER_PORT=$(cat "$TMP/verify-api-overlength_caps.port")
API_SERVER_KEY=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ENV
if overlength_out="$(HOME="$verify_live/home" HERMES_HOME="$verify_live/home/.hermes" HERMES_NATIVE_BOTS_API_PROBE_TIMEOUT=1 "$HELPER" verify-api 2>/tmp/native-bots-overlength.err)"; then
  fail "verify-api accepted overlength capabilities response"
fi
grep -q '"ok":false' <<<"$overlength_out" || fail "overlength response did not mark receipt failed"
grep -q '"response_overlength":true' <<<"$overlength_out" || fail "overlength response did not expose explicit overlength diagnostic"
grep -q '"error":"response_too_large"' <<<"$overlength_out" || fail "overlength response did not expose response_too_large"

module_home="$TMP/module-home"
mkdir -p "$module_home" "$TMP/no-ts-bin"
cat >"$TMP/no-ts-bin/tailscale" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$TMP/no-ts-bin/tailscale"
if module_out="$(PATH="$TMP/no-ts-bin:/usr/bin:/bin" HOME="$module_home" REPO_ROOT="$ROOT" TIER=recommended ROLE=server HERMES_SKIP= bash "$MODULE" 2>&1)"; then
  fail "module succeeded without tailscale bind"
fi
grep -q 'no fallback bind' <<<"$module_out" || fail "module missing tailscale fail-closed warning"
[[ ! -e "$module_home/.hermes/.env" ]] || fail "module created .env without tailscale"

hbtp="$TMP/hbtp"
mkdir -p "$hbtp/bin" "$hbtp/home/.hermes"
cat >"$hbtp/bin/hostname" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "-s" ]] && printf 'h-btp\n' || printf 'h-btp.example\n'
SH
chmod +x "$hbtp/bin/hostname"
cat >"$hbtp/hosts.yaml" <<'YAML'
hosts:
  - hostname: h-btp
    management:
      runtime_user: hermes
      hermes_home: /home/hermes/.hermes
YAML
hbtp_out="$(PATH="$hbtp/bin:/usr/bin:/bin" HOME="$hbtp/home" HERMES_NATIVE_BOTS_HOSTS_METADATA="$hbtp/hosts.yaml" HERMES_HOME="$hbtp/home/.hermes" HERMES_NATIVE_BOTS_TAILSCALE_IP=100.64.1.5 "$HELPER" configure-api --host 100.64.1.5 --port 8642)"
grep -q '"status":"deferred"' <<<"$hbtp_out" || fail "h-btp root/default invocation did not defer to registry runtime"
[[ ! -e "$hbtp/home/.hermes/.env" ]] || fail "h-btp defer modified caller home"

desktop="$TMP/desktop"
mkdir -p "$desktop/bin" "$desktop/home/Applications" "$desktop/source/apps/desktop/release/mac-arm64/Hermes.app/Contents"
cat >"$desktop/bin/uname" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-m" ]]; then printf 'x86_64\n'; else printf 'Darwin\n'; fi
SH
chmod +x "$desktop/bin/uname"
cat >"$desktop/bin/file" <<'SH'
#!/usr/bin/env bash
printf 'Mach-O 64-bit executable x86_64\n'
SH
chmod +x "$desktop/bin/file"
mkdir -p "$desktop/source/apps/desktop/release/mac-arm64/Hermes.app/Contents/MacOS"
python3 - "$desktop/source/apps/desktop/release/mac-arm64/Hermes.app/Contents/Info.plist" <<'PY'
import plistlib, sys
data = {
    "CFBundleIdentifier": "com.nousresearch.hermes",
    "CFBundleShortVersionString": "1.2.3",
    "CFBundleExecutable": "Hermes",
}
with open(sys.argv[1], "wb") as fh:
    plistlib.dump(data, fh)
PY
printf '#!/usr/bin/env bash\nexit 0\n' >"$desktop/source/apps/desktop/release/mac-arm64/Hermes.app/Contents/MacOS/Hermes"
chmod +x "$desktop/source/apps/desktop/release/mac-arm64/Hermes.app/Contents/MacOS/Hermes"

desktop_runtime="$TMP/desktop-runtime"
mkdir -p "$desktop_runtime/home/.hermes"
cp -R "$desktop/source" "$desktop_runtime/home/.hermes/hermes-agent"
runtime_status="$(unset HERMES_SOURCE_ROOT; PATH="$desktop/bin:/usr/bin:/bin" HOME="$desktop_runtime/home" "$HELPER" status-desktop)"
grep -q '"status":"source_missing"' <<<"$runtime_status" && fail "runtime source detection missed built app"
grep -q "$desktop_runtime/home/.hermes/hermes-agent/apps/desktop/release/mac-arm64/Hermes.app" <<<"$runtime_status" \
  || fail "runtime source path not reported without HERMES_SOURCE_ROOT override"

status="$(PATH="$desktop/bin:/usr/bin:/bin" HOME="$desktop/home" HERMES_SOURCE_ROOT="$desktop/source" "$HELPER" status-desktop)"
grep -q '"status":"source_missing"' <<<"$status" && fail "native source detection missed built app"
grep -q "$desktop/source/apps/desktop/release/mac-arm64/Hermes.app" <<<"$status" || fail "native source path not reported"
cat >"$desktop/bin/launchctl" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "print" && "${HERMES_TEST_LAUNCHCTL_LOADED:-1}" == "1" ]]; then
  exit 0
fi
exit 1
SH
chmod +x "$desktop/bin/launchctl"
mkdir -p "$desktop/home/Library/LaunchAgents"
ln -s "$desktop/source/apps/desktop/release/mac-arm64/Hermes.app" "$desktop/home/Applications/Hermes.app"
python3 - "$desktop/home/Library/LaunchAgents/com.hermes.desktop.plist" "$desktop/home/Applications/Hermes.app" "com.hermes.desktop" <<'PY'
import plistlib, sys
plist, target, label = sys.argv[1:4]
data = {"Label": label, "ProgramArguments": ["/usr/bin/open", target], "RunAtLoad": True}
with open(plist, "wb") as fh:
    plistlib.dump(data, fh)
PY
configured_status="$(PATH="$desktop/bin:/usr/bin:/bin" HOME="$desktop/home" HERMES_SOURCE_ROOT="$desktop/source" "$HELPER" status-desktop)"
grep -q '"status":"configured"' <<<"$configured_status" || fail "desktop status did not report configured when launchagent is loaded"
grep -q '"version":"1.2.3"' <<<"$configured_status" || fail "desktop status did not populate app version"
grep -q '"codesign":"not_checked"' <<<"$configured_status" || fail "desktop status did not populate codesign state"
grep -Fq "\"executable\":\"$desktop/source/apps/desktop/release/mac-arm64/Hermes.app/Contents/MacOS/Hermes\"" <<<"$configured_status" \
  || fail "desktop status did not populate executable path"
python3 - "$desktop/home/Library/LaunchAgents/com.hermes.desktop.plist" "$desktop/home/Applications/Hermes.app" "com.hermes.wrong" <<'PY'
import plistlib, sys
plist, target, label = sys.argv[1:4]
data = {"Label": label, "ProgramArguments": ["/usr/bin/open", target], "RunAtLoad": True}
with open(plist, "wb") as fh:
    plistlib.dump(data, fh)
PY
wrong_label_status="$(PATH="$desktop/bin:/usr/bin:/bin" HOME="$desktop/home" HERMES_SOURCE_ROOT="$desktop/source" "$HELPER" status-desktop)"
! grep -q '"status":"configured"' <<<"$wrong_label_status" || fail "desktop status accepted wrong LaunchAgent label"
grep -q '"plist_ok":false' <<<"$wrong_label_status" || fail "desktop status did not reject wrong LaunchAgent label"
python3 - "$desktop/home/Library/LaunchAgents/com.hermes.desktop.plist" "$desktop/home/Applications/Hermes.app" "com.hermes.desktop" <<'PY'
import plistlib, sys
plist, target, label = sys.argv[1:4]
data = {"Label": label, "ProgramArguments": ["/usr/bin/open", target], "RunAtLoad": True}
with open(plist, "wb") as fh:
    plistlib.dump(data, fh)
PY
not_loaded_status="$(HERMES_TEST_LAUNCHCTL_LOADED=0 PATH="$desktop/bin:/usr/bin:/bin" HOME="$desktop/home" HERMES_SOURCE_ROOT="$desktop/source" "$HELPER" status-desktop)"
grep -q '"status":"not_loaded"' <<<"$not_loaded_status" || fail "desktop status configured despite unloaded LaunchAgent"
grep -q '"loaded":false' <<<"$not_loaded_status" || fail "desktop status did not expose unloaded LaunchAgent"
rm -f "$desktop/home/Applications/Hermes.app"
mkdir -p "$desktop/home/Applications/Hermes.app"
if PATH="$desktop/bin:/usr/bin:/bin" HOME="$desktop/home" HERMES_SOURCE_ROOT="$desktop/source" "$HELPER" configure-desktop >/tmp/native-bots-desktop.out 2>&1; then
  fail "conflicting existing Hermes.app was replaced"
fi
grep -q 'desktop_conflict' /tmp/native-bots-desktop.out || fail "desktop conflict refusal missing"

desktop_fail="$TMP/desktop-fail"
mkdir -p "$desktop_fail/bin" "$desktop_fail/home" "$desktop_fail/source/apps/desktop/release/mac-arm64/Hermes.app/Contents/MacOS"
cp "$desktop/bin/uname" "$desktop_fail/bin/uname"
cp "$desktop/bin/file" "$desktop_fail/bin/file"
python3 - "$desktop_fail/source/apps/desktop/release/mac-arm64/Hermes.app/Contents/Info.plist" <<'PY'
import plistlib, sys
data = {"CFBundleIdentifier": "com.nousresearch.hermes", "CFBundleShortVersionString": "1.2.3", "CFBundleExecutable": "Hermes"}
with open(sys.argv[1], "wb") as fh:
    plistlib.dump(data, fh)
PY
printf '#!/usr/bin/env bash\nexit 0\n' >"$desktop_fail/source/apps/desktop/release/mac-arm64/Hermes.app/Contents/MacOS/Hermes"
chmod +x "$desktop_fail/source/apps/desktop/release/mac-arm64/Hermes.app/Contents/MacOS/Hermes"
cat >"$desktop_fail/bin/launchctl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$desktop_fail/bin/launchctl"
if PATH="$desktop_fail/bin:/usr/bin:/bin" HOME="$desktop_fail/home" HERMES_SOURCE_ROOT="$desktop_fail/source" "$HELPER" configure-desktop >/tmp/native-bots-desktop-open.out 2>&1; then
  fail "configure-desktop succeeded without launching app"
fi
grep -q 'desktop_open_failed' /tmp/native-bots-desktop-open.out || fail "desktop launch failure did not propagate"

module_desktop="$TMP/module-desktop"
mkdir -p "$module_desktop/bin" "$module_desktop/home"
cat >"$module_desktop/bin/uname" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-m" ]]; then printf 'x86_64\n'; else printf 'Darwin\n'; fi
SH
cat >"$module_desktop/bin/tailscale" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == "ip" ]] && { printf '100.64.2.1\n'; exit 0; }
exit 1
SH
cat >"$module_desktop/bin/hermes" <<'SH'
#!/usr/bin/env bash
[[ "$*" == "desktop --build-only" ]] && exit 42
exit 43
SH
chmod +x "$module_desktop/bin/uname" "$module_desktop/bin/tailscale" "$module_desktop/bin/hermes"
if module_desktop_out="$(PATH="$module_desktop/bin:/usr/bin:/bin" HOME="$module_desktop/home" REPO_ROOT="$ROOT" TIER=recommended ROLE=client HERMES_SKIP= bash "$MODULE" 2>&1)"; then
  fail "module succeeded after Hermes Desktop build failure"
fi
grep -q 'Hermes Desktop build failed' <<<"$module_desktop_out" || fail "module did not propagate desktop build failure"

probe="$TMP/probe"
mkdir -p "$probe/bin"
for name in uname python3 hermes-native-bots; do
  cat >"$probe/bin/$name" <<'SH'
#!/usr/bin/env bash
printf 'unexpected eager verifier command: %s\n' "$0" >&2
exit 97
SH
  chmod +x "$probe/bin/$name"
done
PATH="$probe/bin:/usr/bin:/bin" bash -c 'source "$1"' _ "$VERIFY" \
  || fail "verify.sh eagerly executed native-bots probe"

verify_api="$TMP/verify-api"
mkdir -p "$verify_api/bin"
cat >"$verify_api/bin/hermes-native-bots" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$VERIFY_API_LOG"
case "$1" in
  verify-api)
    printf '%s\n' '{"schema_version":1,"ok":true,"action":"verify-api","api":{"host":"100.64.1.17","port":8642,"no_key_denied":true,"wrong_key_denied":true,"capabilities_authenticated":true,"models_authenticated":true}}'
    ;;
  status-api)
    printf '%s\n' '{"schema_version":1,"ok":true,"action":"status-api","api":{"status":"configured","host":"100.64.1.17","port":8642,"key_present":true}}'
    ;;
  *) exit 98 ;;
esac
SH
chmod +x "$verify_api/bin/hermes-native-bots"
verify_native_out="$(VERIFY_API_LOG="$verify_api/log" PATH="$verify_api/bin:/usr/bin:/bin" bash -c 'source "$1"; verify_hermes_native_api' _ "$VERIFY")" \
  || fail "verify_hermes_native_api rejected live verify-api object"
[[ "$verify_native_out" == "verified" ]] || fail "verify_hermes_native_api did not report verified"
grep -qx 'verify-api' "$verify_api/log" || fail "verify_hermes_native_api did not call verify-api"
! grep -qx 'status-api' "$verify_api/log" || fail "verify_hermes_native_api used diagnostic status-api"
cat >"$verify_api/bin/hermes-native-bots" <<'SH'
#!/usr/bin/env bash
case "$1" in
  verify-api)
    printf '%s\n' '{"schema_version":1,"ok":true,"action":"status-api","api":{"status":"deferred","host":"","port":8642}}'
    ;;
  *) exit 98 ;;
esac
SH
chmod +x "$verify_api/bin/hermes-native-bots"
if PATH="$verify_api/bin:/usr/bin:/bin" bash -c 'source "$1"; verify_hermes_native_api' _ "$VERIFY" >/tmp/native-bots-verify-deferred.out 2>&1; then
  fail "verify_hermes_native_api accepted diagnostic/deferred object"
fi

grep -q 'hermes_native_bots:' "$ROOT/lib/99-register-host.sh" || fail "registry helper version field missing"
grep -q 'hermes_desktop:' "$ROOT/lib/99-register-host.sh" || fail "registry desktop version field missing"
grep -q 'Hermes native Bot API defaults' "$ROOT/tiers/recommended.txt" || fail "tier manifest missing API defaults"
grep -q 'Hermes Desktop LaunchAgent' "$ROOT/tiers/recommended.txt" || fail "tier manifest missing Desktop defaults"

pass "Hermes native bots package contract and behavior"
