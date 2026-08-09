#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CORE="$ROOT/scripts/hermes-workspace"
WRAPPER="$ROOT/scripts/hmw-herdr.sh"
TMUX_WRAPPER="$ROOT/scripts/hmw-tmux.sh"
TEST_TMP=$(mktemp -d)
FAKE_BIN="$TEST_TMP/bin"
HOME_DIR="$TEST_TMP/home"
LOG="$TEST_TMP/calls.log"
TMUX_STATE="$TEST_TMP/tmux.state"
HERDR_NAMES_FILE="$TEST_TMP/herdr.names"
STATUS_COUNT="$TEST_TMP/status.count"
HERDR_LIST_COUNT="$TEST_TMP/herdr-list.count"
SLEEP_LOG="$TEST_TMP/sleeps.log"
STDOUT_FILE="$TEST_TMP/stdout"
STDERR_FILE="$TEST_TMP/stderr"
PASS=0
FAIL=0
REAL_TMUX=$(command -v tmux 2>/dev/null || :)
REAL_TMUX_SOCKET=""

cleanup() {
  if [ -n "$REAL_TMUX" ] && [ -n "$REAL_TMUX_SOCKET" ]; then
    "$REAL_TMUX" -L "$REAL_TMUX_SOCKET" kill-server 2>/dev/null || :
  fi
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN" "$HOME_DIR/.local/bin"
ln -s "$CORE" "$HOME_DIR/.local/bin/hermes-workspace"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  FAIL=$((FAIL + 1))
}

pass() {
  printf 'ok - %s\n' "$1"
  PASS=$((PASS + 1))
}

assert_eq() {
  local expected=$1 actual=$2 message=$3
  if [ "$expected" = "$actual" ]; then
    return 0
  fi
  printf '  expected: <%s>\n  actual:   <%s>\n' "$expected" "$actual" >&2
  fail "$message"
  return 1
}

assert_contains() {
  local file=$1 text=$2 message=$3
  if grep -Fq -- "$text" "$file"; then
    return 0
  fi
  printf '  missing <%s> in %s\n' "$text" "$file" >&2
  fail "$message"
  return 1
}

assert_not_contains() {
  local file=$1 text=$2 message=$3
  if ! grep -Fq -- "$text" "$file"; then
    return 0
  fi
  printf '  unexpected <%s> in %s\n' "$text" "$file" >&2
  fail "$message"
  return 1
}

assert_line_count() {
  local expected=$1 file=$2 text=$3 message=$4 actual
  actual=$(grep -Fc -- "$text" "$file" || :)
  assert_eq "$expected" "$actual" "$message"
}

assert_exact_line_count() {
  local expected=$1 file=$2 text=$3 message=$4 actual
  actual=$(grep -Fxc -- "$text" "$file" || :)
  assert_eq "$expected" "$actual" "$message"
}

run_core() {
  : >"$STDOUT_FILE"
  : >"$STDERR_FILE"
  env HOME="$HOME_DIR" PATH="$FAKE_BIN:/usr/local/bin:/usr/bin:/bin" \
    HMW_STUB_LOG="$LOG" TMUX_STATE="$TMUX_STATE" HERDR_NAMES_FILE="$HERDR_NAMES_FILE" \
    STATUS_COUNT="$STATUS_COUNT" HERDR_LIST_COUNT="$HERDR_LIST_COUNT" SLEEP_LOG="$SLEEP_LOG" \
    "$@" >"$STDOUT_FILE" 2>"$STDERR_FILE"
}

reset_state() {
  : >"$LOG"
  : >"$TMUX_STATE"
  : >"$HERDR_NAMES_FILE"
  : >"$SLEEP_LOG"
  printf '0\n' >"$STATUS_COUNT"
  printf '0\n' >"$HERDR_LIST_COUNT"
  export STUB_HOSTNAME=origin
  export RESOLVED_TARGET=root@resolved
  export TMUX_EXISTS=0
  export HERDR_READY_AT=1
  export HERDR_MALFORMED=0
  unset HERDR_UNNAMED_LABEL HERDR_UNNAMED_PANE_ID
  export SSH_EXECUTE=0
  export SSH_REMOTE_HOST=target
  unset TMUX HMW_VERIFY HMW_HERDR_VERIFY HMW_BACKEND HMW_REMOTE HMW_DEFAULT_HOST HERDR_SESSION
  unset HERDR_START_FAIL_LABEL HERDR_START_FAIL_ADD
}

cat >"$FAKE_BIN/hostname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${STUB_HOSTNAME:-origin}"
EOF

cat >"$FAKE_BIN/hermes-host-resolve" <<'EOF'
#!/usr/bin/env bash
printf 'resolver\t%s\n' "$1" >>"$HMW_STUB_LOG"
[ "${RESOLVER_EMPTY:-0}" = 1 ] || printf '%s\n' "${RESOLVED_TARGET:-root@resolved}"
EOF

cat >"$FAKE_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh' >>"$HMW_STUB_LOG"
for arg in "$@"; do printf '\t%s' "$arg" >>"$HMW_STUB_LOG"; done
printf '\n' >>"$HMW_STUB_LOG"
if [ "${SSH_EXECUTE:-0}" = 1 ]; then
  if [ "$1" = -t ]; then shift; fi
  target=$1
  shift
  [ "$#" -eq 1 ] || exit 91
  case "$1" in
    'sh -c '*) ;;
    *) exit 92 ;;
  esac
  export STUB_HOSTNAME="${SSH_REMOTE_HOST:-target}"
  export SSH_EXECUTE=0
  if [ "${SSH_LOGIN_SHELL:-sh}" = zsh ]; then
    exec zsh -c "$1"
  fi
  exec /bin/sh -c "$1"
fi
exit "${SSH_EXIT_STATUS:-0}"
EOF

