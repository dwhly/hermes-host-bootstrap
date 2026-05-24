#!/usr/bin/env bash
#
# hermes-host-bootstrap — set up a fresh Linux VPS (or macOS box) to be a
# capable Hermes Agent host.
#
# Usage:
#   ./bootstrap.sh                          # default: tier=recommended
#   ./bootstrap.sh --tier=minimal
#   ./bootstrap.sh --tier=full --skip=docker,zsh
#   ./bootstrap.sh --tier=recommended --only=10-security,90-agents
#
# Or one-liner (from a fresh box):
#   curl -fsSL https://raw.githubusercontent.com/dwhly/hermes-host-bootstrap/main/bootstrap.sh \
#     | bash -s -- --tier=recommended
#
# Flags:
#   --tier=<minimal|recommended|full>   default: recommended
#   --role=<server|client|both>         default: auto-detect
#                                       server = headless VPS (no GUI client apps)
#                                       client = your Mac (no xrdp/desktop)
#                                       both   = desktop Linux daily-driver
#   --skip=KEY1,KEY2,...                skip specific keywords (e.g. docker, zsh)
#   --only=MOD1,MOD2,...                run only the named modules (e.g. 90-agents)
#   --dry-run                           print the plan, don't execute
#   --self-update                       git pull && re-exec (if cloned)
#   -h | --help                         show help

set -euo pipefail

# ── Locate the repo root (handles both `./bootstrap.sh` and `curl | bash`) ──
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  # Piped from curl — clone into a temp dir
  REPO_ROOT="$(mktemp -d)/hermes-host-bootstrap"
  echo "▸ cloning hermes-host-bootstrap to $REPO_ROOT"
  git clone --depth 1 https://github.com/dwhly/hermes-host-bootstrap.git "$REPO_ROOT"
fi
export REPO_ROOT

# ── Defaults ─────────────────────────────────────────────────────────
TIER="recommended"
SKIP_KEYS=()
ONLY_MODS=()
DRY_RUN=0
ROLE_CLI=""

# ── Parse args ──────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tier=*) TIER="${1#*=}"; shift ;;
    --tier)   TIER="$2"; shift 2 ;;
    --role=*) ROLE_CLI="${1#*=}"; shift ;;
    --role)   ROLE_CLI="$2"; shift 2 ;;
    --skip=*) IFS=',' read -r -a SKIP_KEYS <<< "${1#*=}"; shift ;;
    --skip)   IFS=',' read -r -a SKIP_KEYS <<< "$2"; shift 2 ;;
    --only=*) IFS=',' read -r -a ONLY_MODS <<< "${1#*=}"; shift ;;
    --only)   IFS=',' read -r -a ONLY_MODS <<< "$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --self-update)
      cd "$REPO_ROOT" && git pull --ff-only && exec "$0" --tier="$TIER"
      ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case "$TIER" in
  minimal|recommended|full) ;;
  *) echo "invalid --tier: $TIER (use minimal|recommended|full)" >&2; exit 2 ;;
esac

# Export ROLE before sourcing common.sh so it picks up the CLI override
if [[ -n "$ROLE_CLI" ]]; then
  case "$ROLE_CLI" in
    server|client|both) export ROLE="$ROLE_CLI" ;;
    *) echo "invalid --role: $ROLE_CLI (use server|client|both)" >&2; exit 2 ;;
  esac
fi

export TIER SKIP_KEYS

# ── Source common helpers ──
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/common.sh"

# ── Banner ──
echo ""
echo "${_C_BOLD}hermes-host-bootstrap${_C_RESET}"
echo "  tier:    $TIER"
echo "  role:    $ROLE$([[ -z "$ROLE_CLI" ]] && echo " (auto-detected)" || echo " (--role)")"
echo "  os:      $OS ($ARCH)"
echo "  headless: $([[ $IS_HEADLESS -eq 1 ]] && echo yes || echo no)"
echo "  user:    ${USER}"
echo "  skip:    ${SKIP_KEYS[*]:-<none>}"
echo "  only:    ${ONLY_MODS[*]:-<all>}"
echo "  log:     $HOME/.hermes-host-bootstrap.log"
echo ""

if [[ "$DRY_RUN" -eq 1 ]]; then
  warn "DRY-RUN: would execute the following modules, then exit"
fi

# ── Tee everything to a log ──
LOGFILE="$HOME/.hermes-host-bootstrap.log"
mkdir -p "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1
log "bootstrap started (tier=$TIER os=$OS)"

# ── Module runner ──────────────────────────────────────────────────
run_module() {
  local mod="$1"
  local path="$REPO_ROOT/lib/${mod}.sh"
  if [[ ! -f "$path" ]]; then
    err "module not found: $path"
    return 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  [dry-run] would run: $mod"
    return 0
  fi

  # Run in a subshell so set -e + module-level returns don't kill the parent
  ( bash "$path" ) || {
    err "module $mod failed (continuing); see $LOGFILE"
  }
}

# Discover modules in lib/, ordered by prefix. Prefix can be:
#   NN-name.sh    (numeric — runs in numeric order: 00, 10, 20, …)
#   Xn-name.sh    (letter+digit — runs AFTER numerics, alphabetically:
#                  A0-remote-desktop, M5-mac-client, …)
# This lets us add optional/role-specific modules without renumbering.
mapfile -t ALL_MODS < <(find "$REPO_ROOT/lib" -maxdepth 1 -name '[0-9A-Z][0-9A-Z]-*.sh' -print | sort | xargs -n1 basename | sed 's/\.sh$//')

# Filter by --only if given
if [[ ${#ONLY_MODS[@]} -gt 0 ]]; then
  filtered=()
  for m in "${ALL_MODS[@]}"; do
    for o in "${ONLY_MODS[@]}"; do
      [[ "$m" == "$o" ]] && filtered+=("$m")
    done
  done
  ALL_MODS=("${filtered[@]}")
fi

if [[ ${#ALL_MODS[@]} -eq 0 ]]; then
  err "no modules to run"
  exit 1
fi

for m in "${ALL_MODS[@]}"; do
  run_module "$m"
done

# ── Final verification ──────────────────────────────────────────────
echo ""
step "Verification"

verify() {
  local name="$1" cmd="$2"
  if eval "$cmd" >/dev/null 2>&1; then
    ok "$name"
  else
    warn "$name — not found or failed"
  fi
}

verify "git"        "git --version"
verify "tmux"       "tmux -V"
verify "mosh"       "mosh-server --help 2>&1 | head -1"
verify "neovim"     "nvim --version"
verify "ripgrep"    "rg --version"
verify "fzf"        "fzf --version"
verify "jq"         "jq --version"
verify "python3"    "python3 --version"
verify "uv"         "uv --version"
verify "pipx"       "pipx --version"
verify "node"       "node --version"
verify "docker"     "docker --version"
verify "gh"         "gh --version"
verify "hermes"     "hermes --version"
verify "ffmpeg"     "ffmpeg -version"
verify "tailscale"  "tailscale version"

echo ""
ok "Bootstrap finished. Next steps:"
echo "   1. log out + back in so PATH + docker group + linger take effect"
echo "   2. hermes setup          # configure model / provider"
echo "   3. hermes doctor         # sanity-check the install"
echo "   4. hermes gateway setup  # if you want Telegram / Discord / etc."
echo "   5. sudo tailscale up     # if you installed tailscale"
echo ""
log "bootstrap finished"
