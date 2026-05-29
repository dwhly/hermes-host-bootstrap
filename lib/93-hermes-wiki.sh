#!/usr/bin/env bash
# 93-hermes-wiki: install a local copy of Dan's Hermes Automation Wiki.
#
# The wiki is Markdown-first source plus generated static HTML. This module
# clones/pulls the local copy and publishes HTML so `hermes-wiki` / `hmwiki`
# can open it from a local terminal.
#
# Skip keys:
#   hermes-wiki       skip this whole module
#   hermes-wiki-pull  skip git pull when the wiki repo already exists
#   hermes-wiki-build skip scripts/publish.py

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Hermes automation wiki"

if is_skipped hermes-wiki; then
  skip "hermes-wiki — opted out via --skip"
  return 0 2>/dev/null || exit 0
fi

WIKI_REPO="${HERMES_WIKI_REPO:-}"
WIKI_DIR="${HERMES_WIKI_DIR:-$HOME/code/hermes-automation-wiki}"

if [[ -z "$WIKI_REPO" ]]; then
  skip "HERMES_WIKI_REPO not set — local wiki clone skipped"
  info "set HERMES_WIKI_REPO in ~/.hermes-bootstrap.conf to clone/pull the wiki"
  return 0 2>/dev/null || exit 0
fi

if ! have git; then
  warn "git not installed — cannot clone/pull wiki"
  return 0 2>/dev/null || exit 0
fi

mkdir -p "$(dirname "$WIKI_DIR")"

if [[ -d "$WIKI_DIR/.git" ]]; then
  ok "$WIKI_DIR is already git-tracked"
  if ! is_skipped hermes-wiki-pull; then
    info "fetching wiki repo"
    if git -C "$WIKI_DIR" fetch origin --prune; then
      current_branch="$(git -C "$WIKI_DIR" branch --show-current 2>/dev/null || echo main)"
      if git -C "$WIKI_DIR" rev-parse --verify "origin/$current_branch" >/dev/null 2>&1; then
        if git -C "$WIKI_DIR" merge-base --is-ancestor HEAD "origin/$current_branch" 2>/dev/null; then
          git -C "$WIKI_DIR" merge --ff-only "origin/$current_branch" || warn "wiki fast-forward merge failed"
        else
          warn "local wiki has commits not on origin/$current_branch — not auto-merging"
        fi
      fi
    else
      warn "wiki git fetch failed — keeping existing local copy"
    fi
  fi
elif [[ -e "$WIKI_DIR" ]]; then
  warn "$WIKI_DIR exists but is not a git repo — leaving it untouched"
  warn "set HERMES_WIKI_DIR elsewhere or move the existing directory"
  return 0 2>/dev/null || exit 0
else
  info "cloning wiki: $WIKI_REPO → $WIKI_DIR"
  if git clone "$WIKI_REPO" "$WIKI_DIR"; then
    ok "wiki repo cloned"
  else
    warn "wiki clone failed — check GitHub auth / repository URL"
    return 0 2>/dev/null || exit 0
  fi
fi

if [[ -f "$WIKI_DIR/scripts/publish.py" ]] && ! is_skipped hermes-wiki-build; then
  info "publishing local wiki HTML"
  if [[ -x "$WIKI_DIR/scripts/publish.py" ]]; then
    "$WIKI_DIR/scripts/publish.py" >/dev/null || warn "wiki publish failed"
  else
    python3 "$WIKI_DIR/scripts/publish.py" >/dev/null || warn "wiki publish failed"
  fi
fi

if [[ -f "$WIKI_DIR/public/index.html" ]]; then
  ok "local wiki ready: $WIKI_DIR/public/index.html"
else
  warn "wiki HTML not found yet: $WIKI_DIR/public/index.html"
fi
