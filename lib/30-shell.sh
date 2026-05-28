#!/usr/bin/env bash
# 30-shell: tmux, zsh, oh-my-zsh, neovim, mosh, micro, and shell rc wiring.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Shell & multiplexer"

# Per-OS package install. Important: on macOS, missing Homebrew must NOT skip
# the rest of this module. Dotfile/alias wiring below is pure file work and
# should still happen after a partial first bootstrap (the exact h-mini2 failure
# mode: Homebrew couldn't prompt for sudo, so hmr/hmc aliases never went live).
if [[ "$OS" == "macos" ]]; then
  if have brew; then
    tier_allows E && { is_skipped tmux   || brew install tmux; }
    tier_allows E && { is_skipped neovim || brew install neovim; }
    tier_allows R && { is_skipped mosh   || brew install mosh; }
    tier_allows R && { is_skipped zsh    || true; }  # macOS already has zsh
    tier_allows N && { is_skipped micro  || brew install micro; }
  else
    warn "Homebrew missing — package installs skipped, but shell rc/aliases will still be wired"
  fi
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

# tmux workspace colors — separate file sourced from ~/.tmux.conf, so we can
# update the per-session statusline coloring without overwriting the user's
# main tmux.conf. Drop the snippet file, then ensure_line a source-file line
# into ~/.tmux.conf so it's picked up on every tmux start (and on prefix-r
# reload). Skip key: tmux-workspace-colors.
if have tmux && tier_allows R && ! is_skipped tmux-workspace-colors; then
  cp "$REPO_ROOT/dotfiles/tmux-workspace-colors.conf" \
     "$HOME/.hermes-host-bootstrap.tmux-workspace-colors.conf"
  if [[ -f "$HOME/.tmux.conf" ]]; then
    ensure_line "# ── hermes-host-bootstrap tmux workspace colors ──" "$HOME/.tmux.conf"
    ensure_line "source-file ~/.hermes-host-bootstrap.tmux-workspace-colors.conf" "$HOME/.tmux.conf"
  fi
  ok "tmux workspace colors installed (per-session statusbar)"
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
# We `touch` each rc file first so it's created if missing — otherwise a host
# whose user only ever uses bash (or only zsh) wouldn't pick up the snippet
# in the other shell if they ever switched. Better to always provision both.
if have tmux && tier_allows R && ! is_skipped tmux-autoattach; then
  cp "$REPO_ROOT/dotfiles/tmux-autoattach.sh" "$HOME/.hermes-host-bootstrap.tmux-autoattach.sh"
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    touch "$rc"
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
    touch "$rc"
    ensure_line "# ── hermes-host-bootstrap hssh helper ──" "$rc"
    ensure_line "[ -f $HOME/.hermes-host-bootstrap.hssh.sh ] && . $HOME/.hermes-host-bootstrap.hssh.sh" "$rc"
  done
  ok "hssh helper installed (sourced from bashrc/zshrc)"
fi

# Rewrite stale hostnames in user's HSSH_DEFAULT_HOST exports.
# When a fleet host gets renamed (e.g. hermes-do1 → h-do1), any client machine
# that hand-edited HSSH_DEFAULT_HOST="root@hermes-do1" into ~/.zshrc keeps the
# stale name forever, even after `hmr` pulls new bootstrap defaults. This step
# scans rc files for HSSH_DEFAULT_HOST exports referencing the canonical-rename
# table below and rewrites them in-place (with a .bak left behind).
#
# The table is the source of truth for "we renamed X → Y in the fleet". Add a
# new entry the next time a host is renamed; rerun `hmr --only=30-shell` on
# every client and they all converge. Idempotent — does nothing if the new
# name is already in place.
#
# Skip key: hostname-rewrite.
if tier_allows R && ! is_skipped hostname-rewrite; then
  # Format: "OLD=NEW" — bash array; add more as the fleet renames happen.
  hostname_renames=(
    "hermes-do1=h-do1"
    "hermes-mini=h-mini"
    "hermes-air=h-air"
  )
  rewrites=0
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] || continue
    for rename in "${hostname_renames[@]}"; do
      old="${rename%%=*}"
      new="${rename##*=}"
      # Only touch lines that look like an HSSH_DEFAULT_HOST export
      # mentioning the old name — narrow match to avoid clobbering
      # unrelated occurrences (e.g. comments, ssh config blocks).
      if grep -qE "^[[:space:]]*export[[:space:]]+HSSH_DEFAULT_HOST=.*${old}\b" "$rc" 2>/dev/null; then
        sed -i.bak "/^[[:space:]]*export[[:space:]]\+HSSH_DEFAULT_HOST=/ s/\b${old}\b/${new}/g" "$rc"
        info "rewrote HSSH_DEFAULT_HOST: $old → $new in $rc (backup: ${rc}.bak)"
        rewrites=$((rewrites + 1))
      fi
    done
  done
  if (( rewrites > 0 )); then
    ok "hostname rewrite: $rewrites HSSH_DEFAULT_HOST update(s) applied"
  else
    skip "hostname rewrite: no stale HSSH_DEFAULT_HOST values found"
  fi
fi

# Shell aliases — common shortcuts maintained by the add-shell-alias skill.
# Lives in dotfiles/aliases.sh; gets sourced from .bashrc, .zshrc, and .profile
# so it works for bash/zsh and minimal login shells. This must not depend on
# Homebrew or tmux being installed.
if tier_allows R && ! is_skipped aliases; then
  cp "$REPO_ROOT/dotfiles/aliases.sh" "$HOME/.hermes-host-bootstrap.aliases.sh"
  for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
    touch "$rc"
    ensure_line "# ── hermes-host-bootstrap shell aliases ──" "$rc"
    ensure_line "[ -f $HOME/.hermes-host-bootstrap.aliases.sh ] && . $HOME/.hermes-host-bootstrap.aliases.sh" "$rc"
  done
  # macOS zsh login shells read .zprofile before .zshrc. If .zprofile exists
  # (or gets created by this line), source .zshrc so aliases show up in a new
  # Terminal.app window, not only in non-login interactive shells.
  if [[ "$OS" == "macos" ]]; then
    touch "$HOME/.zprofile"
    ensure_line "# ── hermes-host-bootstrap zprofile loads zshrc ──" "$HOME/.zprofile"
    ensure_line "[ -f $HOME/.zshrc ] && . $HOME/.zshrc" "$HOME/.zprofile"
  fi
  ok "shell aliases installed (hmr, hmc, hmf, hmb — sourced from shell rc files)"
fi

# Make zsh the default login shell on Linux (matches macOS defaults since
# 10.15 — gives Dan one mental model across his Mac and every Hermes host).
# Only switches when the user is currently NOT on zsh and zsh is installed.
# Skip key: chsh-zsh.
if [[ "$OS" != "macos" ]] && have zsh && tier_allows R && ! is_skipped chsh-zsh; then
  current_shell="$(getent passwd "$USER" 2>/dev/null | cut -d: -f7)"
  zsh_path="$(command -v zsh)"
  if [[ "$current_shell" != "$zsh_path" ]]; then
    if chsh -s "$zsh_path" "$USER" 2>/dev/null; then
      ok "default login shell switched to zsh ($zsh_path) — re-login to take effect"
    else
      warn "chsh -s $zsh_path failed (no sudo or PAM rules?) — run manually: chsh -s $zsh_path"
    fi
  else
    skip "default login shell is already zsh"
  fi
fi

ok "Shell setup complete"
