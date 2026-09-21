#!/usr/bin/env bash
# 98-hermes-native-bots: fleet defaults for native Hermes Desktop + authenticated Bot API.

set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$MODULE_DIR/.." && pwd)}"
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/common.sh"

if [[ -z "${SKIP_KEYS+x}" ]]; then
  SKIP_KEYS=()
fi
if [[ ${#SKIP_KEYS[@]} -eq 0 && -n "${HERMES_SKIP:-}" ]]; then
  IFS=',' read -r -a SKIP_KEYS <<<"$HERMES_SKIP"
fi

step "Hermes native Desktop + Bot API defaults"

if is_skipped native-bots; then
  skip "native-bots — opted out via --skip"
  return 0 2>/dev/null || exit 0
fi

if ! tier_allows R; then
  skip "native-bots requires recommended/full tier"
  return 0 2>/dev/null || exit 0
fi

helper_src="$REPO_ROOT/scripts/hermes-native-bots"
helper_dst="$HOME/.local/bin/hermes-native-bots"
[[ -x "$helper_src" ]] || { err "missing executable helper script: $helper_src"; exit 1; }
mkdir -p "$HOME/.local/bin" || { err "cannot create $HOME/.local/bin"; exit 1; }
if [[ -e "$helper_dst" && ! -L "$helper_dst" ]]; then
  err "helper path conflict: $helper_dst exists and is not a symlink"
  exit 1
fi
ln -sfn "$helper_src" "$helper_dst" || { err "failed to link $helper_dst"; exit 1; }
ok "hermes-native-bots → $helper_dst"

receipt_dir() {
  local dir="${HERMES_HOME:-$HOME/.hermes}/runtime"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

write_receipt() {
  local name="$1" payload="$2" dir
  dir="$(receipt_dir)"
  printf '%s\n' "$payload" >"$dir/$name"
  chmod 600 "$dir/$name" 2>/dev/null || true
}

find_hermes_cli() {
  local candidate
  for candidate in "${HERMES_NATIVE_BOTS_HERMES_BIN:-}" "$HOME/.local/bin/hermes" /usr/local/bin/hermes /usr/local/lib/hermes-agent/venv/bin/hermes hermes; do
    [[ -n "$candidate" ]] || continue
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
    [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

configure_api() {
  local tailscale_bin tailscale_ip receipt
  if ! tailscale_bin="$(find_tailscale 2>/dev/null)"; then
    err "native Bot API not configured: tailscale CLI unavailable (no fallback bind)"
    return 1
  fi
  tailscale_ip="$("$tailscale_bin" ip -4 2>/dev/null | sed -n '1p' || true)"
  if [[ -z "$tailscale_ip" ]]; then
    err "native Bot API not configured: no local Tailscale IPv4 (no fallback bind)"
    return 1
  fi

  receipt="$(HERMES_NATIVE_BOTS_TAILSCALE_IP="$tailscale_ip" "$helper_dst" configure-api --host "$tailscale_ip" --port 8642 2>&1)" || {
    err "native Bot API configuration failed"
    printf '%s\n' "$receipt" >&2
    return 1
  }
  write_receipt "native-bots-api.json" "$receipt"
  if [[ "$receipt" == *'"restart_pending":true'* ]]; then
    ok "native Bot API env configured for Tailscale bind (gateway restart pending; run hermes-native-bots apply-api after backup)"
  else
    ok "native Bot API env configured for Tailscale bind"
  fi
}

desktop_source_verified() {
  local status
  status="$("$helper_dst" status-desktop 2>/dev/null || true)"
  [[ "$status" == *'"source_verified":true'* ]]
}

build_desktop_if_needed() {
  desktop_source_verified && return 0
  local hermes
  hermes="$(find_hermes_cli || true)"
  [[ -n "$hermes" ]] || { err "Hermes Desktop build failed: hermes CLI not found"; return 1; }
  info "building Hermes Desktop package"
  "$hermes" desktop --build-only || { err "Hermes Desktop build failed"; return 1; }
  desktop_source_verified || { err "Hermes Desktop build completed but no verified Hermes.app was found"; return 1; }
}

configure_desktop() {
  if [[ "$OS" != "macos" ]]; then
    skip "Hermes Desktop launcher is macOS-only"
    return 0
  fi
  if ! role_includes client; then
    skip "role=$ROLE — Hermes Desktop launcher only installs on client/both"
    return 0
  fi
  local receipt
  build_desktop_if_needed
  receipt="$("$helper_dst" configure-desktop 2>&1)" || {
    err "Hermes Desktop launcher configuration failed"
    printf '%s\n' "$receipt" >&2
    return 1
  }
  write_receipt "native-bots-desktop.json" "$receipt"
  ok "Hermes Desktop LaunchAgent configured and app launched"
}

configure_api
configure_desktop

ok "Hermes native Desktop + Bot API defaults applied"
