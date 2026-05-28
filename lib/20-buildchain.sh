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

    # Homebrew's installer switches to NONINTERACTIVE mode when stdin is not a
    # TTY (common for `curl ... | bash` and SSH-driven bootstrap). On macOS
    # that makes sudo fail with the misleading "Need sudo access" message even
    # for admin users, because sudo cannot prompt for a password. If /dev/tty is
    # available, explicitly hand the installer a TTY so it can ask. If no TTY is
    # available, fail with a short actionable message instead of letting the
    # installer spew confusing output and causing later modules to half-run.
    if [[ -r /dev/tty ]]; then
      INTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty
    else
      warn "Homebrew is required for the macOS client/host toolchain, but this session has no TTY for sudo."
      warn "Run this once in Terminal.app on the Mac so sudo can prompt:"
      warn "  cd /tmp && curl -fsSL https://raw.githubusercontent.com/dwhly/hermes-host-bootstrap/main/bootstrap.sh | bash -s -- --tier=$TIER --role=$ROLE"
      return 1 2>/dev/null || exit 1
    fi
  else
    skip "Homebrew already installed"
  fi

  # Make Homebrew available to the current module chain even before the user's
  # next login shell. Apple Silicon uses /opt/homebrew; Intel uses /usr/local.
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  ok "Build chain ready"
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
