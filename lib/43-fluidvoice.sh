#!/usr/bin/env bash
# 43-fluidvoice: FluidVoice — local-first system-wide dictation for macOS.
# https://github.com/altic-dev/FluidVoice  ·  https://altic.dev/fluid
#
# Package-add contract:
#   1) this install module,
#   2) tiers/recommended.txt entry,
#   3) version tracking in lib/99-register-host.sh,
#   4) verify.sh visibility check.
#
# FluidVoice is a GUI client app, not a server package. Install only on macOS
# client/both hosts. First launch still requires the user to grant Microphone
# and Accessibility access and choose/download a speech model; those TCC grants
# cannot and should not be automated remotely.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "FluidVoice (local-first macOS dictation)"

if ! tier_allows R; then
  skip "FluidVoice skipped (tier below R)"
  return 0 2>/dev/null || exit 0
fi
if is_skipped fluidvoice; then
  skip "FluidVoice skipped (HERMES_SKIP includes fluidvoice)"
  return 0 2>/dev/null || exit 0
fi
if [[ "$OS" != "macos" ]] || ! role_includes client; then
  skip "FluidVoice is macOS client-only"
  return 0 2>/dev/null || exit 0
fi
if ! have brew; then
  warn "FluidVoice requires Homebrew on macOS — install Homebrew, then rerun --only=43-fluidvoice"
  return 0 2>/dev/null || exit 0
fi

if [[ -d /Applications/FluidVoice.app ]]; then
  version="$(defaults read /Applications/FluidVoice.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo present)"
  skip "FluidVoice already installed: $version"
else
  info "installing FluidVoice via the official Homebrew cask"
  if brew install --cask fluidvoice; then
    ok "FluidVoice installed"
  else
    warn "FluidVoice cask install failed — see https://github.com/altic-dev/FluidVoice/releases/latest"
    return 0 2>/dev/null || exit 0
  fi
fi

if [[ -d /Applications/FluidVoice.app ]]; then
  version="$(defaults read /Applications/FluidVoice.app/Contents/Info CFBundleShortVersionString 2>/dev/null || echo unknown)"
  ok "FluidVoice app present: $version"
else
  warn "FluidVoice cask completed but /Applications/FluidVoice.app is absent"
  return 0 2>/dev/null || exit 0
fi

# Start FluidVoice at graphical login on every fleet Mac. FluidVoice's native
# setting uses SMAppService, which is only invokable inside the signed app UI.
# For unattended bootstrap, use the app's own supported legacy compatibility
# Login Item path (the source explicitly knows how to remove this item when the
# user disables launch-at-startup later). This produces a genuine login-item
# launch event, allowing FluidVoice to boot silently in the menu bar.
bundle_id="$(defaults read /Applications/FluidVoice.app/Contents/Info CFBundleIdentifier 2>/dev/null || echo com.FluidApp.app)"
defaults write "$bundle_id" ShowMainWindowAtLoginLaunch -bool false
defaults write "$bundle_id" LaunchAtStartupCompatibilityFallback -bool true

if osascript -e 'tell application "System Events" to if not (exists login item "FluidVoice") then make login item at end with properties {name:"FluidVoice", path:"/Applications/FluidVoice.app", hidden:true}' >/dev/null 2>&1; then
  login_path="$(osascript -e 'tell application "System Events" to if exists login item "FluidVoice" then get path of login item "FluidVoice"' 2>/dev/null || true)"
  if [[ "$login_path" == "/Applications/FluidVoice.app" ]]; then
    ok "FluidVoice login item enabled (starts silently at graphical login)"
  else
    warn "FluidVoice login item exists but path verification returned: ${login_path:-unknown}"
  fi
else
  warn "could not register FluidVoice with macOS Login Items from this session"
  warn "approve System Events automation or enable FluidVoice in System Settings > General > Login Items"
fi

info "manual first launch: grant Microphone + Accessibility and choose a speech model"
