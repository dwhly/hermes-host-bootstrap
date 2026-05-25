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
#   --rename                            force the hostname prompt even if box is already in fleet registry
#   --retag                             force the note prompt even if a note already exists
#   --noninteractive                    skip ALL prompts (equivalent to HERMES_NONINTERACTIVE=1)
#   --self-update                       git pull && re-exec (if cloned)
#   -h | --help                         show help

set -euo pipefail

# ── Personal config (optional) ──
# Source ~/.hermes-bootstrap.conf if it exists. This is where personal/
# machine-specific defaults live — git identity for commits, default tier,
# preferred hostname, etc. — so the repo itself stays neutral and forkable.
# See `.hermes-bootstrap.conf.example` in this repo for available vars.
# Anyone using this repo can drop their own ~/.hermes-bootstrap.conf with
# their own settings; the file is intentionally outside the repo.
if [[ -f "$HOME/.hermes-bootstrap.conf" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.hermes-bootstrap.conf"
fi

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
# Honor HERMES_DEFAULT_TIER / HERMES_DEFAULT_ROLE from ~/.hermes-bootstrap.conf
# if set; otherwise use repo defaults.
TIER="${HERMES_DEFAULT_TIER:-recommended}"
SKIP_KEYS=()
ONLY_MODS=()
DRY_RUN=0
ROLE_CLI="${HERMES_DEFAULT_ROLE:-}"

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
    --rename) export HERMES_FORCE_RENAME=1; shift ;;
    --retag)  export HERMES_FORCE_RETAG=1; shift ;;
    --noninteractive|--non-interactive)
      export HERMES_NONINTERACTIVE=1; shift ;;
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

