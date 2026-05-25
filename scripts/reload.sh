#!/usr/bin/env bash
# scripts/reload.sh — pull latest bootstrap repo and re-run it on this host.
#
# Symlinked to ~/.local/bin/hermes-reload by lib/30-shell.sh. Usable from
# anywhere as `hermes-reload`, plus aliased to `r` in dotfiles/aliases.sh
# for one-keystroke daily use.
#
# Usage:
#   hermes-reload                     # default: git pull + ./bootstrap.sh --tier=recommended
#   hermes-reload --only=30-shell     # forward args to bootstrap.sh
#   hermes-reload --dry-run           # preview without applying
#   hermes-reload --no-pull           # skip git pull (useful in offline / testing flows)
#
# Tier and role default to whatever's in ~/.hermes-bootstrap.conf if it
# exists, otherwise --tier=recommended for the user to override.

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
PASSTHROUGH=()
for arg in "$@"; do
  case "$arg" in
    --no-pull)
      DO_PULL=0
      ;;
    --help|-h)
      sed -n '2,20p' "$0" | sed 's/^#\s\{0,1\}//'
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
has_tier=0
for arg in "${PASSTHROUGH[@]:-}"; do
  case "$arg" in
    --tier=*) has_tier=1 ;;
  esac
done
if [[ "$has_tier" -eq 0 ]]; then
  PASSTHROUGH=("--tier=recommended" "${PASSTHROUGH[@]:-}")
fi

echo "==> $clone/bootstrap.sh ${PASSTHROUGH[*]:-}"
exec "$clone/bootstrap.sh" "${PASSTHROUGH[@]:-}"
