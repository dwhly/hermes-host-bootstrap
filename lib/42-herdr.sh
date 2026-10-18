#!/usr/bin/env bash
# 42-herdr: Herdr — "the tmux for AI agents", an agent multiplexer (Rust binary).
# https://github.com/ogulcancelik/herdr  ·  https://herdr.dev
#
# Fleet model (package-add 3-part contract, see fleet-management playbook):
#   1) this install module (auto-discovered by the bootstrap glob),
#   2) a tiers/<tier>.txt manifest entry,
#   3) version tracking in lib/99-register-host.sh (*_VER + versions:).
# Plus a verify.sh verify_check for console visibility.
#
# WHY a release-binary install (not `curl … | sh`): herdr ships per-OS/arch static
# binaries on GitHub releases; downloading the exact asset to ~/.local/bin is
# reproducible and avoids piping a remote script into a shell. Herdr runs a
# PER-HOST server that multiplexes THAT host's local PTYs (the hermes sessions on
# that node), so every node that runs agents needs its own herdr. See the herdr
# research page in the automation wiki for the fleet-fit rationale.
#
# Also links the Herdr workspace + independent-agent helpers and renders the
# fleet keybinding (Ctrl-b, then a) into Herdr's config. Skip key: herdr.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

step "Herdr (agent multiplexer)"

# The record is the sole editable floor/install/tier policy for this interim owner.
if ! pkg_tier="$(pkg_field herdr tier)" || ! skip_key="$(pkg_field herdr skip_key)"; then
  warn "herdr: missing/invalid packages/herdr.yaml — leaving binaries untouched"
  return 0 2>/dev/null || exit 0
fi
if ! tier_allows "$pkg_tier"; then
  skip "herdr skipped (tier below $pkg_tier)"
  return 0 2>/dev/null || exit 0
fi
if is_skipped "$skip_key"; then
  skip "herdr skipped (HERMES_SKIP includes $skip_key)"
  return 0 2>/dev/null || exit 0
fi

install_dir="$HOME/.local/bin"

herdr_version() {
  local output
  output="$("$1" --version </dev/null 2>/dev/null)" || return 1
  [[ "$output" =~ ^herdr[[:space:]]+([0-9]+(\.[0-9]+)*)[[:space:]]*$ ]] || return 1
  printf '%s\n' "${BASH_REMATCH[1]}"
}

# A process owned by any user defers, even if no binary is currently on PATH.
herdr_processes_idle() {
  local process_status
  if pgrep -x herdr >/dev/null 2>&1; then
    return 1
  else
    process_status=$?
    [[ "$process_status" -eq 1 ]]
  fi
}

# Both probes must establish idleness when a binary is available. Unsupported
# session-list commands and unfamiliar output fail closed.
herdr_idle() {
  local binary="$1" sessions idle=1
  if [[ -z "$binary" ]]; then
    herdr_processes_idle
    return
  fi
  if sessions="$("$binary" session list </dev/null 2>/dev/null)"; then
    if printf '%s\n' "$sessions" | awk '
      BEGIN { known=0; unsafe=0; status_col=2 }
      {
        line=tolower($0)
        if (line ~ /^[[:space:]]*$/) next
        if (line ~ /^[[:space:]]*no sessions( found)?\.?[[:space:]]*$/) { known=1; next }
        running=0; header=0
        for (i=1; i<=NF; i++) {
          word=tolower($i)
          if (word == "running") running=1
          if (word == "status") header=i
        }
        if (running) { unsafe=1; next }
        if (header && tolower($1) ~ /^(name|session|sessions)$/) { status_col=header; next }
        if (tolower($status_col) == "stopped") { known=1; next }
        if (line ~ /^[[:space:]+|=-]+$/) next
        unsafe=1
      }
      END { exit !(known && !unsafe) }
    '; then
      idle=0
    fi
  fi
  herdr_processes_idle || idle=1
  return "$idle"
}

herdr_defer() {
  warn "herdr: installed $1, floor $2 — upgrade deferred: Herdr is running or activity detection is unknown. Run 'herdr update --handoff' in an operator window, or stop the sessions and re-run 'bootstrap.sh --only=42-herdr'."
}

