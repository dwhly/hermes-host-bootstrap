#!/usr/bin/env bash
# 42-herdr: Herdr — "the tmux for AI agents", an agent multiplexer (Rust binary).
# https://github.com/ogulcancelik/herdr  ·  https://herdr.dev
#
# Fleet model (package-add 3-part contract, see fleet-management playbook):
#   1) this install module (auto-discovered by the bootstrap glob),
#   2) a tiers/<tier>.txt manifest entry,
#   3) version tracking in lib/99-register-host.sh (*_VER + versions:).
# Plus a verify.sh verify_check for console visibility.
#
# WHY a release-binary install (not `curl … | sh`): herdr ships per-OS/arch static
# binaries on GitHub releases; downloading the exact asset to ~/.local/bin is
# reproducible and avoids piping a remote script into a shell. Herdr runs a
# PER-HOST server that multiplexes THAT host's local PTYs (the hermes sessions on
# that node), so every node that runs agents needs its own herdr. See the herdr
# research page in the automation wiki for the fleet-fit rationale.
#
# Also symlinks the `hmw-herdr` backend-selecting wrapper (scripts/hmw-herdr.sh)
# so the Herdr-backed workspace is reachable on PATH like hmw. Skip key: herdr.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

step "Herdr (agent multiplexer)"

# Recommended tier (R): a useful agent/dev tool, not essential to a base node.
if ! tier_allows R; then
  skip "herdr skipped (tier below R)"
  return 0 2>/dev/null || exit 0
fi
if is_skipped herdr; then
  skip "herdr skipped (HERMES_SKIP includes herdr)"
  return 0 2>/dev/null || exit 0
fi

install_dir="$HOME/.local/bin"
mkdir -p "$install_dir"

# ── Map OS + ARCH → the herdr release asset name ──────────────────────────
# common.sh: OS ∈ {macos, ubuntu, debian, ...}; ARCH = uname -m
os_tag=""; arch_tag=""
case "$OS" in
  macos) os_tag="macos" ;;
  *)     os_tag="linux" ;;   # ubuntu/debian/etc → linux binary
esac
case "$ARCH" in
  arm64|aarch64) arch_tag="aarch64" ;;
  x86_64|amd64)  arch_tag="x86_64" ;;
  *) warn "herdr: unsupported arch '$ARCH' — skipping"; return 0 2>/dev/null || exit 0 ;;
esac
asset="herdr-${os_tag}-${arch_tag}"

# ── Install the binary if missing ─────────────────────────────────────────
if have herdr || [[ -x "$install_dir/herdr" ]]; then
  skip "herdr already installed: $("$install_dir/herdr" --version 2>/dev/null | head -1 || herdr --version 2>/dev/null | head -1 || echo present)"
else
  info "installing herdr release binary ($asset) → $install_dir"
  url="https://github.com/ogulcancelik/herdr/releases/latest/download/${asset}"
  tmp="$(mktemp)"
  if curl -fsSL "$url" -o "$tmp" && [[ -s "$tmp" ]]; then
    install -m 0755 "$tmp" "$install_dir/herdr"
    rm -f "$tmp"
    if "$install_dir/herdr" --version >/dev/null 2>&1; then
      ok "herdr installed: $("$install_dir/herdr" --version 2>/dev/null | head -1)"
    else
      warn "herdr binary installed but --version failed — check $install_dir/herdr"
    fi
  else
    rm -f "$tmp"
    warn "herdr download failed ($url) — install manually: https://herdr.dev/docs/install/"
    return 0 2>/dev/null || exit 0
  fi
fi

# ── Symlink the hmw-herdr backend wrapper onto PATH (like hmw) ─────────────
if [[ -f "$REPO_ROOT/scripts/hmw-herdr.sh" ]]; then
  chmod +x "$REPO_ROOT/scripts/hmw-herdr.sh" 2>/dev/null || true
  ln -sf "$REPO_ROOT/scripts/hmw-herdr.sh" "$install_dir/hmw-herdr"
  ok "linked hmw-herdr → $install_dir/hmw-herdr (shared Herdr workspace backend)"
fi

# ── Install the Hermes agent-state integration ────────────────────────────
# Without this, herdr can't tell a Hermes pane's state and the sidebar always
# shows "idle". The integration is a Hermes plugin
# (~/.hermes/plugins/herdr-agent-state/) that reports working/blocked/idle from
# Hermes lifecycle hooks (pre_llm_call→working, pre_approval_request→blocked,
# post_llm_call→idle) to herdr's socket when running inside a herdr pane.
# Idempotent: `herdr integration install hermes` re-installs/updates in place.
herdr_bin="$install_dir/herdr"; have herdr && herdr_bin="herdr"
if "$herdr_bin" integration status 2>/dev/null | grep -q "hermes: current"; then
  skip "herdr hermes integration already current"
else
  info "installing herdr↔hermes agent-state integration (fixes 'always idle' sidebar)"
  if "$herdr_bin" integration install hermes 2>&1 | grep -qiE "installed|enabled|current"; then
    ok "herdr hermes integration installed ($("$herdr_bin" integration status 2>/dev/null | grep -o 'hermes: [^(]*' | head -1))"
  else
    warn "herdr hermes integration install failed — run: herdr integration install hermes"
  fi
fi
