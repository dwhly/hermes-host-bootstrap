#!/usr/bin/env bash
# Common helpers sourced by every module.
# DO NOT execute directly — use ../bootstrap.sh.

set -euo pipefail

# ── Logging ──────────────────────────────────────────────────────────
_C_RESET=$'\033[0m'; _C_DIM=$'\033[2m'; _C_BOLD=$'\033[1m'
_C_BLUE=$'\033[34m'; _C_GREEN=$'\033[32m'; _C_YELLOW=$'\033[33m'; _C_RED=$'\033[31m'

log()   { printf '%s[%s]%s %s\n' "$_C_DIM" "$(date +%H:%M:%S)" "$_C_RESET" "$*"; }
info()  { printf '%s▸%s %s\n' "$_C_BLUE" "$_C_RESET" "$*"; }
ok()    { printf '%s✓%s %s\n' "$_C_GREEN" "$_C_RESET" "$*"; }
warn()  { printf '%s⚠%s %s\n' "$_C_YELLOW" "$_C_RESET" "$*" >&2; }
err()   { printf '%s✗%s %s\n' "$_C_RED" "$_C_RESET" "$*" >&2; }
step()  { printf '\n%s%s┄┄ %s ┄┄%s\n' "$_C_BOLD" "$_C_BLUE" "$*" "$_C_RESET"; }
skip()  { printf '%s∘%s %s\n' "$_C_DIM" "$_C_RESET" "$*"; }

# ── Platform detection ──────────────────────────────────────────────
detect_os() {
  if [[ "$(uname -s)" == "Darwin" ]]; then echo "macos"; return; fi
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "${ID:-unknown}"
    return
  fi
  echo "unknown"
}

OS="$(detect_os)"
ARCH="$(uname -m)"
IS_HEADLESS=1
# crude headless check: no DISPLAY, no WAYLAND_DISPLAY, no /Applications
if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" || -d /Applications ]]; then
  IS_HEADLESS=0
fi

# ── Idempotency primitives ──────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

# apt_install — install only packages that aren't already installed
apt_install() {
  local missing=()
  for pkg in "$@"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing+=("$pkg")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    skip "all already installed: $*"
    return 0
  fi
  info "apt install: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive sudo -E apt-get install -y -q "${missing[@]}"
}

# apt_refresh — `apt-get update` at most once per bootstrap run
APT_REFRESHED=0
apt_refresh() {
  if [[ "$APT_REFRESHED" -eq 1 ]]; then return 0; fi
  info "apt-get update"
  sudo apt-get update -q
  APT_REFRESHED=1
}

# ensure_line — append a line to a file iff not already present
ensure_line() {
  local line="$1"
  local file="$2"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if ! grep -qsxF "$line" "$file"; then
    printf '%s\n' "$line" >> "$file"
    ok "added to $file: $line"
  else
    skip "already in $file: $line"
  fi
}

# backup_once — copy a file to .bak.YYYYmmdd if no backup exists yet
backup_once() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local bak="${f}.bak.$(date +%Y%m%d)"
  if [[ ! -f "$bak" ]]; then
    sudo cp -a "$f" "$bak"
    ok "backed up $f → $bak"
  fi
}

# require_root_or_sudo — bail early if we can't sudo
require_sudo() {
  if [[ $EUID -eq 0 ]]; then return 0; fi
  if ! sudo -n true 2>/dev/null; then
    info "this step needs sudo; you may be prompted for your password"
    sudo -v
  fi
}

# tier filter — modules check $TIER before running their tier-N blocks
# values: minimal | recommended | full
tier_allows() {
  local item_tier="$1"
  case "$TIER" in
    minimal)     [[ "$item_tier" == "E" ]] ;;
    recommended) [[ "$item_tier" == "E" || "$item_tier" == "R" ]] ;;
    full)        true ;;
    *)           false ;;
  esac
}

# is_skipped — was this module/keyword passed via --skip?
is_skipped() {
  local key="$1"
  local s
  for s in "${SKIP_KEYS[@]:-}"; do
    [[ "$s" == "$key" ]] && return 0
  done
  return 1
}
