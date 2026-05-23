#!/usr/bin/env bash
# 40-cli: modern unix CLI replacements — rg, fd, fzf, bat, jq, htop, btop, etc.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Modern CLI tools"

if [[ "$OS" == "macos" ]]; then
  have brew || { warn "Homebrew missing"; return 0 2>/dev/null || exit 0; }
  tier_allows E && brew install ripgrep fd jq htop
  tier_allows R && brew install fzf bat eza zoxide yq btop ncdu git-delta shellcheck
  tier_allows N && brew install tldr tree httpie git-lfs iftop glances graphviz
  return 0 2>/dev/null || exit 0
fi

require_sudo
apt_refresh

# Tier E
if tier_allows E; then
  apt_install ripgrep fd-find jq htop

  # fd-find ships as `fdfind` on Debian/Ubuntu — symlink to `fd`
  if have fdfind && ! have fd; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
    ok "symlinked fdfind → ~/.local/bin/fd"
  fi
fi

# Tier R
if tier_allows R; then
  apt_install fzf bat ncdu yq btop shellcheck

  # bat ships as `batcat` on Debian/Ubuntu
  if have batcat && ! have bat; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
    ok "symlinked batcat → ~/.local/bin/bat"
  fi

  # eza: available on Ubuntu 24.04+ apt, fallback to direct download
  if ! have eza; then
    if apt-cache show eza >/dev/null 2>&1; then
      apt_install eza
    else
      info "eza not in apt — installing via cargo (skipped if no cargo)"
      have cargo && cargo install eza || skip "eza skipped (no apt entry, no cargo)"
    fi
  fi

  # zoxide: official install script fails on `x86_64-unknown-linux-musl`
  # on Ubuntu 24.04 (https://github.com/ajeetdsouza/zoxide/issues/...). Use
  # apt where available; install-script only as fallback for older releases.
  if ! have zoxide && ! is_skipped zoxide; then
    if apt-cache show zoxide >/dev/null 2>&1; then
      apt_install zoxide
    else
      info "installing zoxide via official install script"
      curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | bash || \
        warn "zoxide install failed — install manually from https://github.com/ajeetdsouza/zoxide"
    fi
  fi

  # git-delta: try apt, fallback to cargo
  if ! have delta && ! is_skipped delta; then
    if apt-cache show git-delta >/dev/null 2>&1; then
      apt_install git-delta
    elif have cargo; then
      info "installing git-delta via cargo"
      cargo install git-delta || warn "git-delta cargo install failed"
    else
      skip "git-delta skipped (no apt entry, no cargo)"
    fi
  fi
fi

# Tier N — small/easy
if tier_allows N; then
  apt_install tldr tree httpie git-lfs iotop iftop glances graphviz
fi

ok "CLI tools installed"
