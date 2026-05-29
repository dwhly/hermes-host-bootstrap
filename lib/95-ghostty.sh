#!/usr/bin/env bash
# 95-ghostty: Ghostty terminal emulator. Client/both role only.
#
# Ghostty is a GUI terminal app. It belongs on the CLIENT machine you ssh
# FROM, not on a headless server. This module gates on $ROLE so it only
# runs on machines that actually have (or will have) a display.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Ghostty terminal emulator"

if is_skipped ghostty; then
  skip "--skip=ghostty passed"
  return 0 2>/dev/null || exit 0
fi

if ! role_includes client; then
  skip "role=$ROLE — Ghostty is a GUI app; install it on your client machine (set --role=client or --role=both)"
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

  # The Ghostty cask doesn't symlink the CLI onto PATH. The CLI is
  # /Applications/Ghostty.app/Contents/MacOS/ghostty and it ships useful
  # subcommands like `ghostty +ssh` (auto-installs xterm-ghostty terminfo
  # on remote hosts), `ghostty +list-fonts`, `ghostty +ssh-cache`, etc.
  # Symlink it into a user-writable PATH dir so `ghostty +ssh` works from
  # any shell. We prefer ~/.local/bin (no sudo, already on PATH via
  # ~/.local/bin/env) but fall back to /usr/local/bin if writable.
  ghostty_cli="/Applications/Ghostty.app/Contents/MacOS/ghostty"
  if [[ -x "$ghostty_cli" ]] && ! is_skipped ghostty-cli-link; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$ghostty_cli" "$HOME/.local/bin/ghostty"
    ok "Ghostty CLI symlinked to ~/.local/bin/ghostty"
  fi
fi

# Desktop Linux
if [[ "$OS" != "macos" ]]; then
case "$OS" in
  ubuntu|debian)
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
fi

# Drop a sensible default config (idempotent — only writes if missing)
ghostty_cfg_dir="$HOME/.config/ghostty"
ghostty_cfg="$ghostty_cfg_dir/config"
if [[ -f "$REPO_ROOT/dotfiles/ghostty-config" && ! -f "$ghostty_cfg" ]]; then
  mkdir -p "$ghostty_cfg_dir"
  cp "$REPO_ROOT/dotfiles/ghostty-config" "$ghostty_cfg"
  ok "installed ~/.config/ghostty/config"
elif [[ -f "$ghostty_cfg" ]]; then
  skip "$ghostty_cfg already exists — not overwritten"
fi

ok "Ghostty step complete"
