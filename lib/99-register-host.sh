#!/usr/bin/env bash
# 99-register-host: write a snapshot of this machine into ~/.hermes/hosts/<hostname>.yaml
# so the host shows up in fleet dashboards / inventories. Runs near the end of
# bootstrap, after all other modules — the snapshot reflects what THIS run installed.
#
# The yaml is intentionally human-readable and append-friendly: subsequent
# bootstrap runs overwrite the file with the latest state. A separate
# `hermes-fleet refresh` command (see scripts/hermes-fleet) can be cronned to
# keep live fields (uptime, disk, mem) current between bootstrap runs.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Host registry snapshot"

if is_skipped host-registry; then
  skip "host-registry — opted out via --skip"
  return 0 2>/dev/null || exit 0
fi

# Where the registry lives. ~/.hermes/ is the synced config dir, so the file
# will roll forward to other machines via hermes-config-sync.
REGISTRY_DIR="${HERMES_HOME:-$HOME/.hermes}/hosts"
mkdir -p "$REGISTRY_DIR"

# ── Gather facts ──────────────────────────────────────────────────────
HOSTNAME_VAL="$(hostname -s 2>/dev/null || hostname)"
FQDN_VAL="$(hostname -f 2>/dev/null || echo "$HOSTNAME_VAL")"
OS_KIND="$OS"

if [[ "$OS_KIND" == "macos" ]]; then
  OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
  OS_PRETTY="macOS $OS_VERSION"
  ARCH="$(uname -m)"
  KERNEL="$(uname -sr)"
else
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_PRETTY="${PRETTY_NAME:-$NAME $VERSION}"
    OS_VERSION="${VERSION_ID:-unknown}"
  else
    OS_PRETTY="$(uname -sr)"
    OS_VERSION="unknown"
  fi
  ARCH="$(uname -m)"
  KERNEL="$(uname -r)"
fi

# Public IP (best-effort, no failure on offline)
PUBLIC_IP="$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || echo unknown)"
# Local non-loopback IPs
if [[ "$OS_KIND" == "macos" ]]; then
  LOCAL_IPS="$(ipconfig getifaddr en0 2>/dev/null || true)"
else
  LOCAL_IPS="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
fi

# Tailscale name (if installed and authed)
TAILSCALE_NAME="$(tailscale status --self --json 2>/dev/null | \
                  python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("Self",{}).get("DNSName","").rstrip("."))' \
                  2>/dev/null || echo "")"

# Tool versions (each one tolerant of "not installed")
get_ver() { eval "$1" 2>/dev/null | head -n 1 || echo "not installed"; }
HERMES_VER="$(get_ver 'hermes --version')"
NODE_VER="$(get_ver 'node --version')"
PYTHON_VER="$(get_ver 'python3 --version')"
DOCKER_VER="$(get_ver 'docker --version')"
TMUX_VER="$(get_ver 'tmux -V')"
MOSH_VER="$(mosh --version 2>/dev/null | head -n 1 || echo "not installed")"
GIT_VER="$(get_ver 'git --version')"

# Resource snapshot
if [[ "$OS_KIND" == "macos" ]]; then
  TOTAL_MEM_MB="$(($(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024))"
  TOTAL_DISK="$(df -h / | awk 'NR==2{print $2}')"
  USED_DISK_PCT="$(df -h / | awk 'NR==2{print $5}')"
  CPU_MODEL="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
  CPU_COUNT="$(sysctl -n hw.ncpu 2>/dev/null || echo unknown)"
else
  TOTAL_MEM_MB="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo unknown)"
  TOTAL_DISK="$(df -h / | awk 'NR==2{print $2}')"
  USED_DISK_PCT="$(df -h / | awk 'NR==2{print $5}')"
  CPU_MODEL="$(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null | sed 's/^ //' || echo unknown)"
  CPU_COUNT="$(nproc 2>/dev/null || echo unknown)"
fi

UPTIME_DAYS="$(awk '{print int($1/86400)}' /proc/uptime 2>/dev/null || echo 0)"

# Note: preserve any existing note when re-running (don't blank it out
# unless the bootstrap.sh interactive prompt or HERMES_HOST_NOTE env
# explicitly set a new value).
HOST_NOTE="${HERMES_HOST_NOTE:-}"
TARGET_TMP_CHECK="$REGISTRY_DIR/${HOSTNAME_VAL}.yaml"
if [[ -z "$HOST_NOTE" ]] && [[ -f "$TARGET_TMP_CHECK" ]]; then
  HOST_NOTE="$(awk -F': ' '/^note:/ {sub(/^note:[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit}' "$TARGET_TMP_CHECK" 2>/dev/null)"
