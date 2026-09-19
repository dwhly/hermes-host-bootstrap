#!/usr/bin/env bash
# h-btp-only bridge for /opt/hermes/hermes-cli.sh.
#
# Keep root's /usr/local/bin/hermes shim usable while executing the existing
# Hermes install as the existing hermes account, without su-login shell
# evaluation, a new PTY, or inherited root credential environment.

set -euo pipefail

HERMES_USER="hermes"
HERMES_ACCOUNT_HOME="/home/hermes"
HERMES_HOME_VALUE="/home/hermes/.hermes"
HERMES_BIN_VALUE="${HBTP_HERMES_BIN:-/home/hermes/.local/bin/hermes}"
HERDR_BIN_PATH_VALUE="/home/hermes/.local/bin/herdr"
HERMES_SHELL_VALUE="${HBTP_HERMES_SHELL:-/bin/bash}"
HERMES_PATH_VALUE="${HBTP_HERMES_PATH:-/home/hermes/.local/bin:/usr/local/bin:/usr/bin:/bin}"
BRIDGE_CWD="${HBTP_HERMES_CWD:-/home/hermes}"
RUNUSER_BIN="${HBTP_RUNUSER_BIN:-/usr/sbin/runuser}"
ID_BIN="${HBTP_ID_BIN:-id}"
ENV_BIN="${HBTP_ENV_BIN:-/usr/bin/env}"

cd "$BRIDGE_CWD"

env_args=(
  "HOME=$HERMES_ACCOUNT_HOME"
  "USER=$HERMES_USER"
  "LOGNAME=$HERMES_USER"
  "SHELL=$HERMES_SHELL_VALUE"
  "PATH=$HERMES_PATH_VALUE"
  "PWD=$PWD"
  "HERMES_HOME=$HERMES_HOME_VALUE"
  "HERDR_BIN_PATH=$HERDR_BIN_PATH_VALUE"
)

forward_if_set() {
  local name="$1"
  if [[ ${!name+x} ]]; then
    env_args+=("$name=${!name}")
  fi
}

for name in \
  TERM COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION NO_COLOR FORCE_COLOR CLICOLOR CLICOLOR_FORCE \
  LANG LANGUAGE LC_ALL LC_COLLATE LC_CTYPE LC_MESSAGES LC_MONETARY LC_NUMERIC LC_TIME TZ \
  HERDR_ENV HERDR_SESSION HERDR_PANE_ID HERDR_SOCKET HERDR_SOCKET_PATH HERDR_SERVER_SOCKET \
  HERDR_WORKSPACE HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_AGENT_ID NO_TMUX
do
  forward_if_set "$name"
done

target_uid="$("$ID_BIN" -u "$HERMES_USER")"
current_uid="$("$ID_BIN" -u)"
target_command=("$ENV_BIN" -i "${env_args[@]}" "$HERMES_BIN_VALUE" "$@")

if [[ "$current_uid" == "$target_uid" ]]; then
  exec "${target_command[@]}"
fi

exec "$ENV_BIN" -i PATH="/usr/sbin:/usr/bin:/sbin:/bin" \
  "$RUNUSER_BIN" -u "$HERMES_USER" -- "${target_command[@]}"