# ── Interactive host identity prompt ─────────────────────────────────
# Ask the user for a friendly hostname + one-line "what is this box for"
# note that will land in the host registry yaml.
#
# Suppressed when:
#   - stdin is not a tty (curl|bash, ssh-with-command)
#   - HERMES_NONINTERACTIVE=1 (set by hermes-reload for daily reruns)
#   - DRY_RUN is on
#
# Each prompt has its own skip-when-known logic:
#   - Hostname prompt: skipped if HERMES_HOSTNAME is set in env/conf, OR
#     the current OS hostname matches a host already registered in
#     ~/.hermes/hosts/. The 'I already know this box' case prints one
#     quiet line so it's discoverable; pass --rename to force the prompt.
#   - Note prompt: skipped if HERMES_HOST_NOTE is set, OR the registry
#     yaml for this host already has a non-empty note. Pass --retag to
#     force the prompt and overwrite.
#
# The note ultimately lands in ~/.hermes/hosts/<hostname>.yaml under `note:`.
if [[ -t 0 ]] && [[ "${HERMES_NONINTERACTIVE:-0}" != "1" ]] && [[ "$DRY_RUN" -eq 0 ]]; then
  current_host="$(hostname -s 2>/dev/null || hostname)"
  fleet_dir="${HERMES_HOME:-$HOME/.hermes}/hosts"

  # Hostname prompt — skip if already set via env / conf, OR if the
  # current OS hostname is already registered (we recognize this box).
  registered_yaml=""
  if [[ -f "$fleet_dir/${current_host}.yaml" ]]; then
    registered_yaml="$fleet_dir/${current_host}.yaml"
  fi

  if [[ -n "${HERMES_HOSTNAME:-}" ]]; then
    : # already set, no prompt
  elif [[ -n "$registered_yaml" ]] && [[ "${HERMES_FORCE_RENAME:-0}" != "1" ]]; then
    # Box already in fleet registry. Skip silently except for one quiet line.
    echo "${_C_DIM}known host: $current_host (re-register via --rename)${_C_RESET}"
    export HERMES_HOSTNAME="$current_host"
  else
    # Show known fleet hostnames so the user doesn't pick a collision
    if [[ -d "$fleet_dir" ]] && [[ -n "$(ls -A "$fleet_dir"/*.yaml 2>/dev/null)" ]]; then
      echo "${_C_DIM}existing fleet hostnames:${_C_RESET}"
      ls "$fleet_dir"/*.yaml 2>/dev/null | sed 's|.*/||; s|\.yaml$||; s|^|    - |'
      echo ""
    fi

    echo "${_C_BOLD}Hostname${_C_RESET} for this machine in the Hermes fleet."
    echo "  current OS hostname: ${_C_DIM}$current_host${_C_RESET}"
    echo "  pick a short, unique name (e.g. hermes-do1, mac-mini, hetzner-builder)"
    echo "  ${_C_DIM}empty = keep '$current_host', no rename${_C_RESET}"
    printf "> "
    read -r answer || answer=""
    if [[ -n "$answer" ]]; then
      # Basic sanity: alphanumerics, dashes, dots only. No spaces.
      if [[ "$answer" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        export HERMES_HOSTNAME="$answer"
        echo "  → will rename to: $HERMES_HOSTNAME"
      else
        warn "  '$answer' has invalid characters — keeping '$current_host'"
      fi
    fi
    echo ""
  fi

  # Note prompt — skip if HERMES_HOST_NOTE is set, OR if the registry yaml
  # for this hostname already has a non-empty note. Override with
  # HERMES_FORCE_RETAG=1 (set via --retag).
  effective_host="${HERMES_HOSTNAME:-$current_host}"
  note_file="$fleet_dir/${effective_host}.yaml"
  existing_note=""
  if [[ -f "$note_file" ]]; then
    existing_note="$(awk -F': ' '/^note:/ {sub(/^note:[[:space:]]*/, ""); gsub(/^"|"$/, ""); print; exit}' "$note_file" 2>/dev/null)"
  fi

  if [[ -n "${HERMES_HOST_NOTE:-}" ]]; then
    : # already set via env/conf, no prompt
  elif [[ -n "$existing_note" ]] && [[ "${HERMES_FORCE_RETAG:-0}" != "1" ]]; then
    # Existing note found, silently inherit it. (Don't even print —
    # the hostname line above is enough acknowledgment of "I know this box".)
    export HERMES_HOST_NOTE="$existing_note"
  else
    echo "${_C_BOLD}One-line note${_C_RESET} — what is this machine for?"
    echo "  e.g. 'main production VPS for hermes', 'macbook M2 daily driver', 'hetzner build farm'"
    if [[ -n "$existing_note" ]]; then
      echo "  current note: ${_C_DIM}\"$existing_note\"${_C_RESET}"
      echo "  ${_C_DIM}empty = keep existing note${_C_RESET}"
    else
      echo "  ${_C_DIM}empty = skip (registry will have no note for this host)${_C_RESET}"
    fi
    printf "> "
    read -r note_input || note_input=""
    if [[ -n "$note_input" ]]; then
      # Strip surrounding quotes the user might have typed, and any `"` that
      # would break the yaml.
      note_input="${note_input//\"/}"
      export HERMES_HOST_NOTE="$note_input"
    elif [[ -n "$existing_note" ]]; then
      export HERMES_HOST_NOTE="$existing_note"
    fi
    echo ""
  fi
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
#
# NOTE: avoid `mapfile` here — macOS ships bash 3.2 which lacks it.
# This while-read loop is the portable equivalent.
ALL_MODS=()
while IFS= read -r _mod; do
  ALL_MODS+=("$_mod")
done < <(find "$REPO_ROOT/lib" -maxdepth 1 -name '[0-9A-Z][0-9A-Z]-*.sh' -print | sort | xargs -n1 basename | sed 's/\.sh$//')

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
verify "tmux-autoattach" "test -f $HOME/.hermes-host-bootstrap.tmux-autoattach.sh && echo present"
verify "hssh"       "test -f $HOME/.hermes-host-bootstrap.hssh.sh && echo present"
verify "tmux-workspace-colors" "test -f $HOME/.hermes-host-bootstrap.tmux-workspace-colors.conf && echo present"
verify "aliases"     "test -f $HOME/.hermes-host-bootstrap.aliases.sh && echo present"
verify "op"          "op --version 2>&1 | head -1"
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
verify "hermes-fleet"   "hermes-fleet --help 2>&1 | head -1"
verify "hermes-reload"  "test -L $HOME/.local/bin/hermes-reload && echo present"

echo ""
ok "Bootstrap finished. Next steps:"
echo "   1. log out + back in so PATH + docker group + linger take effect"
echo "   2. hermes setup          # configure model / provider"
echo "   3. hermes doctor         # sanity-check the install"
echo "   4. hermes gateway setup  # if you want Telegram / Discord / etc."
echo "   5. sudo tailscale up     # if you installed tailscale"
echo ""
log "bootstrap finished"
