#!/usr/bin/env bash
# 95-ghostty: Ghostty terminal emulator.
#
# Ghostty is a GUI terminal app. It belongs on the CLIENT machine you ssh
# FROM, not on a headless server. This module installs it on machines
# that actually have a display, and logs a friendly skip on headless boxes.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Ghostty terminal emulator"

if is_skipped ghostty; then
  skip "--skip=ghostty passed"
  return 0 2>/dev/null || exit 0
fi

# Skip on headless hosts — Ghostty needs a display
if [[ "$IS_HEADLESS" -eq 1 && "$OS" != "macos" ]]; then
  skip "headless host detected — Ghostty is a GUI app; install it on your client machine (Mac/desktop), not on the VPS"
  return 0 2>/dev/null || exit 0
fi

# macOS — Homebrew cask
if [[ "$OS" == "macos" ]]; then
  if [[ -d /Applications/Ghostty.app ]]; then
    skip "Ghostty already installed (/Applications/Ghostty.app)"
  elif have brew; then
    info "installing Ghostty via Homebrew cask"
    brew install --cask ghostty
    ok "Ghostty installed — launch via Spotlight"
  else
    warn "Homebrew missing — install via https://ghostty.org/download"
  fi
  return 0 2>/dev/null || exit 0
fi

# Desktop Linux (rare for a Hermes host, but supported)
case "$OS" in
  ubuntu|debian)
    # Ghostty has no official apt repo yet (as of late 2025).
    # Snap is the easiest route; flatpak as fallback.
    if have ghostty; then
      skip "Ghostty already installed"
    elif have snap; then
      info "installing Ghostty via snap (community build)"
      sudo snap install ghostty --classic || warn "snap install failed — try flatpak or build from source"
    elif have flatpak; then
      info "installing Ghostty via flatpak"
      flatpak install -y flathub com.mitchellh.ghostty || warn "flatpak install failed"
    else
      warn "no snap or flatpak available — see https://ghostty.org/download for source-build instructions"
    fi
    ;;
  fedora|rhel|centos)
    if have dnf && ! have ghostty; then
      sudo dnf copr enable -y pgdev/ghostty 2>/dev/null || true
      sudo dnf install -y ghostty || warn "Ghostty COPR install failed"
    fi
    ;;
  *)
    warn "Ghostty: don't know how to install on OS=$OS; see https://ghostty.org/download"
    ;;
esac

ok "Ghostty step complete"
