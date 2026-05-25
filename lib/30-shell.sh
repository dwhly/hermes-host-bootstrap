#!/usr/bin/env bash
# 30-shell: tmux, zsh, oh-my-zsh, neovim, mosh, micro.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Shell & multiplexer"

# Per-OS package install
if [[ "$OS" == "macos" ]]; then
  have brew || { warn "Homebrew missing — run buildchain step first"; return 0 2>/dev/null || exit 0; }
  tier_allows E && { is_skipped tmux   || brew install tmux; }
  tier_allows E && { is_skipped neovim || brew install neovim; }
  tier_allows R && { is_skipped mosh   || brew install mosh; }
  tier_allows R && { is_skipped zsh    || true; }  # macOS already has zsh
  tier_allows N && { is_skipped micro  || brew install micro; }
else
  require_sudo
  apt_refresh
  tier_allows E && { is_skipped tmux   || apt_install tmux; }
  tier_allows E && { is_skipped neovim || apt_install neovim; }
  tier_allows R && { is_skipped mosh   || apt_install mosh; }
  tier_allows R && { is_skipped zsh    || apt_install zsh; }
  tier_allows N && { is_skipped micro  || apt_install micro; }
fi

# tmux config — drop a sensible default if user has none
if have tmux && tier_allows E && ! is_skipped tmux-conf; then
  if [[ ! -f "$HOME/.tmux.conf" ]]; then
    cp "$REPO_ROOT/dotfiles/tmux.conf" "$HOME/.tmux.conf"
    ok "installed ~/.tmux.conf"
  else
    skip "$HOME/.tmux.conf already exists — not overwritten"
  fi
fi

# oh-my-zsh — only if zsh present, OMZ missing, and user opts in (default: yes for R)
if have zsh && tier_allows R && ! is_skipped oh-my-zsh; then
  if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    info "installing oh-my-zsh (unattended)"
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c \
      "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
      "" --unattended
  else
    skip "oh-my-zsh already installed"
  fi

  # Append our recommended zshrc snippet (idempotent)
  ensure_line "# ── hermes-host-bootstrap zshrc additions ──" "$HOME/.zshrc"
  ensure_line "[ -f $HOME/.hermes-host-bootstrap.zshrc ] && source $HOME/.hermes-host-bootstrap.zshrc" \
              "$HOME/.zshrc"
  cp "$REPO_ROOT/dotfiles/zshrc-snippet.sh" "$HOME/.hermes-host-bootstrap.zshrc"
  ok "zshrc snippet installed (history + path tweaks)"
fi

# .inputrc — case-insensitive completion, history search on arrows
if tier_allows R && ! is_skipped inputrc; then
  if [[ ! -f "$HOME/.inputrc" ]]; then
    cp "$REPO_ROOT/dotfiles/inputrc" "$HOME/.inputrc"
    ok "installed ~/.inputrc"
  else
    skip "$HOME/.inputrc already exists — not overwritten"
  fi
fi

# tmux auto-attach on interactive SSH — drop snippet, source from rc files.
# Works for both bash and zsh; SSH-only and interactive-only guarded inside.
if have tmux && tier_allows R && ! is_skipped tmux-autoattach; then
  cp "$REPO_ROOT/dotfiles/tmux-autoattach.sh" "$HOME/.hermes-host-bootstrap.tmux-autoattach.sh"
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] || continue
    ensure_line "# ── hermes-host-bootstrap tmux auto-attach ──" "$rc"
    ensure_line "[ -f $HOME/.hermes-host-bootstrap.tmux-autoattach.sh ] && . $HOME/.hermes-host-bootstrap.tmux-autoattach.sh" "$rc"
  done
  ok "tmux auto-attach snippet installed (sourced from bashrc/zshrc)"
fi

# hssh — ssh + attach/create named tmux session in one shot.
# Lives on every host so it works whether you're the client or hopping between boxes.
if have tmux && tier_allows R && ! is_skipped hssh; then
  cp "$REPO_ROOT/dotfiles/hssh.sh" "$HOME/.hermes-host-bootstrap.hssh.sh"
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] || continue
    ensure_line "# ── hermes-host-bootstrap hssh helper ──" "$rc"
    ensure_line "[ -f $HOME/.hermes-host-bootstrap.hssh.sh ] && . $HOME/.hermes-host-bootstrap.hssh.sh" "$rc"
  done
  ok "hssh helper installed (sourced from bashrc/zshrc)"
fi

ok "Shell setup complete"
