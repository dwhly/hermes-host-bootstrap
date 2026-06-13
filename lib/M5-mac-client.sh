#!/usr/bin/env bash
# M5-mac-client: macOS client-side setup — Microsoft Remote Desktop, Tailscale GUI,
# a couple of optional CLI niceties. Only runs on macOS with role=client/both.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "macOS client-side apps"

if [[ "$OS" != "macos" ]]; then
  skip "not macOS — skipping mac-client module"
  return 0 2>/dev/null || exit 0
fi

if ! role_includes client; then
  skip "role=$ROLE — mac-client module only runs on client/both"
  return 0 2>/dev/null || exit 0
fi

if ! have brew; then
  warn "Homebrew missing — run 20-buildchain first or install from https://brew.sh"
  return 0 2>/dev/null || exit 0
fi

# tmux on the Mac as well — handy for local sessions, and also so `mosh host -- tmux`
# style invocations work from any shell. The server-side install is in 30-shell.sh;
# this one is the client-side counterpart so the same recipe works in both directions.
if tier_allows E && ! is_skipped tmux; then
  if have tmux; then
    skip "tmux already installed"
  else
    info "installing tmux"
    brew install tmux || warn "tmux install failed"
  fi
fi

# mosh on the Mac — the client side of the SSH-replacement combo. Pair with tmux on
# the server (mosh handles transport resilience over UDP across Mac sleep / Wi-Fi
# changes; tmux protects the running process state on the server). Use as:
#     mosh <host> -- tmux new -A -s main
if tier_allows R && ! is_skipped mosh; then
  if have mosh; then
    skip "mosh already installed"
  else
    info "installing mosh"
    brew install mosh || warn "mosh install failed"
  fi
fi

# Microsoft Remote Desktop — for connecting to the xrdp server we set up on Linux
if ! is_skipped ms-remote-desktop; then
  if [[ -d "/Applications/Microsoft Remote Desktop.app" ]] || \
     [[ -d "/Applications/Windows App.app" ]]; then
    # Microsoft renamed it to "Windows App" in 2024 — both names cover that
    skip "Microsoft Remote Desktop / Windows App already installed"
  else
    info "installing Microsoft Remote Desktop"
    brew install --cask windows-app || \
      brew install --cask microsoft-remote-desktop || \
      warn "could not install Remote Desktop cask — get it from the Mac App Store"
  fi
fi

# Tailscale GUI app (separate from the CLI in 70-network.sh — the cask gives you
# the menu-bar widget). Brew handles the dedupe.
if ! is_skipped tailscale-gui; then
  if [[ ! -d /Applications/Tailscale.app ]]; then
    info "installing Tailscale GUI"
    brew install --cask tailscale-app 2>/dev/null || brew install --cask tailscale || true
  else
    skip "Tailscale app already installed"
  fi
fi

# Rectangle — keyboard-driven window snapping. Tiny, universally loved.
if tier_allows N && ! is_skipped rectangle; then
  if [[ ! -d /Applications/Rectangle.app ]]; then
    info "installing Rectangle (window snapping)"
    brew install --cask rectangle || true
  fi
fi

# Raycast — Spotlight replacement. Lots of Hermes users love it.
if tier_allows N && ! is_skipped raycast; then
  if [[ ! -d /Applications/Raycast.app ]]; then
    info "installing Raycast (Spotlight replacement)"
    brew install --cask raycast || true
  fi
fi

