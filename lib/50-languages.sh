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
  curl -LsSf https://astral.sh/uv/install.sh | sh
  # uv installs to ~/.local/bin
  export PATH="$HOME/.local/bin:$PATH"
  have uv && ok "uv installed: $(uv --version)" || warn "uv install may have failed"
fi

# ── Node.js via fnm ─────────────────────────────────────────────────
if tier_allows E && ! is_skipped node; then
  if ! have fnm; then
    info "installing fnm (Fast Node Manager)"
    curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
  else
    skip "fnm already installed"
  fi

  # set up fnm env in this shell so we can install Node now
  FNM_DIR="${FNM_DIR:-$HOME/.local/share/fnm}"
  if [[ -x "$FNM_DIR/fnm" ]]; then
    export PATH="$FNM_DIR:$PATH"
    eval "$("$FNM_DIR/fnm" env --shell bash)" || true
  fi

  if have fnm; then
    if ! fnm list 2>/dev/null | grep -q 'lts'; then
      info "installing Node.js LTS via fnm"
      fnm install --lts
      fnm default lts-latest
      fnm use lts-latest
    else
      skip "Node LTS already installed via fnm"
    fi
    # Add fnm init to shell rc files (idempotent)
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
      [[ -f "$rc" ]] || continue
      ensure_line 'eval "$(fnm env --use-on-cd)"' "$rc"
    done
  fi
fi

# pnpm — only if npm now present
if tier_allows R && ! is_skipped pnpm && have npm && ! have pnpm; then
  info "installing pnpm via npm"
  npm install -g pnpm
fi

# ── Rust (rustup) ───────────────────────────────────────────────────
if tier_allows R && ! is_skipped rust && ! have cargo; then
  info "installing Rust via rustup"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
  # shellcheck disable=SC1091
  [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
fi

ok "Languages ready"
