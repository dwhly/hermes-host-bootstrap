#!/usr/bin/env bash
# M5-mac-client: macOS client-side setup — Microsoft Remote Desktop, Tailscale GUI,
# a couple of optional CLI niceties. Only runs on macOS with role=client/both.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "macOS client-side apps"

if [[ "$OS" != "macos" ]]; then
  skip "not macOS — skipping mac-client module"
  return 0 2>/dev/null || exit 0
fi

if ! role_includes client; then
  skip "role=$ROLE — mac-client module only runs on client/both"
  return 0 2>/dev/null || exit 0
fi

if ! have brew; then
  warn "Homebrew missing — run 20-buildchain first or install from https://brew.sh"
  return 0 2>/dev/null || exit 0
fi

# Microsoft Remote Desktop — for connecting to the xrdp server we set up on Linux
if ! is_skipped ms-remote-desktop; then
  if [[ -d "/Applications/Microsoft Remote Desktop.app" ]] || \
     [[ -d "/Applications/Windows App.app" ]]; then
    # Microsoft renamed it to "Windows App" in 2024 — both names cover that
    skip "Microsoft Remote Desktop / Windows App already installed"
  else
    info "installing Microsoft Remote Desktop"
    brew install --cask windows-app || \
      brew install --cask microsoft-remote-desktop || \
      warn "could not install Remote Desktop cask — get it from the Mac App Store"
  fi
fi

# Tailscale GUI app (separate from the CLI in 70-network.sh — the cask gives you
# the menu-bar widget). Brew handles the dedupe.
if ! is_skipped tailscale-gui; then
  if [[ ! -d /Applications/Tailscale.app ]]; then
    info "installing Tailscale GUI"
    brew install --cask tailscale-app 2>/dev/null || brew install --cask tailscale || true
  else
    skip "Tailscale app already installed"
  fi
fi

# Rectangle — keyboard-driven window snapping. Tiny, universally loved.
if tier_allows N && ! is_skipped rectangle; then
  if [[ ! -d /Applications/Rectangle.app ]]; then
    info "installing Rectangle (window snapping)"
    brew install --cask rectangle || true
  fi
fi

# Raycast — Spotlight replacement. Lots of Hermes users love it.
if tier_allows N && ! is_skipped raycast; then
  if [[ ! -d /Applications/Raycast.app ]]; then
    info "installing Raycast (Spotlight replacement)"
    brew install --cask raycast || true
  fi
fi

ok "macOS client setup complete"

echo ""
info "Next steps on this Mac:"
echo "    1. Launch Ghostty — settings already configured at ~/.config/ghostty/config"
echo "    2. Launch Tailscale, sign in, and you'll see your VPS in the menu bar"
echo "    3. To reach your VPS desktop:"
echo "         ssh -L 3389:localhost:3389 you@vps    # tunnel"
echo "         (then open Windows App / Remote Desktop, connect to localhost:3389)"
echo ""