fi

# ── Write yaml ────────────────────────────────────────────────────────
TARGET="$REGISTRY_DIR/${HOSTNAME_VAL}.yaml"
NOW_ISO="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
# Preserve first-install date across re-runs. The yaml stores
# installed_at indented two spaces under `bootstrap:`, so the regex
# matches optional leading whitespace.
INSTALLED_AT="$NOW_ISO"
if [[ -f "$TARGET" ]]; then
  PREV="$(awk -F': ' '/^[[:space:]]*installed_at:/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' "$TARGET" 2>/dev/null || echo "")"
  [[ -n "$PREV" ]] && INSTALLED_AT="$PREV"
fi

cat > "$TARGET" <<YAML
# hermes-host-bootstrap host snapshot
# This file is updated on every bootstrap run. Edit manually only if you
# know what you're doing — the next bootstrap rewrites most fields.
hostname: $HOSTNAME_VAL
fqdn: $FQDN_VAL
note: "${HOST_NOTE}"
tailscale_name: "${TAILSCALE_NAME}"
public_ip: "$PUBLIC_IP"
local_ip: "${LOCAL_IPS:-unknown}"

os:
  kind: $OS_KIND
  pretty: "$OS_PRETTY"
  version: "$OS_VERSION"
  arch: $ARCH
  kernel: "$KERNEL"

bootstrap:
  tier: $TIER
  role: $ROLE
  installed_at: $INSTALLED_AT
  last_run_at: $NOW_ISO

resources:
  cpu_model: "$CPU_MODEL"
  cpu_count: $CPU_COUNT
  total_mem_mb: $TOTAL_MEM_MB
  total_disk: $TOTAL_DISK
  disk_used_pct: "$USED_DISK_PCT"
  uptime_days: $UPTIME_DAYS

versions:
  hermes: "$HERMES_VER"
  node: "$NODE_VER"
  python: "$PYTHON_VER"
  docker: "$DOCKER_VER"
  tmux: "$TMUX_VER"
  mosh: "$MOSH_VER"
  git: "$GIT_VER"
YAML

ok "host registry: $TARGET"

# ── Install hermes-fleet on PATH ──────────────────────────────────────
# The dashboard script ships in scripts/ of this repo; link it into
# ~/.local/bin so the user can run `hermes-fleet` from anywhere.
if [[ -f "$REPO_ROOT/scripts/hermes-fleet" ]]; then
  mkdir -p "$HOME/.local/bin"
  TARGET_LINK="$HOME/.local/bin/hermes-fleet"
  if [[ -L "$TARGET_LINK" || -f "$TARGET_LINK" ]]; then
    rm -f "$TARGET_LINK"
  fi
  ln -s "$REPO_ROOT/scripts/hermes-fleet" "$TARGET_LINK"
  ok "hermes-fleet → $TARGET_LINK"
fi

# ── Install hermes-reload on PATH ─────────────────────────────────────
# Companion to hermes-fleet: scripts/reload.sh is the canonical way to
# "pull latest bootstrap and re-apply on this host." Symlinked so the
# user can `hermes-reload` from anywhere, and aliased to `r` in
# dotfiles/aliases.sh for one-keystroke daily use.
if [[ -f "$REPO_ROOT/scripts/reload.sh" ]]; then
  mkdir -p "$HOME/.local/bin"
  TARGET_LINK="$HOME/.local/bin/hermes-reload"
  if [[ -L "$TARGET_LINK" || -f "$TARGET_LINK" ]]; then
    rm -f "$TARGET_LINK"
  fi
  ln -s "$REPO_ROOT/scripts/reload.sh" "$TARGET_LINK"
  ok "hermes-reload → $TARGET_LINK"
fi

# Helpful hint for the user: if ~/.hermes is git-tracked (the typical
# hermes-config-sync setup), nudge them to commit the snapshot.
if [[ -d "${HERMES_HOME:-$HOME/.hermes}/.git" ]]; then
  info "hosts/${HOSTNAME_VAL}.yaml is in a git-tracked ~/.hermes — run"
  info "  ~/.hermes/sync.sh save \"register host $HOSTNAME_VAL\""
  info "to share this snapshot with your other machines."
fi
