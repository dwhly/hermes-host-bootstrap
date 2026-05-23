#!/usr/bin/env bash
# 70-network: tailscale + cloudflared (named tunnels for hermes webhooks).

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Network / remote access"

if ! tier_allows R; then
  skip "tier=$TIER — tailscale/cloudflared are recommended-tier, skipping"
  return 0 2>/dev/null || exit 0
fi

# ── Tailscale ───────────────────────────────────────────────────────
if ! is_skipped tailscale; then
  if [[ "$OS" == "macos" ]]; then
    if [[ ! -d /Applications/Tailscale.app ]]; then
      have brew && brew install --cask tailscale || warn "tailscale install failed"
    else
      skip "Tailscale already installed"
    fi
  else
    if have tailscale; then
      skip "tailscale already installed: $(tailscale version | head -1)"
    else
      info "installing Tailscale"
      curl -fsSL https://tailscale.com/install.sh | sudo sh
    fi
    info "run \`sudo tailscale up\` to connect this node to your tailnet"
  fi
fi

# ── cloudflared ─────────────────────────────────────────────────────
if ! is_skipped cloudflared; then
  if [[ "$OS" == "macos" ]]; then
    have brew && brew install cloudflared || skip "cloudflared install failed"
  else
    if have cloudflared; then
      skip "cloudflared already installed"
    else
      info "installing cloudflared (.deb from github releases)"
      arch_pkg="amd64"
      [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && arch_pkg="arm64"
      tmp_deb="$(mktemp --suffix=.deb)"
      curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch_pkg}.deb" -o "$tmp_deb"
      sudo dpkg -i "$tmp_deb" || true
      rm -f "$tmp_deb"
    fi
  fi
fi

ok "Network tools ready"
