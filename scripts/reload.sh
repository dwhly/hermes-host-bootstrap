#!/usr/bin/env bash
# scripts/reload.sh — pull latest bootstrap repo and re-run it on this host.
#
# Symlinked to ~/.local/bin/hermes-reload by lib/30-shell.sh. Usable from
# anywhere as `hermes-reload`, plus aliased to `r` in dotfiles/aliases.sh
# for one-keystroke daily use.
#
# Usage:
#   hermes-reload                     # default: git pull + ./bootstrap.sh --tier=recommended --noninteractive
#   hermes-reload --only=30-shell     # forward args to bootstrap.sh
#   hermes-reload --dry-run           # preview without applying
#   hermes-reload --no-pull           # skip git pull (useful in offline / testing flows)
#   hermes-reload --prompt            # allow prompts (e.g. when you DO want to rename or re-tag)
#   hermes-reload --prompt --rename   # force hostname re-prompt
#   hermes-reload --prompt --retag    # force note re-prompt
#   hermes-reload --interactive-sudo   # macOS: re-exec through ssh -tt localhost so sudo/Homebrew can prompt
#
# Tier and role default to whatever's in ~/.hermes-bootstrap.conf if it
# exists, otherwise --tier=recommended for the user to override.
#
# `hermes-reload` defaults to --noninteractive because the common case is
# "re-apply latest config, don't ask me to re-identify the box every time."
# Pass --prompt to override (e.g. paired with --rename or --retag).

set -euo pipefail

# ── locate the clone ────────────────────────────────────────────────
# Standard places we look, in order:
#   1. $HERMES_HOST_BOOTSTRAP_DIR if set (explicit override)
#   2. ~/code/hermes-host-bootstrap/hermes-host-bootstrap (Dan's Mac layout)
#   3. ~/hermes-host-bootstrap (common Linux user clone)
#   4. /tmp/hhb-work/hermes-host-bootstrap (agent's working clone)
#   5. The directory containing THIS script (when invoked via symlink resolution)
#
# If none of the above are git repos, fall back to fresh-cloning into ~/.hermes/hermes-host-bootstrap.

REPO_URL="https://github.com/dwhly/hermes-host-bootstrap.git"
FALLBACK_CLONE="$HOME/.hermes/hermes-host-bootstrap"

find_clone() {
  local candidates=(
    "${HERMES_HOST_BOOTSTRAP_DIR:-}"
    "$HOME/code/hermes-host-bootstrap/hermes-host-bootstrap"
    "$HOME/hermes-host-bootstrap"
    "/tmp/hhb-work/hermes-host-bootstrap"
    "$FALLBACK_CLONE"
  )
  # Also try the directory containing the actual (resolved) script path.
  local script_path
  if [[ -L "${BASH_SOURCE[0]}" ]]; then
    script_path="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || readlink "${BASH_SOURCE[0]}")"
  else
    script_path="${BASH_SOURCE[0]}"
  fi
  if [[ -n "$script_path" ]]; then
    # script lives at $clone/scripts/reload.sh, so the clone is two levels up
    candidates+=("$(cd "$(dirname "$script_path")/.." 2>/dev/null && pwd)")
  fi

  for d in "${candidates[@]}"; do
    [[ -z "$d" ]] && continue
    if [[ -d "$d/.git" && -f "$d/bootstrap.sh" ]]; then
      echo "$d"
      return 0
    fi
  done

  return 1
}

clone_fresh() {
  echo "==> No existing clone found. Cloning fresh into $FALLBACK_CLONE"
  mkdir -p "$(dirname "$FALLBACK_CLONE")"
  git clone "$REPO_URL" "$FALLBACK_CLONE"
  echo "$FALLBACK_CLONE"
}

# ── parse our own flags before forwarding to bootstrap.sh ───────────
DO_PULL=1
ALLOW_PROMPTS=0
INTERACTIVE_SUDO=0
PASSTHROUGH=()
for arg in "$@"; do
  case "$arg" in
    --no-pull)
      DO_PULL=0
      ;;
    --prompt)
      ALLOW_PROMPTS=1
      ;;
    --interactive-sudo)
      INTERACTIVE_SUDO=1
      ;;
    --help|-h)
      sed -n '2,24p' "$0" | sed 's/^#\s\{0,1\}//'
      exit 0
      ;;
    *)
      PASSTHROUGH+=("$arg")
      ;;
  esac
done

# ── locate or clone the repo ────────────────────────────────────────
clone="$(find_clone)" || clone="$(clone_fresh)"
echo "==> Using clone: $clone"

# ── git pull (unless --no-pull) ─────────────────────────────────────
if [[ "$DO_PULL" -eq 1 ]]; then
  echo "==> git pull"
  git -C "$clone" pull --ff-only || {
    echo "==> Non-fast-forward pull. Try 'git -C $clone status' to inspect."
    exit 1
  }
fi

# ── re-run bootstrap.sh with passthrough args ───────────────────────
# Default to --tier=recommended if user didn't specify a tier.
#
# Note: empty bash arrays under `set -u` need careful expansion. Both
# `${ARR[@]:-}` and `${ARR[*]:-}` add a spurious empty-string element to
# the expansion when ARR is empty, which trips bootstrap.sh's arg parser
# with "unknown arg: ". The correct idiom is `${ARR[@]+"${ARR[@]}"}` — it
# expands to the array if set, otherwise to nothing (zero elements).
has_tier=0
for arg in ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}; do
  case "$arg" in
    --tier=*) has_tier=1 ;;
  esac
done
if [[ "$has_tier" -eq 0 ]]; then
  PASSTHROUGH=("--tier=recommended" ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"})
fi

# Default to --noninteractive unless --prompt was passed. This is the
# whole point of `hermes-reload` vs running bootstrap.sh directly:
# silent re-apply for daily use.
if [[ "$ALLOW_PROMPTS" -eq 0 ]]; then
  PASSTHROUGH+=("--noninteractive")
fi

echo "==> $clone/bootstrap.sh ${PASSTHROUGH[*]}"

# macOS first bootstrap often needs sudo for Homebrew. When the current SSH
# command has no TTY, sudo cannot prompt; re-enter through localhost with -tt
# if requested so the password prompt is visible in the caller's terminal.
if [[ "$INTERACTIVE_SUDO" -eq 1 ]]; then
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "==> --interactive-sudo is only needed on macOS; running directly"
  elif [[ -t 0 ]]; then
    echo "==> TTY already present; running directly"
  else
    target="${USER:-$(id -un)}@localhost"
    if ssh -o BatchMode=yes -o ConnectTimeout=2 "$target" true >/dev/null 2>&1; then
      quoted_args=""
      for arg in ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}; do
        quoted_args+=" $(printf '%q' "$arg")"
      done
      echo "==> Re-execing via ssh -tt $target for sudo/Homebrew prompts"
      exec ssh -tt "$target" "$(printf '%q' "$clone/bootstrap.sh")$quoted_args"
    else
      echo "==> --interactive-sudo requested, but key-based ssh to $target is not available." >&2
      echo "==> Run this in Terminal.app on the Mac instead:" >&2
      echo "    $clone/bootstrap.sh ${PASSTHROUGH[*]//--noninteractive/}" >&2
      exit 1
    fi
  fi
fi

exec "$clone/bootstrap.sh" "${PASSTHROUGH[@]}"
