#!/usr/bin/env bash
# 60-containers: Docker engine + compose.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Containers (Docker)"

if ! tier_allows R; then
  skip "tier=$TIER — docker is recommended-tier, skipping"
  return 0 2>/dev/null || exit 0
fi
if is_skipped docker; then
  skip "--skip=docker passed"
  return 0 2>/dev/null || exit 0
fi

if [[ "$OS" == "macos" ]]; then
  if [[ -d /Applications/Docker.app ]]; then
    skip "Docker Desktop already installed"
  else
    have brew && brew install --cask docker || warn "could not install Docker Desktop"
    info "launch Docker Desktop manually once to finish setup"
  fi
  return 0 2>/dev/null || exit 0
fi

# Linux
require_sudo
if have docker; then
  skip "docker already installed: $(docker --version)"
else
  info "installing Docker via get.docker.com (official convenience script)"
  curl -fsSL https://get.docker.com | sudo sh
fi

# Add invoking user to docker group
target_user="${SUDO_USER:-$USER}"
if ! id -nG "$target_user" | grep -qw docker; then
  sudo usermod -aG docker "$target_user"
  warn "added $target_user to 'docker' group — log out and back in for it to take effect"
fi

# Enable & start
sudo systemctl enable --now docker >/dev/null 2>&1 || true

ok "Docker ready"
