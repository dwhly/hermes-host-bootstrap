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

app_path="${FLUIDVOICE_APP_PATH:-/Applications/FluidVoice.app}"

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

if [[ -d "$app_path" ]]; then
  version="$(defaults read "$app_path/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo present)"
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

if [[ -d "$app_path" ]]; then
  version="$(defaults read "$app_path/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown)"
  ok "FluidVoice app present: $version"
else
  warn "FluidVoice cask completed but $app_path is absent"
  return 0 2>/dev/null || exit 0
fi

# Start FluidVoice at graphical login on every fleet Mac. FluidVoice's native
# setting uses SMAppService, which is only invokable inside the signed app UI.
# For unattended bootstrap, use the app's own supported legacy compatibility
# Login Item path (the source explicitly knows how to remove this item when the
# user disables launch-at-startup later). This produces a genuine login-item
# launch event; the app preference below suppresses its window at login.
bundle_id="$(defaults read "$app_path/Contents/Info" CFBundleIdentifier 2>/dev/null || echo com.FluidApp.app)"
defaults write "$bundle_id" ShowMainWindowAtLoginLaunch -bool false
defaults write "$bundle_id" LaunchAtStartupCompatibilityFallback -bool true

app_path_as="${app_path//\\/\\\\}"
app_path_as="${app_path_as//\"/\\\"}"
login_path="$(osascript -e 'tell application "System Events" to if exists login item "FluidVoice" then get path of login item "FluidVoice"' 2>/dev/null || true)"
if [[ -n "$login_path" && "$login_path" != "$app_path" ]]; then
  info "repairing stale FluidVoice login item path: $login_path"
  osascript -e 'tell application "System Events" to delete login item "FluidVoice"' >/dev/null 2>&1 \
    || { warn "could not remove stale FluidVoice login item"; exit 1; }
fi

if osascript -e "tell application \"System Events\" to if not (exists login item \"FluidVoice\") then make login item at end with properties {name:\"FluidVoice\", path:\"$app_path_as\"}" >/dev/null 2>&1; then
  login_path="$(osascript -e 'tell application "System Events" to if exists login item "FluidVoice" then get path of login item "FluidVoice"' 2>/dev/null || true)"
  if [[ "$login_path" == "$app_path" ]]; then
    ok "FluidVoice login item enabled (window suppressed at graphical login)"
  else
    warn "FluidVoice login item path verification failed: ${login_path:-unknown}"
    exit 1
  fi
else
  warn "could not register FluidVoice with macOS Login Items"
  warn "approve System Events automation or enable FluidVoice in System Settings > General > Login Items, then rerun"
  exit 1
fi

info "manual first launch: grant Microphone + Accessibility and choose a speech model"