cat >"$FAKE_BIN/hermes-pane" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
printf 'tmux' >>"$HMW_STUB_LOG"
for arg in "$@"; do printf '\t%s' "$arg" >>"$HMW_STUB_LOG"; done
printf '\n' >>"$HMW_STUB_LOG"
command=$1
shift
case "$command" in
  has-session)
    [ "${TMUX_EXISTS:-0}" = 1 ]
    ;;
  list-panes)
    cat "$TMUX_STATE"
    ;;
  new-session)
    pane_id=%1
    pane_command=${!#}
    printf '%s__HMW_SEP____HMW_SEP__%s\n' "$pane_id" "$pane_command" >"$TMUX_STATE"
    printf '%s\n' "$pane_id"
    export TMUX_EXISTS=1
    ;;
  split-window)
    count=$(wc -l <"$TMUX_STATE")
    pane_id="%$((count + 1))"
    pane_command=${!#}
    printf '%s__HMW_SEP____HMW_SEP__%s\n' "$pane_id" "$pane_command" >>"$TMUX_STATE"
    printf '%s\n' "$pane_id"
    ;;
  set-option)
    target=$3
    label=$5
    awk -F '__HMW_SEP__' -v OFS='__HMW_SEP__' -v target="$target" -v label="$label" \
      '{ if ($1 == target) $2 = label; print }' "$TMUX_STATE" >"$TMUX_STATE.next"
    mv "$TMUX_STATE.next" "$TMUX_STATE"
    ;;
  select-layout|select-pane|switch-client|attach-session)
    ;;
  *)
    exit 97
    ;;
esac
EOF

cat >"$FAKE_BIN/herdr" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --session ] && [ "${3:-}" = agent ] && [ "${4:-}" = start ] && [ "${5:-}" = --help ]; then
  if [ "${HERDR_NEW_API:-0}" = 1 ]; then
    printf '%s\n' 'Usage: herdr agent start <NAME> --kind <KIND> --pane <ID>'
    exit 0
  fi
  exit 2
fi
printf 'herdr' >>"$HMW_STUB_LOG"
for arg in "$@"; do printf '\t%s' "$arg" >>"$HMW_STUB_LOG"; done
printf '\n' >>"$HMW_STUB_LOG"
[ "$1" = --session ] || exit 90
session=$2
shift 2
if [ "$#" -eq 0 ]; then
  exit 0
fi
case "$1 $2" in
  'status server')
    count=$(cat "$STATUS_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" >"$STATUS_COUNT"
    if [ "$count" -ge "${HERDR_READY_AT:-1}" ]; then
      printf '{"status":"running","running":true,"session":"%s"}\n' "$session"
      exit 0
    fi
    printf '{"status":"stopped","running":false,"session":"%s"}\n' "$session"
    exit 1
    ;;
  'agent list')
    count=$(cat "$HERDR_LIST_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" >"$HERDR_LIST_COUNT"
    if [ "$count" -le "${HERDR_LIST_FAILS:-0}" ]; then
      exit 1
    fi
    if [ "${HERDR_MALFORMED:-0}" = 1 ]; then
      printf '{malformed\n'
      exit 0
    fi
    printf '{"id":"cli:agent:list","result":{"agents":['
    first=1
    if [ -n "${HERDR_UNNAMED_LABEL:-}" ]; then
      printf '{"agent":"hermes","pane_id":"%s"}' "${HERDR_UNNAMED_PANE_ID:-w1:pB}"
      first=0
    fi
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      [ "$first" -eq 1 ] || printf ','
      printf '{"name":"%s"}' "$name"
      first=0
    done <"$HERDR_NAMES_FILE"
    printf '],"type":"agent_list"}}\n'
    ;;
  'pane list')
    printf '{"id":"cli:pane:list","result":{"panes":['
    if [ -n "${HERDR_UNNAMED_LABEL:-}" ]; then
      printf '{"agent":"hermes","label":"%s","pane_id":"%s"}' \
        "$HERDR_UNNAMED_LABEL" "${HERDR_UNNAMED_PANE_ID:-w1:pB}"
    fi
    printf '],"type":"pane_list"}}\n'
    ;;
  'workspace create')
    printf '%s\n' '{"id":"cli:workspace:create","result":{"root_pane":{"pane_id":"w1:p1"},"type":"workspace_created"}}'
    ;;
  'pane split')
    printf '%s\n' '{"id":"cli:pane:split","result":{"pane":{"pane_id":"w1:p2"},"type":"pane_info"}}'
    ;;
  'pane rename')
    ;;
  'pane run')
    label=${4#hermes-pane }
    printf '%s\n' "$label" >>"$HERDR_NAMES_FILE"
    ;;
  'pane get')
    printf '%s\n' '{"id":"cli:pane:get","result":{"pane":{"agent":"hermes"},"type":"pane_info"}}'
    ;;
  'agent start')
    label=$3
    if [ "$label" = "${HERDR_START_FAIL_LABEL:-}" ]; then
      if [ "${HERDR_START_FAIL_ADD:-0}" = 1 ]; then
        printf '%s\n' "$label" >>"$HERDR_NAMES_FILE"
      fi
      exit 42
    fi
    printf '%s\n' "$label" >>"$HERDR_NAMES_FILE"
    if [ "${HERDR_CHATTER:-0}" = 1 ]; then printf 'started %s\n' "$label"; fi
    ;;
  'agent focus')
    if [ "${HERDR_CHATTER:-0}" = 1 ]; then printf 'focused %s\n' "$3"; fi
    ;;
  'server ')
    ;;
  *)
    [ "$1" = server ] || exit 96
    ;;
esac
EOF

cat >"$FAKE_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$SLEEP_LOG"
EOF