# macOS hostname rename — opt-in via HERMES_MAC_HOSTNAME. Sets the three
# Mac hostname facets:
#   HostName       → CLI hostname (`hostname`, $HOSTNAME, shell prompt)
#   LocalHostName  → Bonjour/mDNS name (used for `<name>.local`)
#   ComputerName   → friendly name (AirDrop, Finder, Sharing pane)
#
# By design, ComputerName stays human-readable ("Dan's Mac Mini") so
# AirDrop / Finder pickers don't show "h-mini" — only HostName + LocalHostName
# become the CLI-friendly $HERMES_MAC_HOSTNAME. If you want to override the
# ComputerName too, set HERMES_MAC_COMPUTER_NAME explicitly.
#
# Skip key: mac-hostname. Lockout-safe: only fires when the env var is set.
if [[ -n "${HERMES_MAC_HOSTNAME:-}" ]] && ! is_skipped mac-hostname; then
  new_host="$HERMES_MAC_HOSTNAME"
  current_host="$(scutil --get HostName 2>/dev/null || hostname)"
  if [[ "$current_host" == "$new_host" ]]; then
    skip "Mac hostname already $new_host"
  else
    info "renaming Mac: $current_host → $new_host"
    if sudo scutil --set HostName "$new_host" && \
       sudo scutil --set LocalHostName "$new_host"; then
      if [[ -n "${HERMES_MAC_COMPUTER_NAME:-}" ]]; then
        sudo scutil --set ComputerName "$HERMES_MAC_COMPUTER_NAME" && \
          ok "ComputerName: $HERMES_MAC_COMPUTER_NAME"
      else
        info "ComputerName left unchanged (set HERMES_MAC_COMPUTER_NAME to override AirDrop / Finder name too)"
      fi
      ok "Mac hostname: $current_host → $new_host (HostName + LocalHostName)"
      ok "open a new terminal to see the new prompt"
    else
      warn "scutil rename failed — try manually:"
      warn "  sudo scutil --set HostName \"$new_host\""
      warn "  sudo scutil --set LocalHostName \"$new_host\""
    fi
  fi
fi

# Ghostty 4-pane workspace launcher (AppleScript).
# Drops the .applescript file and a wrapper command, both idempotent. Requires
# Ghostty 1.3.0+ for AppleScript support (current Homebrew cask is fine).
if ! is_skipped ghostty-workspace; then
  if [[ -d /Applications/Ghostty.app ]]; then
    workspace_dir="$HOME/.hermes-host-bootstrap"
    mkdir -p "$workspace_dir"
    cp "$REPO_ROOT/scripts/ghostty-workspace.applescript" \
       "$workspace_dir/ghostty-workspace.applescript"

    # Wrapper command on PATH — `hermes-workspace` opens the 2x2 grid.
    bin_dir="$HOME/.local/bin"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/hermes-workspace" <<'WRAPPER'
#!/bin/sh
# hermes-workspace — open a 4-pane Ghostty grid SSH'd into named tmux sessions.
#
# Usage:
#   hermes-workspace                # default: h-do1 resolved via ~/.hermes/hosts
#   hermes-workspace h-mini         # resolves via ~/.hermes/hosts/h-mini.yaml
#   hermes-workspace root@h-do1     # explicit user@host
#   hmw …                           # same, via the alias
#
# Resolve fleet hostnames through ~/.hermes/hosts before AppleScript builds the
# pane commands. This avoids depending on local MagicDNS/SSH config state.
target="${1:-h-do1}"
if command -v hermes-host-resolve >/dev/null 2>&1; then
  target="$(hermes-host-resolve "$target")"
fi
exec osascript "$HOME/.hermes-host-bootstrap/ghostty-workspace.applescript" "$target"
WRAPPER
    chmod +x "$bin_dir/hermes-workspace"
    ok "Ghostty workspace launcher installed (run: hermes-workspace)"
  else
    skip "Ghostty not installed yet — workspace launcher skipped"
  fi
fi

ok "macOS client setup complete"

echo ""
info "Next steps on this Mac:"
echo "    1. Launch Ghostty — settings already configured at ~/.config/ghostty/config"
echo "    2. Launch Tailscale, sign in, and you'll see your VPS in the menu bar"
echo "    3. To reach your VPS desktop:"
echo "         ssh -L 3389:localhost:3389 you@vps    # tunnel"
echo "         (then open Windows App / Remote Desktop, connect to localhost:3389)"
echo "    4. For a shell that survives Mac sleep + tmux session that survives mosh:"
echo "         mosh you@vps -- tmux new -A -s main"
echo "         (mosh handles transport; tmux keeps your work alive even if mosh dies)"
echo ""
