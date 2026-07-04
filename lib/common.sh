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

# macOS noninteractive shells (ssh host 'cmd', launchd, bootstrap reruns) often
# start with /usr/bin:/bin:/usr/sbin:/sbin only, so Homebrew is invisible even
# when it is installed. Put the canonical Homebrew prefixes on PATH before any
# module calls `have brew` or invokes brew-installed tools.
if [[ "$OS" == "macos" ]]; then
  PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
  export PATH
fi

# Tailscale's GUI app on macOS ships a CLI binary inside the .app bundle but
# does not always put it on PATH. Keep this lookup centralized so registry and
# network modules don't mistake "CLI not on PATH" for "Tailscale unavailable".
find_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    command -v tailscale
    return 0
  fi
  if [[ -x /Applications/Tailscale.app/Contents/MacOS/tailscale ]]; then
    printf '%s\n' /Applications/Tailscale.app/Contents/MacOS/tailscale
    return 0
  fi
  if [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
    printf '%s\n' /Applications/Tailscale.app/Contents/MacOS/Tailscale
    return 0
  fi
  return 1
}

IS_HEADLESS=1
# crude headless check: no DISPLAY, no WAYLAND_DISPLAY, no /Applications
if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" || -d /Applications ]]; then
  IS_HEADLESS=0
fi

# ── Role detection ──────────────────────────────────────────────────
# Roles answer "what is this machine *for*?":
#   server — a headless box you ssh INTO (a VPS). No GUI client apps.
#   client — a personal machine you ssh FROM (your Mac). No server-side
#            daemons like xrdp. Gets Ghostty, MS Remote Desktop, etc.
#   both   — a desktop Linux you use AS your daily driver AND as a host.
#            Gets both sides.
# Auto-detected if --role wasn't passed; can be overridden explicitly.
auto_detect_role() {
  if [[ "$OS" == "macos" ]]; then
    echo "client"
    return
  fi
  # Linux: headless box = server; desktop Linux = both
  if [[ "$IS_HEADLESS" -eq 1 ]]; then
    echo "server"
  else
    echo "both"
  fi
}
ROLE="${ROLE:-$(auto_detect_role)}"

role_includes() {
  # role_includes server  → true if ROLE is server or both
  # role_includes client  → true if ROLE is client or both
  local want="$1"
  case "$ROLE" in
    both) return 0 ;;
    "$want") return 0 ;;
    *) return 1 ;;
  esac
}

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
  # Default to bootstrap's own default tier if TIER is unset — lets a module be
  # run standalone (e.g. `bash lib/NN-x.sh` for debugging) without crashing under
  # `set -u`. Through bootstrap.sh, TIER is always exported so this is a no-op.
  case "${TIER:-recommended}" in
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
