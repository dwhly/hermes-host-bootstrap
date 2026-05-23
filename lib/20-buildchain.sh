#!/usr/bin/env bash
# 20-buildchain: build-essential + libs Python wheels / cargo / make need.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Build chain & core libs"

if [[ "$OS" == "macos" ]]; then
  if have xcode-select && ! xcode-select -p >/dev/null 2>&1; then
    info "installing Xcode Command Line Tools (GUI prompt may appear)"
    xcode-select --install || true
  else
    skip "Xcode Command Line Tools already present"
  fi
  if ! have brew; then
    info "installing Homebrew"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  else
    skip "Homebrew already installed"
  fi
  return 0 2>/dev/null || exit 0
fi

require_sudo
apt_refresh

# Tier E
if tier_allows E; then
  apt_install \
    build-essential pkg-config \
    libssl-dev libffi-dev \
    zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev liblzma-dev \
    ca-certificates curl wget git rsync \
    less man-db cron logrotate \
    unzip zip
  # ^ unzip needed by the fnm install script (50-languages.sh).
  # zip is a freebie and gets asked for often enough.
fi

# Tier R
if tier_allows R; then
  apt_install cmake
fi

ok "Build chain ready"