# Failure/deferral returns nonzero; existing installs retain their usual setup below.
herdr_ensure_floor() {
  local target="$install_dir/herdr" floor source destination verify record_id
  local installed=none path_binary path_version activity_binary=""
  local os_tag arch_tag asset digest actual url staged
  # The destination is a literal scalar in the record; do not expand its tilde.
  # shellcheck disable=SC2088
  if ! floor="$(pkg_field herdr minimum_version)" || ! version_valid "$floor" ||
     ! record_id="$(pkg_field herdr id)" || [[ "$record_id" != herdr ]] ||
     ! source="$(pkg_field herdr source)" || [[ "$source" != 'github-release ogulcancelik/herdr' ]] ||
     ! destination="$(pkg_field herdr destination)" || [[ "$destination" != '~/.local/bin/herdr' ]] ||
     ! verify="$(pkg_field herdr verify)" || [[ "$verify" != --version ]]; then
    warn "herdr: missing/invalid packages/herdr.yaml — leaving binaries untouched"
    return 1
  fi

  if [[ -e "$target" || -L "$target" ]]; then
    installed="$(herdr_version "$target")" || installed=unknown
    activity_binary="$target"
  fi
  path_binary="$(command -v herdr || true)"
  if [[ -n "$path_binary" && "$path_binary" != "$target" ]]; then
    path_version="$(herdr_version "$path_binary")" || path_version=unknown
    warn "herdr: PATH shadow: $path_binary ($path_version); fleet destination $target ($installed). A copy at $path_binary shadows the fleet binary for tools that put Homebrew first; if stale, consider 'brew uninstall herdr'."
    [[ -n "$activity_binary" ]] || activity_binary="$path_binary"
  fi
  if [[ "$installed" == unknown ]]; then
    warn "herdr: unparsable installed version at $target (floor $floor) — leaving binary untouched"
    return 1
  fi
  if [[ "$installed" != none ]] && ! version_lt "$installed" "$floor"; then
    skip "herdr $installed meets floor $floor"
    return 0
  fi

  case "$OS" in
    macos) os_tag=macos ;;
    ubuntu|debian|linux) os_tag=linux ;;
    *)
      if [[ "$(uname -s)" == Linux ]]; then os_tag=linux
      else warn "herdr: unsupported OS '$OS' — skipping"; return 1; fi ;;
  esac
  case "$ARCH" in
    arm64|aarch64) arch_tag=aarch64 ;;
    x86_64|amd64) arch_tag=x86_64 ;;
    *) warn "herdr: unsupported arch '$ARCH' — skipping"; return 1 ;;
  esac
  if ! asset="$(pkg_field herdr "asset_${os_tag}_${arch_tag}")" ||
     [[ "$asset" != "herdr-${os_tag}-${arch_tag}" ]] ||
     ! digest="$(pkg_field herdr "sha256_${os_tag}_${arch_tag}")" ||
     [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
    warn "herdr: missing/invalid asset or digest for $os_tag/$arch_tag — leaving binaries untouched"
    return 1
  fi
  if ! herdr_idle "$activity_binary"; then
    herdr_defer "$installed" "$floor"
    return 1
  fi

  url="https://github.com/${source#github-release }/releases/download/v${floor}/${asset}"
  info "installing herdr $floor ($asset) → $target"
  if ! mkdir -p "$install_dir" || ! staged="$(mktemp "$install_dir/.herdr.XXXXXX")"; then
    warn "herdr: cannot stage in $install_dir — leaving binary untouched"
    return 1
  fi
  if ! curl -fsSL --connect-timeout 20 --max-time 300 "$url" -o "$staged" || [[ ! -s "$staged" ]]; then
    rm -f "$staged"
    warn "herdr: download failed ($url) — leaving binary untouched"
    return 1
  fi
  if ! actual="$(sha256_of "$staged")" || [[ "$actual" != "$digest" ]]; then
    rm -f "$staged"
    warn "herdr: sha256 mismatch or verification failed — leaving binary untouched"
    return 1
  fi
  if ! chmod 0755 "$staged" || ! actual="$(herdr_version "$staged")" || [[ "$actual" != "$floor" ]]; then
    rm -f "$staged"
    warn "herdr: staged --version does not equal $floor — leaving binary untouched"
    return 1
  fi
  # Recheck after the download so a newly started session also causes deferral.
  if ! herdr_idle "$activity_binary"; then
    rm -f "$staged"
    herdr_defer "$installed" "$floor"
    return 1
  fi
  if [[ "$installed" != none ]]; then
    if ! cp -p "$target" "$staged.prev" || ! mv -f "$staged.prev" "$target.prev"; then
      rm -f "$staged" "$staged.prev"
      warn "herdr: could not save $target.prev — leaving binary untouched"
      return 1
    fi
  fi
  if ! mv -f "$staged" "$target"; then
    rm -f "$staged"
    warn "herdr: atomic replacement failed — previous binary retained"
    return 1
  fi
  if ! actual="$(herdr_version "$target")" || [[ "$actual" != "$floor" ]]; then
    warn "herdr: post-install --version failed — restoring previous binary"
    if [[ "$installed" != none ]]; then
      mv -f "$target.prev" "$target" || warn "herdr: restore failed; restore $target.prev manually"
    else
      rm -f "$target" || warn "herdr: could not remove failed fresh install at $target"
    fi
    return 1
  fi
  ok "herdr installed: $actual (previous binary: $target.prev when upgrading)"
}