chmod +x "$FAKE_BIN"/*

test_argument_and_default_parity() {
  local first second
  reset_state
  run_core env HMW_VERIFY=1 STUB_HOSTNAME=origin "$CORE" alpha 3 || return 1
  first=$(grep '^ssh' "$LOG")
  reset_state
  run_core env HMW_VERIFY=1 STUB_HOSTNAME=origin "$CORE" 3 alpha || return 1
  second=$(grep '^ssh' "$LOG")
  assert_eq "$first" "$second" 'host/count order is equivalent' || return 1

  reset_state
  run_core env HMW_VERIFY=1 STUB_HOSTNAME=origin "$CORE" || return 1
  assert_contains "$LOG" $'resolver\th-do1' 'no args use default host' || return 1
  assert_contains "$LOG" "hermes-workspace '\''2'\''" 'no args use default count' || return 1

  reset_state
  run_core env HMW_VERIFY=1 "$CORE" user@literal 2 || return 1
  assert_not_contains "$LOG" 'resolver' 'explicit user@host bypasses resolver' || return 1
  assert_contains "$LOG" $'ssh\tuser@literal\t' 'explicit user@host remains verbatim' || return 1

  for default in node user@node node.example; do
    reset_state
    run_core env HMW_VERIFY=1 HMW_DEFAULT_HOST="$default" STUB_HOSTNAME=node TMUX_EXISTS=0 "$CORE" || return 1
    assert_not_contains "$LOG" 'resolver' "matching default $default runs locally" || return 1
    assert_not_contains "$LOG" 'ssh' "matching default $default avoids self-SSH" || return 1
  done

  reset_state
  run_core env HMW_VERIFY=1 HMW_DEFAULT_HOST=alias STUB_HOSTNAME=node RESOLVED_TARGET=root@node "$CORE" || return 1
  assert_contains "$LOG" $'resolver\talias' 'alias mismatch resolves before dispatch' || return 1
  assert_contains "$LOG" $'ssh\troot@node\t' 'alias resolving local still self-SSHs' || return 1

  reset_state
  run_core env HMW_REMOTE=1 HMW_VERIFY=1 "$CORE" 1 || return 1
  assert_contains "$STDOUT_FILE" 'HMW_VERIFY backend=herdr' 'hmw defaults to the Herdr backend' || return 1
  assert_not_contains "$LOG" $'tmux\t' 'default hmw does not invoke tmux' || return 1
  pass 'argument order and default-target parity'
}

test_invalid_requests() {
  local args status
  for args in '0' '-2' '2 3' 'host other' '--bad'; do
    reset_state
    set +e
    # shellcheck disable=SC2086
    run_core env "$CORE" $args
    status=$?
    set -e
    assert_eq 2 "$status" "invalid request '$args' exits 2" || return 1
    assert_not_contains "$LOG" 'ssh' "invalid request '$args' avoids SSH" || return 1
    assert_not_contains "$LOG" 'tmux' "invalid request '$args' avoids tmux" || return 1
    assert_not_contains "$LOG" 'herdr' "invalid request '$args' avoids Herdr" || return 1
  done
  reset_state
  set +e
  run_core env "$CORE" ''
  status=$?
  set -e
  assert_eq 2 "$status" 'explicit empty argument exits 2' || return 1
  assert_contains "$STDERR_FILE" 'arguments must not be empty' 'explicit empty argument gives a usage diagnostic' || return 1
  assert_eq '' "$(cat "$LOG")" 'explicit empty argument has no side effects' || return 1

  reset_state
  set +e
  run_core env HMW_BACKEND=invalid "$CORE" host 2
  status=$?
  set -e
  assert_eq 2 "$status" 'invalid backend exits 2' || return 1
  assert_eq '' "$(cat "$LOG")" 'invalid backend has no side effects' || return 1

  reset_state
  set +e
  run_core env HMW_REMOTE=1 "$CORE" host 2
  status=$?
  set -e
  assert_eq 2 "$status" 'remote re-entry rejects host arguments' || return 1
  assert_eq '' "$(cat "$LOG")" 'invalid remote re-entry has no side effects' || return 1
  pass 'invalid requests fail before dispatch or backend calls'
}

test_remote_dispatch_and_reentry() {
  local session="ws ' spaced;\$(touch nope)" status ssh_line
  reset_state
  printf 'H2\nunrelated\n' >"$HERDR_NAMES_FILE"
  export SSH_EXECUTE=1 SSH_LOGIN_SHELL=sh SSH_REMOTE_HOST=remote-one
  run_core env HMW_BACKEND=herdr HMW_VERIFY=1 HERDR_SESSION="$session" STUB_HOSTNAME=origin \
    SSH_EXECUTE=1 SSH_LOGIN_SHELL=sh SSH_REMOTE_HOST=remote-one "$CORE" alias 2 || return 1
  assert_line_count 1 "$LOG" $'ssh\t' 'remote request uses exactly one SSH hop' || return 1
  assert_line_count 1 "$LOG" $'resolver\talias' 'resolver runs only at origin' || return 1
  assert_contains "$LOG" "$(printf 'herdr\t--session\t%s\tstatus\tserver\t--json' "$session")" 'session survives POSIX quoting as one inert argument' || return 1
  assert_contains "$STDOUT_FILE" 'HMW_VERIFY target=remote-one' 'remote verify reports re-entry hostname' || return 1
  assert_not_contains "$STDOUT_FILE" 'root@resolved' 'verify does not expose resolved endpoint' || return 1
  ssh_line=$(grep '^ssh' "$LOG")
  case "$ssh_line" in
    *$'\tsh -c '*) ;;
    *) fail 'remote command explicitly invokes sh -c'; return 1 ;;
  esac
  assert_not_contains "$LOG" $'ssh\t-t\t' 'verify mode omits ssh -t' || return 1

  reset_state
  printf 'H1\n' >"$HERDR_NAMES_FILE"
  run_core env HMW_BACKEND=herdr HMW_VERIFY='' HERDR_SESSION=ws STUB_HOSTNAME=origin \
    SSH_EXECUTE=1 SSH_LOGIN_SHELL=zsh SSH_REMOTE_HOST=remote-zsh "$CORE" unknown 1 || return 1
  assert_contains "$LOG" $'ssh\t-t\troot@resolved\tsh -c ' 'interactive mode uses ssh -t' || return 1
  assert_line_count 1 "$LOG" $'ssh\t' 'zsh-login harness still uses one SSH hop' || return 1
  assert_contains "$LOG" $'herdr\t--session\tws\tstatus\tserver\t--json' 'zsh-login harness reaches remote backend' || return 1
  assert_line_count 1 "$LOG" $'resolver\tunknown' 'remote marker prevents recursive resolution' || return 1

  reset_state
  set +e
  run_core env HMW_BACKEND=herdr STUB_HOSTNAME=origin SSH_EXIT_STATUS=255 "$CORE" remote 1
  status=$?
  set -e
  assert_eq 255 "$status" 'broken Herdr SSH preserves the ssh failure status' || return 1
  assert_contains "$STDOUT_FILE" $'\033[<u' 'broken Herdr SSH pops Kitty keyboard mode locally' || return 1
  assert_contains "$STDOUT_FILE" $'\033[>4m' 'broken Herdr SSH disables modifyOtherKeys locally' || return 1
  assert_not_contains "$STDOUT_FILE" $'\033[H\033[2J' 'post-SSH heal does not clear the user shell screen' || return 1

  if rg -n 'printf +%q' "$CORE" >/dev/null 2>&1; then
    fail 'core contains no printf %q quoting path'
    return 1
  fi
  [ ! -e "$TEST_TMP/nope" ] || { fail 'quoted metacharacters remained inert'; return 1; }
  pass 'remote propagation, POSIX quoting, interpreter, and recursion'
}

test_tmux_preservation_and_verify() {
  local expected
  reset_state
  run_core env HMW_BACKEND=tmux HMW_REMOTE=1 HMW_VERIFY=1 TMUX_EXISTS=0 STUB_HOSTNAME=local "$CORE" 3 || return 1
  assert_contains "$LOG" $'tmux\tnew-session\t-d\t-P\t-F\t#{pane_id}\t-s\tws\t-n\tws\thermes-pane H1' 'fresh tmux creates ws:ws with H1' || return 1
  assert_contains "$LOG" $'tmux\tsplit-window\t-h\t-P\t-F\t#{pane_id}\t-t\tws:ws\thermes-pane H2' 'fresh tmux adds H2 horizontally' || return 1
  assert_contains "$LOG" $'tmux\tsplit-window\t-h\t-P\t-F\t#{pane_id}\t-t\tws:ws\thermes-pane H3' 'fresh tmux adds H3 horizontally' || return 1
  assert_contains "$LOG" $'tmux\tselect-layout\t-t\tws:ws\teven-horizontal' 'fresh tmux balances layout' || return 1
  assert_contains "$LOG" $'tmux\tselect-pane\t-t\t%1' 'fresh tmux selects H1 pane id' || return 1
  assert_not_contains "$LOG" 'attach-session' 'tmux verify does not attach' || return 1
  expected=$(cat <<'EOF'
HMW_VERIFY backend=tmux
HMW_VERIFY session=ws:ws
HMW_VERIFY target=local
HMW_VERIFY requested=3
HMW_VERIFY slot=H1 command=hermes-pane H1
HMW_VERIFY slot=H2 command=hermes-pane H2
HMW_VERIFY slot=H3 command=hermes-pane H3
HMW_VERIFY inventory-begin
%1__HMW_SEP__H1__HMW_SEP__hermes-pane H1
%2__HMW_SEP__H2__HMW_SEP__hermes-pane H2
%3__HMW_SEP__H3__HMW_SEP__hermes-pane H3
HMW_VERIFY inventory-end
EOF
)
  assert_eq "$expected" "$(cat "$STDOUT_FILE")" 'tmux verify grammar and inventory are exact' || return 1

  reset_state
  export TMUX_EXISTS=1
  printf '%%7__HMW_SEP__H1__HMW_SEP__hermes-pane H1\n%%8__HMW_SEP____HMW_SEP__other-command\n%%9__HMW_SEP__H2__HMW_SEP__hermes-pane H2\n' >"$TMUX_STATE"
  run_core env HMW_BACKEND=tmux HMW_REMOTE=1 HMW_VERIFY=1 TMUX_EXISTS=1 "$CORE" 3 || return 1
  assert_contains "$LOG" $'split-window\t-h\t-P\t-F\t#{pane_id}\t-t\tws:ws\thermes-pane H3' 'missing exact slot is added despite unrelated pane' || return 1
  assert_contains "$LOG" $'select-pane\t-t\t%7' 'existing H1 pane id is focused' || return 1

  : >"$LOG"
  run_core env HMW_BACKEND=tmux HMW_REMOTE=1 HMW_VERIFY=1 TMUX_EXISTS=1 "$CORE" 1 || return 1
  assert_not_contains "$LOG" 'split-window' 'lower tmux count does not add or shrink' || return 1
  assert_not_contains "$LOG" 'kill-' 'lower tmux count never destroys panes' || return 1
  assert_not_contains "$LOG" 'rename' 'tmux never renames existing objects' || return 1

  reset_state
  printf '%%1__HMW_SEP__H1__HMW_SEP__hermes-pane H1\n' >"$TMUX_STATE"
  run_core env HMW_BACKEND=tmux HMW_REMOTE=1 TMUX_EXISTS=1 TMUX=inside "$CORE" 1 || return 1
  assert_contains "$LOG" $'tmux\tswitch-client\t-t\tws' 'inside tmux switches client' || return 1
  reset_state
  printf '%%1__HMW_SEP__H1__HMW_SEP__hermes-pane H1\n' >"$TMUX_STATE"
  run_core env HMW_BACKEND=tmux HMW_REMOTE=1 TMUX_EXISTS=1 "$CORE" 1 || return 1
  assert_contains "$LOG" $'tmux\tattach-session\t-t\tws' 'outside tmux attaches session' || return 1
  pass 'tmux creation, add-only preservation, focus, attach, and verify'
}

test_tmux_legacy_adoption() {
  local command
  for command in 'hermes-pane H2' "'hermes-pane H2'" '"hermes-pane H2"' "'hermes-pane' 'H2'" '"hermes-pane" "H2"'; do
    reset_state
    printf '%%1__HMW_SEP__H1__HMW_SEP__hermes-pane H1\n%%2__HMW_SEP____HMW_SEP__%s\n' "$command" >"$TMUX_STATE"
    run_core env HMW_BACKEND=tmux HMW_REMOTE=1 HMW_VERIFY=1 TMUX_EXISTS=1 "$CORE" 2 || return 1
    assert_contains "$LOG" $'tmux\tset-option\t-p\t-t\t%2\t@hmw_label\tH2' "legacy command $command is adopted" || return 1
    assert_not_contains "$LOG" 'split-window' "legacy command $command avoids duplicate" || return 1
  done
  for command in \
    ' hermes-pane H2' \
    'hermes-pane H2 ' \
    'hermes-pane H2 extra' \
    'env hermes-pane H2' \
    'hermes-pane\ H2' \
    "'hermes-pane H2" \
    '"hermes-pane H2' \
    "'hermes-pane' 'H2' extra" \
    "'hermes-pane'  'H2'" \
    "'hermes-pane' \"H2\"" \
    "sh -c 'hermes-pane' 'H2'" \
    '"hermes-pane" "H2" extra' \
    '"hermes-pane"  "H2"' \
    "\"hermes-pane\" 'H2'"; do
    reset_state
    printf '%%1__HMW_SEP__H1__HMW_SEP__hermes-pane H1\n%%2__HMW_SEP____HMW_SEP__%s\n' "$command" >"$TMUX_STATE"
    run_core env HMW_BACKEND=tmux HMW_REMOTE=1 HMW_VERIFY=1 TMUX_EXISTS=1 "$CORE" 2 || return 1
    assert_not_contains "$LOG" $'set-option\t-p\t-t\t%2\t@hmw_label\tH2' "near-miss command $command is not adopted" || return 1
    assert_contains "$LOG" $'split-window\t-h\t-P\t-F\t#{pane_id}\t-t\tws:ws\thermes-pane H2' "near-miss command $command causes safe addition" || return 1
  done
  pass 'tmux legacy adoption is conservative'
}

test_tmux_literal_backslash_tab_fixture() {
  reset_state
  printf '%s\n' '%7\tH1\thermes-pane H1' >"$TMUX_STATE"
  run_core env HMW_BACKEND=tmux HMW_REMOTE=1 HMW_VERIFY=1 TMUX_EXISTS=1 "$CORE" 1 || return 1
  assert_contains "$LOG" $'tmux\tlist-panes\t-t\tws:ws\t-F\t#{pane_id}__HMW_SEP__#{@hmw_label}__HMW_SEP__#{pane_start_command}' 'tmux inventory requests a literal separator string' || return 1
  assert_contains "$LOG" $'split-window\t-h\t-P\t-F\t#{pane_id}\t-t\tws:ws\thermes-pane H1' 'literal backslash-t output is not mistaken for delimited inventory' || return 1

  reset_state
  printf '%%7__HMW_SEP__H1__HMW_SEP__command__HMW_SEP__remainder\n' >"$TMUX_STATE"
  run_core env HMW_BACKEND=tmux HMW_REMOTE=1 HMW_VERIFY=1 TMUX_EXISTS=1 "$CORE" 1 || return 1
  assert_not_contains "$LOG" 'split-window' 'parser accepts the first two separators and preserves command remainder' || return 1
  assert_contains "$STDOUT_FILE" '%7__HMW_SEP__H1__HMW_SEP__command__HMW_SEP__remainder' 'verify preserves the native command remainder' || return 1
  pass 'tmux separator parsing rejects literal backslash-t fixtures'
}

test_bash32_compatibility() {
  local forbidden status bash32_mode

  forbidden=$(rg -n \
    -e 'declare[[:space:]]+-A' \
    -e '(^|[[:space:]])(mapfile|readarray)([[:space:]]|$)' \
    -e '\$\{[^}]*,,[^}]*\}' \
    -e '\$\{[^}]*\^\^[^}]*\}' \
    -e '\[\[[[:space:]]+-v([[:space:]]|\])' \
    "$CORE" "$WRAPPER" "$TMUX_WRAPPER" || :)
  assert_eq '' "$forbidden" 'runtime scripts statically reject Bash 4-only constructs' || return 1

  reset_state
  if command -v bash3.2 >/dev/null 2>&1; then
    bash32_mode='native bash3.2'
    set +e
    HOME="$HOME_DIR" PATH="$FAKE_BIN:/usr/local/bin:/usr/bin:/bin" \
      HMW_STUB_LOG="$LOG" TMUX_STATE="$TMUX_STATE" HERDR_NAMES_FILE="$HERDR_NAMES_FILE" \
      STATUS_COUNT="$STATUS_COUNT" HERDR_LIST_COUNT="$HERDR_LIST_COUNT" SLEEP_LOG="$SLEEP_LOG" \
      HMW_BACKEND=tmux HMW_REMOTE=1 HMW_VERIFY=1 TMUX_EXISTS=0 \
      bash3.2 "$CORE" 1 >"$STDOUT_FILE" 2>"$STDERR_FILE"
    status=$?
    set -e
  elif command -v docker >/dev/null 2>&1 && docker image inspect bash:3.2 >/dev/null 2>&1; then
    bash32_mode='bash:3.2 container'
    set +e
    docker run --rm \
      -v "$ROOT:/work:ro" -v "$TEST_TMP:$TEST_TMP" \
      -w /work \
      -e HOME="$HOME_DIR" -e PATH="$FAKE_BIN:/usr/local/bin:/usr/bin:/bin" \
      -e HMW_STUB_LOG="$LOG" -e TMUX_STATE="$TMUX_STATE" -e HERDR_NAMES_FILE="$HERDR_NAMES_FILE" \
      -e STATUS_COUNT="$STATUS_COUNT" -e HERDR_LIST_COUNT="$HERDR_LIST_COUNT" -e SLEEP_LOG="$SLEEP_LOG" \
      -e HMW_BACKEND=tmux -e HMW_REMOTE=1 -e HMW_VERIFY=1 -e TMUX_EXISTS=0 \
      bash:3.2 bash /work/scripts/hermes-workspace 1 >"$STDOUT_FILE" 2>"$STDERR_FILE"
    status=$?
    set -e
  else
    bash32_mode='/bin/bash BASH_COMPAT=3.2 fallback'
    set +e
    HOME="$HOME_DIR" PATH="$FAKE_BIN:/usr/local/bin:/usr/bin:/bin" \
      HMW_STUB_LOG="$LOG" TMUX_STATE="$TMUX_STATE" HERDR_NAMES_FILE="$HERDR_NAMES_FILE" \
      STATUS_COUNT="$STATUS_COUNT" HERDR_LIST_COUNT="$HERDR_LIST_COUNT" SLEEP_LOG="$SLEEP_LOG" \
      HMW_BACKEND=tmux HMW_REMOTE=1 HMW_VERIFY=1 TMUX_EXISTS=0 BASH_COMPAT=3.2 \
      /bin/bash "$CORE" 1 >"$STDOUT_FILE" 2>"$STDERR_FILE"
    status=$?
    set -e
  fi
  assert_eq 0 "$status" "$bash32_mode executes the core" || return 1
  assert_contains "$STDOUT_FILE" 'HMW_VERIFY backend=tmux' 'Bash compatibility execution reaches backend verification' || return 1
  pass "Bash 3.2 compatibility is static-checked and executed ($bash32_mode)"
}

test_real_tmux_integration() {
  local real_bin socket status inventory

  if [ -z "$REAL_TMUX" ]; then
    pass 'real tmux integration skipped (tmux unavailable)'
    return 0
  fi

  real_bin="$TEST_TMP/real-tmux-bin"
  socket="hmw-test-$$"
  REAL_TMUX_SOCKET=$socket
  mkdir -p "$real_bin"
  cat >"$real_bin/tmux" <<EOF
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$socket" "\$@"
EOF
  cat >"$real_bin/hermes-pane" <<'EOF'
#!/usr/bin/env bash
exec /bin/sleep 30
EOF
  chmod +x "$real_bin/tmux" "$real_bin/hermes-pane"

  set +e
  HOME="$HOME_DIR" PATH="$real_bin:/usr/local/bin:/usr/bin:/bin" \
    HMW_BACKEND=tmux HMW_REMOTE=1 HMW_VERIFY=1 /bin/bash "$CORE" 2 >"$STDOUT_FILE" 2>"$STDERR_FILE"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    "$REAL_TMUX" -L "$socket" kill-server 2>/dev/null || :
    printf '  real tmux stderr:\n' >&2
    cat "$STDERR_FILE" >&2
    fail 'real tmux workspace creation succeeds'
    return 1
  fi

  inventory=$("$REAL_TMUX" -L "$socket" list-panes -t ws:ws -F '#{pane_id}__HMW_SEP__#{@hmw_label}__HMW_SEP__#{pane_start_command}')
  assert_contains "$STDOUT_FILE" '__HMW_SEP__H1__HMW_SEP__' 'implementation parses actual tmux H1 output' || return 1
  assert_contains "$STDOUT_FILE" '__HMW_SEP__H2__HMW_SEP__' 'implementation parses actual tmux H2 output' || return 1
  assert_eq 2 "$(printf '%s\n' "$inventory" | wc -l | tr -d ' ')" 'isolated real tmux session has exactly two panes' || return 1

  HOME="$HOME_DIR" PATH="$real_bin:/usr/local/bin:/usr/bin:/bin" \
    HMW_BACKEND=tmux HMW_REMOTE=1 HMW_VERIFY=1 /bin/bash "$CORE" 2 >"$STDOUT_FILE" 2>"$STDERR_FILE" || return 1
  inventory=$("$REAL_TMUX" -L "$socket" list-panes -t ws:ws -F '#{@hmw_label}')
  assert_eq 'H1
H2' "$inventory" 'second real invocation reuses exact labeled panes' || return 1
  "$REAL_TMUX" -L "$socket" kill-server 2>/dev/null || :
  REAL_TMUX_SOCKET=""
  pass 'real tmux integration uses an isolated socket'
}

test_herdr_prerequisite_scoping_and_readiness() {
  local status fake_missing fake_missing_pane
  reset_state
  fake_missing="$TEST_TMP/missing-python"
  mkdir -p "$fake_missing"
  ln -s /bin/bash "$fake_missing/bash"
  ln -s "$FAKE_BIN/herdr" "$fake_missing/herdr"
  set +e
  HOME="$HOME_DIR" PATH="$fake_missing" HMW_STUB_LOG="$LOG" HERDR_NAMES_FILE="$HERDR_NAMES_FILE" \
    STATUS_COUNT="$STATUS_COUNT" HMW_BACKEND=herdr HMW_REMOTE=1 \
    /bin/bash "$CORE" 1 >"$STDOUT_FILE" 2>"$STDERR_FILE"
  status=$?
  set -e
  assert_eq 1 "$status" 'missing python3 fails Herdr backend' || return 1
  assert_contains "$STDERR_FILE" 'install python3' 'missing python3 gives install-oriented error' || return 1
  assert_not_contains "$LOG" 'herdr' 'missing python3 fails before any Herdr call' || return 1

  reset_state
  fake_missing_pane="$TEST_TMP/missing-hermes-pane"
  mkdir -p "$fake_missing_pane"
  ln -s /bin/bash "$fake_missing_pane/bash"
  ln -s "$FAKE_BIN/herdr" "$fake_missing_pane/herdr"
  ln -s "$(command -v python3)" "$fake_missing_pane/python3"
  set +e
  HOME="$HOME_DIR" PATH="$fake_missing_pane" HMW_STUB_LOG="$LOG" HERDR_NAMES_FILE="$HERDR_NAMES_FILE" \
    STATUS_COUNT="$STATUS_COUNT" HERDR_LIST_COUNT="$HERDR_LIST_COUNT" HMW_BACKEND=herdr HMW_REMOTE=1 \
    /bin/bash "$CORE" 1 >"$STDOUT_FILE" 2>"$STDERR_FILE"
  status=$?
  set -e
  assert_eq 1 "$status" 'missing hermes-pane fails Herdr backend' || return 1
  assert_contains "$STDERR_FILE" "'hermes-pane' not on PATH" 'missing hermes-pane gives install-oriented error' || return 1
  assert_not_contains "$LOG" 'herdr' 'missing hermes-pane fails before any Herdr call' || return 1

  reset_state
  printf 'H1\n' >"$HERDR_NAMES_FILE"
  run_core env HMW_BACKEND=herdr HMW_REMOTE=1 HMW_VERIFY=1 HERDR_SESSION=custom HERDR_READY_AT=1 "$CORE" 1 || return 1
  assert_eq 1 "$(cat "$STATUS_COUNT")" 'ready Herdr succeeds on first status attempt' || return 1
  assert_eq '' "$(cat "$SLEEP_LOG")" 'ready Herdr performs no sleeps' || return 1
  if grep '^herdr' "$LOG" | grep -v $'^herdr\t--session\tcustom\t' >/dev/null; then
    fail 'every Herdr invocation is session-scoped'
    return 1
  fi
  assert_contains "$LOG" $'herdr\t--session\tcustom\tagent\tlist' 'scoped inventory grammar is used' || return 1
  assert_contains "$LOG" $'herdr\t--session\tcustom\tagent\tfocus\tH1' 'scoped focus grammar is used' || return 1
  assert_exact_line_count 0 "$LOG" $'herdr\t--session\tcustom' 'verify mode does not attach Herdr' || return 1

  reset_state
  printf 'H1\n' >"$HERDR_NAMES_FILE"
  run_core env HMW_BACKEND=herdr HMW_REMOTE=1 HMW_VERIFY=1 HERDR_LIST_FAILS=2 "$CORE" 1 || return 1
  assert_eq 3 "$(cat "$HERDR_LIST_COUNT")" 'Herdr inventory retries two post-ready races' || return 1
  assert_eq 2 "$(wc -l <"$SLEEP_LOG" | tr -d ' ')" 'Herdr inventory race retry remains tightly bounded' || return 1

  reset_state
  printf 'H1\n' >"$HERDR_NAMES_FILE"
  run_core env HMW_BACKEND=herdr HMW_REMOTE=1 HMW_VERIFY=1 HERDR_READY_AT=20 "$CORE" 1 || return 1
  assert_eq 20 "$(cat "$STATUS_COUNT")" 'Herdr can become ready on attempt 20' || return 1
  assert_eq 19 "$(wc -l <"$SLEEP_LOG" | tr -d ' ')" 'attempt-20 success sleeps exactly 19 times' || return 1
  assert_contains "$LOG" $'herdr\t--session\tws\tserver' 'failed initial status starts scoped server' || return 1

  reset_state
  set +e
  run_core env HMW_BACKEND=herdr HMW_REMOTE=1 HMW_VERIFY=1 HERDR_READY_AT=99 HERDR_SESSION=slow "$CORE" 1
  status=$?
  set -e
  assert_eq 1 "$status" 'Herdr readiness timeout fails' || return 1
  assert_eq 20 "$(cat "$STATUS_COUNT")" 'Herdr timeout makes exactly 20 status calls' || return 1
  assert_eq 19 "$(wc -l <"$SLEEP_LOG" | tr -d ' ')" 'Herdr timeout sleeps exactly 19 times' || return 1
  assert_contains "$STDERR_FILE" "Herdr session 'slow' did not become ready" 'timeout names scoped session' || return 1
  assert_contains "$STDERR_FILE" '/herdr/sessions/slow/herdr.sock' 'timeout names expected socket' || return 1
  assert_not_contains "$LOG" $'agent\tlist' 'timeout performs no inventory' || return 1
  assert_not_contains "$LOG" $'agent\tstart' 'timeout performs no starts' || return 1
  assert_not_contains "$STDOUT_FILE" 'inventory-end' 'failed verify omits success trailer' || return 1
  pass 'Herdr prerequisites, scoping, and bounded readiness'
}

test_herdr_add_only_json_and_verify() {
  local expected status
  reset_state
  printf 'unrelated\nH2\n' >"$HERDR_NAMES_FILE"
  run_core env HMW_BACKEND=herdr HMW_REMOTE=1 HMW_VERIFY=1 HERDR_SESSION=team STUB_HOSTNAME=herdr-host HERDR_CHATTER=1 "$CORE" 3 || return 1
  assert_contains "$LOG" $'agent\tstart\tH1\t--split\tright\t--no-focus\t--\thermes-pane\tH1' 'Herdr starts missing H1 with exact grammar' || return 1
  assert_contains "$LOG" $'agent\tstart\tH3\t--split\tright\t--no-focus\t--\thermes-pane\tH3' 'Herdr starts missing H3 with exact grammar' || return 1
  assert_not_contains "$LOG" $'agent\tstart\tH2' 'Herdr reuses exact existing H2' || return 1
  assert_not_contains "$LOG" 'close' 'Herdr never closes agents' || return 1
  assert_not_contains "$LOG" 'stop' 'Herdr never stops sessions' || return 1
  assert_not_contains "$LOG" 'delete' 'Herdr never deletes sessions' || return 1
  assert_not_contains "$LOG" 'rename' 'Herdr never renames agents' || return 1
  expected=$(cat <<'EOF'
HMW_VERIFY backend=herdr
HMW_VERIFY session=team
HMW_VERIFY target=herdr-host
HMW_VERIFY requested=3
HMW_VERIFY slot=H1 command=hermes-pane H1
HMW_VERIFY slot=H2 command=hermes-pane H2
HMW_VERIFY slot=H3 command=hermes-pane H3
HMW_VERIFY inventory-begin
{"id":"cli:agent:list","result":{"agents":[{"name":"unrelated"},{"name":"H2"},{"name":"H1"},{"name":"H3"}],"type":"agent_list"}}
HMW_VERIFY inventory-end
EOF
)
  assert_eq "$expected" "$(cat "$STDOUT_FILE")" 'Herdr verify grammar and final native inventory are exact' || return 1

  reset_state
  printf 'H2\n' >"$HERDR_NAMES_FILE"
  run_core env HMW_BACKEND=herdr HMW_REMOTE=1 HMW_VERIFY=1 \
    HERDR_UNNAMED_LABEL=H1 HERDR_UNNAMED_PANE_ID=w1:pB "$CORE" 2 || return 1
  assert_not_contains "$LOG" $'agent\tstart\tH1' 'pane label reuses an unnamed detected H1 agent' || return 1
  assert_not_contains "$LOG" $'agent\tstart\tH2' 'named H2 remains reusable beside unnamed H1' || return 1
  assert_contains "$LOG" $'agent\tfocus\tw1:pB' 'pane-label fallback focuses unnamed H1 by pane id' || return 1
  assert_contains "$STDOUT_FILE" '"pane_id":"w1:pB"' 'native verify inventory preserves the unnamed agent evidence' || return 1

  reset_state
  set +e
  run_core env HMW_BACKEND=herdr HMW_REMOTE=1 HMW_VERIFY=1 HERDR_MALFORMED=1 "$CORE" 2
  status=$?
  set -e
  assert_eq 1 "$status" 'malformed Herdr JSON fails closed' || return 1
  assert_contains "$STDERR_FILE" 'malformed agent inventory' 'malformed JSON gives actionable diagnostic' || return 1
  assert_not_contains "$LOG" $'agent\tstart' 'malformed JSON creates no agents' || return 1
  assert_not_contains "$STDOUT_FILE" 'inventory-end' 'malformed JSON omits verify trailer' || return 1

  reset_state
  printf 'H1\n' >"$HERDR_NAMES_FILE"
  run_core env HMW_BACKEND=herdr HMW_REMOTE=1 HMW_HERDR_VERIFY=1 "$CORE" 1 || return 1
  assert_contains "$STDOUT_FILE" 'HMW_VERIFY backend=herdr' 'legacy verify variable remains compatible' || return 1
  assert_not_contains "$STDERR_FILE" 'warning' 'legacy verify emits no warning' || return 1

  reset_state
  printf 'H1\n' >"$HERDR_NAMES_FILE"
  run_core env HMW_BACKEND=herdr HMW_REMOTE=1 HMW_VERIFY=0 HMW_HERDR_VERIFY=1 "$CORE" 1 || return 1
  assert_not_contains "$STDOUT_FILE" 'HMW_VERIFY' 'HMW_VERIFY wins over legacy compatibility variable' || return 1
  assert_exact_line_count 1 "$LOG" $'herdr\t--session\tws' 'nonverify Herdr attaches with scoped prefix only' || return 1

  reset_state
  run_core env HMW_BACKEND=herdr HMW_REMOTE=1 HMW_VERIFY=1 HERDR_NEW_API=1 "$CORE" 2 || {
    printf '  new API stderr:\n' >&2
    cat "$STDERR_FILE" >&2
    printf '  new API calls:\n' >&2
    cat "$LOG" >&2
    return 1
  }
  assert_contains "$LOG" $'workspace\tcreate\t--cwd\t' 'new Herdr API creates the initial workspace pane' || return 1
  assert_contains "$LOG" $'pane\trename\tw1:p1\tH1' 'new Herdr API labels H1 explicitly' || return 1
  assert_contains "$LOG" $'pane\trun\tw1:p1\thermes-pane H1' 'new Herdr API starts Hermes in H1' || return 1
  assert_contains "$LOG" $'pane\tsplit\tw1:p1\t--direction\tright\t--no-focus' 'new Herdr API splits subsequent panes from H1' || return 1
  assert_contains "$LOG" $'pane\trename\tw1:p2\tH2' 'new Herdr API labels H2 explicitly' || return 1
  assert_contains "$LOG" $'pane\trun\tw1:p2\thermes-pane H2' 'new Herdr API starts Hermes in H2' || return 1
  assert_not_contains "$LOG" $'agent\tstart\tH1\t--split' 'new Herdr API avoids removed create-and-split grammar' || return 1
  pass 'Herdr exact-label add-only behavior, JSON safety, and verify compatibility'
}

test_herdr_concurrent_start_reconciliation() {
  local status

  reset_state
  run_core env HMW_BACKEND=herdr HMW_REMOTE=1 HMW_VERIFY=1 \
    HERDR_START_FAIL_LABEL=H1 HERDR_START_FAIL_ADD=1 "$CORE" 1 || return 1
  assert_contains "$LOG" $'agent\tstart\tH1\t--split\tright\t--no-focus\t--\thermes-pane\tH1' 'competing launch still attempts the exact start grammar' || return 1
  assert_eq 3 "$(cat "$HERDR_LIST_COUNT")" 'failed start re-inventories immediately and once after additions' || return 1
  assert_contains "$LOG" $'agent\tfocus\tH1' 'competing launcher result continues to focus H1' || return 1
  assert_contains "$STDOUT_FILE" '{"name":"H1"}' 'competing launcher result appears in final verify inventory' || return 1

  reset_state
  set +e
  run_core env HMW_BACKEND=herdr HMW_REMOTE=1 HMW_VERIFY=1 \
    HERDR_START_FAIL_LABEL=H1 HERDR_START_FAIL_ADD=0 "$CORE" 1
  status=$?
  set -e
  assert_eq 1 "$status" 'failed start without a competing name fails' || return 1
  assert_eq 2 "$(cat "$HERDR_LIST_COUNT")" 'failed start performs one bounded reconciliation inventory' || return 1
  assert_contains "$STDERR_FILE" "agent start failed for H1 in session 'ws'" 'failed start diagnostic names the slot and session' || return 1
  assert_contains "$STDERR_FILE" 'still absent after inventory refresh' 'failed start diagnostic explains reconciliation result' || return 1
  assert_contains "$STDERR_FILE" 'inspect Herdr server output and retry' 'failed start diagnostic is actionable' || return 1
  assert_not_contains "$LOG" $'agent\tfocus' 'unreconciled failed start does not focus' || return 1
  assert_not_contains "$STDOUT_FILE" 'inventory-end' 'unreconciled failed start omits verify success trailer' || return 1
  pass 'Herdr concurrent starts reconcile exact names and fail closed otherwise'
}

test_wrapper_forwarding() {
  local wrapper_bin status
  reset_state
  wrapper_bin="$TEST_TMP/wrapper-bin"
  mkdir -p "$wrapper_bin"
  cat >"$wrapper_bin/hermes-workspace" <<'EOF'
#!/usr/bin/env bash
printf 'backend=<%s>\n' "${HMW_BACKEND-}"
printf 'session=<%s>\n' "${HERDR_SESSION-}"
for arg in "$@"; do printf 'arg=<%s>\n' "$arg"; done
exit 37
EOF
  chmod +x "$wrapper_bin/hermes-workspace"
  set +e
  # Literal metacharacters verify argv preservation.
  # shellcheck disable=SC2016
  HERDR_SESSION="s \"quote\" ; space" HMW_BACKEND=tmux PATH="$wrapper_bin:/usr/local/bin:/usr/bin:/bin" \
    "$WRAPPER" 'host name;$(touch nope)' '3 & * ? [x]' >"$STDOUT_FILE" 2>"$STDERR_FILE"
  status=$?
  set -e
  assert_eq 37 "$status" 'wrapper returns core exit status' || return 1
  expected=$(cat <<'EOF'
backend=<herdr>
session=<s "quote" ; space>
arg=<host name;$(touch nope)>
arg=<3 & * ? [x]>
EOF
)
  assert_eq "$expected" "$(cat "$STDOUT_FILE")" 'wrapper preserves argv and session while forcing Herdr' || return 1

  set +e
  # Literal metacharacters verify argv preservation.
  # shellcheck disable=SC2016
  HMW_BACKEND=herdr PATH="$wrapper_bin:/usr/local/bin:/usr/bin:/bin" \
    "$TMUX_WRAPPER" 'host name;$(touch nope)' '3 & * ? [x]' >"$STDOUT_FILE" 2>"$STDERR_FILE"
  status=$?
  set -e
  assert_eq 37 "$status" 'tmux wrapper returns core exit status' || return 1
  expected=$(cat <<'EOF'
backend=<tmux>
session=<>
arg=<host name;$(touch nope)>
arg=<3 & * ? [x]>
EOF
)
  assert_eq "$expected" "$(cat "$STDOUT_FILE")" 'tmux wrapper preserves argv while forcing tmux' || return 1
  pass 'backend-selecting wrappers are transparent'
}

main() {
  local test
  set -e
  for test in \
    test_argument_and_default_parity \
    test_invalid_requests \
    test_remote_dispatch_and_reentry \
    test_tmux_preservation_and_verify \
    test_tmux_legacy_adoption \
    test_tmux_literal_backslash_tab_fixture \
    test_bash32_compatibility \
    test_real_tmux_integration \
    test_herdr_prerequisite_scoping_and_readiness \
    test_herdr_add_only_json_and_verify \
    test_herdr_concurrent_start_reconciliation \
    test_wrapper_forwarding; do
    if ! "$test"; then
      printf 'FAILED: %s\n' "$test" >&2
      exit 1
    fi
  done
  printf '%s tests passed\n' "$PASS"
}

main "$@"
