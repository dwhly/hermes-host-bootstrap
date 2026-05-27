#!/usr/bin/env bash
# 90-agents: Hermes Agent itself + gh CLI + Claude Code CLI + Codex CLI + faster-whisper.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Agent layer"

# ── GitHub CLI ──────────────────────────────────────────────────────
if tier_allows E && ! is_skipped gh; then
  if have gh; then
    skip "gh already installed: $(gh --version | head -1)"
  elif [[ "$OS" == "macos" ]]; then
    have brew && brew install gh
  else
    info "installing GitHub CLI (via official keyring)"
    require_sudo
    sudo mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    export APT_REFRESHED=0  # force re-refresh after adding new source
    apt_refresh
    apt_install gh
  fi
fi

# ── Hermes Agent ────────────────────────────────────────────────────
if tier_allows E && ! is_skipped hermes; then
  if have hermes; then
    skip "hermes already installed: $(hermes --version 2>/dev/null || echo unknown)"
  else
    info "installing Hermes Agent"
    curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
    # hermes installs to ~/.local/bin typically
    export PATH="$HOME/.local/bin:$PATH"
    if have hermes; then
      ok "hermes installed: $(hermes --version 2>/dev/null || echo unknown)"
    else
      warn "hermes binary not found on PATH after install — check ~/.local/bin and your shell rc"
    fi
  fi
fi

# ── Claude Code CLI ─────────────────────────────────────────────────
if tier_allows R && ! is_skipped claude-code; then
  if have claude; then
    skip "Claude Code already installed"
  elif have npm; then
    info "installing Claude Code CLI via npm"
    npm install -g @anthropic-ai/claude-code
  else
    warn "skipping Claude Code — npm not present (run the 50-languages step first)"
  fi
fi

# ── Codex CLI ───────────────────────────────────────────────────────
if tier_allows R && ! is_skipped codex; then
  if have codex; then
    skip "Codex CLI already installed"
  elif have npm; then
    info "installing OpenAI Codex CLI via npm"
    npm install -g @openai/codex
  else
    warn "skipping Codex — npm not present"
  fi
fi

# ── faster-whisper (local STT for Hermes voice) ─────────────────────
if tier_allows R && ! is_skipped faster-whisper; then
  if have pipx; then
    if ! pipx list 2>/dev/null | grep -q faster-whisper; then
      # faster-whisper is a library, not a CLI app, so we install it
      # into a venv that hermes can find. Use uv if available, else pip --user.
      if have uv; then
        info "installing faster-whisper via uv tool (library, not CLI)"
        # easier: just pip install --user, since Hermes' venv autodetects it
        python3 -m pip install --user --break-system-packages faster-whisper 2>/dev/null \
          || python3 -m pip install --user faster-whisper
      else
        python3 -m pip install --user --break-system-packages faster-whisper 2>/dev/null \
          || python3 -m pip install --user faster-whisper
      fi
      ok "faster-whisper installed (Hermes local STT)"
    else
      skip "faster-whisper already installed"
    fi
  fi
fi

# ── Browser automation deps (chromium + playwright) ─────────────────
# Only on Linux; macOS users typically use the bundled chromium from Playwright.
if tier_allows R && ! is_skipped browser-deps && [[ "$OS" != "macos" ]]; then
  if have npx; then
    info "installing playwright system deps + chromium"
    npx --yes playwright install-deps chromium 2>/dev/null || \
      warn "playwright install-deps failed (may need npm root setup); skipping"
    npx --yes playwright install chromium 2>/dev/null || true
  fi
fi

ok "Agent layer complete"
