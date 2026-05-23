#!/usr/bin/env bash
# 80-media: ffmpeg, imagemagick, poppler-utils, tesseract, pandoc — used by many Hermes skills.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Media & document tooling"

if ! tier_allows R; then
  skip "tier=$TIER — media tools are recommended-tier, skipping"
  return 0 2>/dev/null || exit 0
fi
if is_skipped media; then
  skip "--skip=media passed"
  return 0 2>/dev/null || exit 0
fi

if [[ "$OS" == "macos" ]]; then
  have brew || { warn "Homebrew missing"; return 0 2>/dev/null || exit 0; }
  brew install ffmpeg imagemagick poppler tesseract pandoc
  tier_allows N && brew install espeak-ng
  return 0 2>/dev/null || exit 0
fi

require_sudo
apt_refresh
apt_install ffmpeg imagemagick poppler-utils tesseract-ocr pandoc

# Tier N — espeak-ng (needed by NeuTTS local TTS — small dep, easy)
if tier_allows N; then
  apt_install espeak-ng
fi

ok "Media tools installed"
