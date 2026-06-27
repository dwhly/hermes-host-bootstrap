# ── hermes-host-bootstrap aliases.sh ──
# Sourced from .bashrc and .zshrc. Works in both shells (POSIX-compatible
# `alias` syntax). Maintained by the `add-shell-alias` skill — see
# ~/.hermes/skills/devops/add-shell-alias/SKILL.md
#
# Convention: alias declarations are grouped into named sections, in
# insertion order. The skill appends new aliases to the right section
# based on the BEGIN/END markers below. Don't rename markers — the
# skill keys off them.

# ── BEGIN core ──
alias h='history'
# ── END core ──

# ── BEGIN hermes ──
# Convention: every hm-prefixed alias maps 1:1 to a real command of the
# form `hermes-<verb>`. The long form is always available; the short alias
# is for daily fingerprint efficiency. Add new ones via the
# `add-shell-alias` skill (which also creates the underlying real command
# when it's a new helper script).
alias hm='hermes'
alias hmr='hermes-reload'
alias hmc='hermes-config'
alias hmf='hermes-fleet'
alias hmb='hermes-backlog'
alias hmw='hermes-workspace'
alias hmwiki='hermes-wiki'
alias hmreset='hermes-terminal-reset'
alias hmx='hermes-exit'
# ── END hermes ──

# ── BEGIN git ──
# (empty — add git-related aliases here via the add-shell-alias skill)
# ── END git ──

# ── BEGIN tmux ──
# (empty — add tmux-related aliases here via the add-shell-alias skill)
# ── END tmux ──

# ── BEGIN misc ──
# (empty — catch-all for aliases that don't fit other sections)

# Hermes TUI: point at the prebuilt bundle so `hermes --tui` /
# display.interface=tui launches instantly instead of re-running npm install +
# esbuild on every launch (the content-hash heuristic always flags install in
# the editable/git install layout). Path is derived from the `hermes` launcher
# shim so it's correct on every host (h-do1: /usr/local/lib/hermes-agent;
# Macs: ~/.hermes/hermes-agent). After a `hermes update`, rebuild once:
#   ( cd "$HERMES_TUI_DIR" && npm run build )
if [ -z "${HERMES_TUI_DIR:-}" ] && command -v hermes >/dev/null 2>&1; then
  __hermes_shim="$(command -v hermes)"
  __hermes_venv="$(grep -oE '"[^"]*venv/bin/hermes"' "$__hermes_shim" 2>/dev/null | head -1 | tr -d '"')"
  [ -z "$__hermes_venv" ] && __hermes_venv="$(readlink -f "$__hermes_shim" 2>/dev/null)"
  if [ -n "$__hermes_venv" ]; then
    __hermes_root="$(dirname "$(dirname "$(dirname "$__hermes_venv")")")"
    [ -f "$__hermes_root/ui-tui/dist/entry.js" ] && export HERMES_TUI_DIR="$__hermes_root/ui-tui"
  fi
  unset __hermes_shim __hermes_venv __hermes_root
fi
# ── END misc ──
