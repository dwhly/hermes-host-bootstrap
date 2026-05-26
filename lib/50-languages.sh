#!/usr/bin/env bash
# 50-languages: Python (uv, pipx), Node (fnm + LTS), Rust (rustup).

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Languages & package managers"

# ── Python ──────────────────────────────────────────────────────────
if tier_allows E && ! is_skipped python; then
  if [[ "$OS" == "macos" ]]; then
    have brew && brew install python pipx
  else
    require_sudo; apt_refresh
    apt_install python3 python3-venv python3-dev python3-pip pipx
  fi
  have pipx && pipx ensurepath >/dev/null 2>&1 || true
  ok "python + pipx ready"
fi

# uv — Astral's Python package manager (Hermes' installer uses it)
if tier_allows E && ! is_skipped uv && ! have uv; then
  info "installing uv (Astral)"
  curl -LsSf https://astral.sh/uv/install.sh | sh || \
    warn "uv install failed — see https://astral.sh/uv"
  # uv installs to ~/.local/bin
  export PATH="$HOME/.local/bin:$PATH"
  have uv && ok "uv installed: $(uv --version)" || warn "uv install may have failed"
fi

# ── Node.js via fnm ─────────────────────────────────────────────────
if tier_allows E && ! is_skipped node; then
  if ! have fnm; then
    info "installing fnm (Fast Node Manager)"
    # fnm install script needs unzip — we install that in 20-buildchain,
    # but double-check here in case someone ran with --only=50-languages
    if ! have unzip; then
      warn "unzip is missing — fnm install will fail. Install with: sudo apt install unzip"
    fi
    curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell || \
      warn "fnm install failed — see https://github.com/Schniz/fnm#installation"
  else
    skip "fnm already installed"
  fi

  # set up fnm env in this shell so we can install Node now
  FNM_DIR="${FNM_DIR:-$HOME/.local/share/fnm}"
  if [[ -x "$FNM_DIR/fnm" ]]; then
    export PATH="$FNM_DIR:$PATH"
    # `fnm env` needs FNM_MULTISHELL_PATH to point at a writable per-shell
    # symlink dir; in a fresh bootstrap subshell that var isn't set yet and
    # `fnm install --lts` fails with:
    #   "We can't find the necessary environment variables to replace the
    #    Node version."
    # Setting it explicitly + exporting it before sourcing `fnm env` is the
    # canonical fix. We use the per-PID path that fnm itself would generate.
    export FNM_DIR
    export FNM_MULTISHELL_PATH="${FNM_MULTISHELL_PATH:-$FNM_DIR/_multishells/$$}"
    mkdir -p "$(dirname "$FNM_MULTISHELL_PATH")"
    # Source fnm env — surface failures (don't swallow with || true) so a
    # broken eval doesn't silently leave the install step without env vars.
    if ! eval "$("$FNM_DIR/fnm" env --shell bash)"; then
      warn "fnm env setup failed; Node install may fail"
    fi
    # Symlink fnm into ~/.local/bin so it's on PATH for every shell without
    # needing the FNM_DIR PATH amendment. ~/.local/bin is already on PATH via
    # ~/.local/bin/env (Cargo/uv share this convention). Without this, the
    # guarded eval below skips silently in shells that source .bashrc but not
    # the zshrc-snippet that adds FNM_DIR to PATH, and you get no Node tools.
    mkdir -p "$HOME/.local/bin"
    ln -sf "$FNM_DIR/fnm" "$HOME/.local/bin/fnm"
  fi

  if have fnm; then
    if ! fnm list 2>/dev/null | grep -q 'lts'; then
      info "installing Node.js LTS via fnm"
      # `fnm install` only fetches; `fnm use` is what needs FNM_MULTISHELL_PATH.
      # Split them so an install-only success is still progress.
      if ! fnm install --lts; then
        warn "fnm install --lts failed"
      fi
      fnm default lts-latest 2>/dev/null || true
      if ! fnm use lts-latest 2>/dev/null; then
        warn "fnm use lts-latest failed in this shell (env vars missing). \
Open a new shell and run 'fnm use lts-latest' to verify Node is on PATH."
      fi
    else
      skip "Node LTS already installed via fnm"
    fi
    # Add fnm init to shell rc files (idempotent, self-heals if fnm later vanishes).
    # The guard around the eval means a shell still starts cleanly even if fnm
    # is uninstalled, never installed (e.g. --only=30-shell run alone), or its
    # binary moved. Without the guard you get 'command not found: fnm' on every
    # new shell, which is harmless but noisy.
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
      [[ -f "$rc" ]] || continue
      ensure_line 'command -v fnm >/dev/null 2>&1 && eval "$(fnm env --use-on-cd)"' "$rc"
    done
  fi
fi

# pnpm — install via the now-available npm
if tier_allows R && ! is_skipped pnpm && ! have pnpm; then
  # fnm env was set up earlier in this module; npm should be on PATH now.
  # If not, give the user a clear message instead of silently skipping.
  if have npm; then
    info "installing pnpm via npm"
    npm install -g pnpm || warn "pnpm install failed"
  else
    warn "pnpm skipped: npm not on PATH (open a new shell and run 'npm install -g pnpm' manually)"
  fi
fi

# ── Rust (rustup) ───────────────────────────────────────────────────
if tier_allows R && ! is_skipped rust && ! have cargo; then
  info "installing Rust via rustup"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path || \
    warn "rustup install failed — see https://rustup.rs"
  # shellcheck disable=SC1091
  [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
fi

ok "Languages ready"