if ! herdr_ensure_floor && [[ ! -x "$install_dir/herdr" ]]; then
  return 0 2>/dev/null || exit 0
fi

# ── Symlink explicit workspace backend wrappers onto PATH ──────────────────
if [[ -f "$REPO_ROOT/scripts/hmw-herdr.sh" ]]; then
  chmod +x "$REPO_ROOT/scripts/hmw-herdr.sh" 2>/dev/null || true
  ln -sf "$REPO_ROOT/scripts/hmw-herdr.sh" "$install_dir/hmw-herdr"
  ok "linked hmw-herdr → $install_dir/hmw-herdr (explicit Herdr workspace backend)"
fi
if [[ -f "$REPO_ROOT/scripts/hmw-tmux.sh" ]]; then
  chmod +x "$REPO_ROOT/scripts/hmw-tmux.sh" 2>/dev/null || true
  ln -sf "$REPO_ROOT/scripts/hmw-tmux.sh" "$install_dir/hmw-tmux"
  ok "linked hmw-tmux → $install_dir/hmw-tmux (explicit tmux workspace backend)"
fi

if [[ -f "$REPO_ROOT/scripts/herdr-new-agent" ]]; then
  chmod +x "$REPO_ROOT/scripts/herdr-new-agent" 2>/dev/null || true
  ln -sf "$REPO_ROOT/scripts/herdr-new-agent" "$install_dir/herdr-new-agent"
  ok "linked herdr-new-agent → $install_dir/herdr-new-agent"
fi

# A plain split inherits the shell and may autoattach the same tmux session.
# This semantic action starts a new `hermes-pane HN` process/session instead.
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/herdr"
config_file="$config_dir/config.toml"
mkdir -p "$config_dir"
touch "$config_file"
python3 - "$config_file" <<'PY'
from pathlib import Path
import re, sys

path = Path(sys.argv[1])
text = path.read_text()
block = '''# BEGIN HERMES FLEET KEYBINDINGS
[[keys.command]]
key = "prefix+a"
type = "shell"
command = "herdr-new-agent right"
# END HERMES FLEET KEYBINDINGS'''
pattern = re.compile(r'(?ms)^# BEGIN HERMES FLEET KEYBINDINGS\n.*?^# END HERMES FLEET KEYBINDINGS\n?')
if pattern.search(text):
    text = pattern.sub(block + "\n", text)
else:
    text = text.rstrip() + ("\n\n" if text.strip() else "") + block + "\n"
path.write_text(text)
PY
ok "Herdr Ctrl-b, a → fresh Hermes agent to the right"

# Reload applies config to a running server without terminating its agents.
herdr_bin="$install_dir/herdr"; have herdr && herdr_bin="herdr"
if "$herdr_bin" status server --json 2>/dev/null | grep -q '"running":true'; then
  "$herdr_bin" server reload-config >/dev/null 2>&1 || warn "Herdr config written; reload it with: herdr server reload-config"
fi

# ── Install the Hermes agent-state integration ────────────────────────────
# Without this, herdr can't tell a Hermes pane's state and the sidebar always
# shows "idle". The integration is a Hermes plugin
# (~/.hermes/plugins/herdr-agent-state/) that reports working/blocked/idle from
# Hermes lifecycle hooks (pre_llm_call→working, pre_approval_request→blocked,
# post_llm_call→idle) to herdr's socket when running inside a herdr pane.
# Idempotent: `herdr integration install hermes` re-installs/updates in place.
herdr_bin="$install_dir/herdr"; have herdr && herdr_bin="herdr"
if "$herdr_bin" integration status 2>/dev/null | grep -q "hermes: current"; then
  skip "herdr hermes integration already current"
else
  info "installing herdr↔hermes agent-state integration (fixes 'always idle' sidebar)"
  if "$herdr_bin" integration install hermes 2>&1 | grep -qiE "installed|enabled|current"; then
    ok "herdr hermes integration installed ($("$herdr_bin" integration status 2>/dev/null | grep -o 'hermes: [^(]*' | head -1))"
  else
    warn "herdr hermes integration install failed — run: herdr integration install hermes"
  fi
fi
