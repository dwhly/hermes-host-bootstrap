# shellcheck shell=bash
# ── hermes-host-bootstrap mouse-heal snippet ──
# Sourced from .bashrc and .zshrc (POSIX-ish; bash + zsh aware).
#
# WHY THIS EXISTS
#   `hmw` attaches a mouse-enabled tmux (`set -g mouse on`) over `ssh -t`. tmux
#   puts the OUTER terminal into SGR mouse-tracking mode for the duration. On a
#   clean detach tmux restores it, but if the connection is yanked (tab closed,
#   network blip, SIGHUP) the restore never runs and the outer terminal is left
#   spewing raw `<35;..M` mouse codes onto the prompt.
#
# WHAT THIS DOES
#   Emits the mouse-tracking DISABLE sequences every time a prompt is drawn —
#   but ONLY when we are NOT inside tmux ($TMUX unset). That is exactly the
#   "I just landed back at a bare local shell after a workspace connection went
#   away" condition. Crucially, the $TMUX guard means it NEVER fires inside a
#   tmux pane, so it can't fight tmux's own mouse mode (scroll/selection inside
#   panes keeps working).
#
#   The disable battery includes mouse/focus reporting plus the extended-key
#   modes (Kitty keyboard stack and xterm modifyOtherKeys). A dropped Herdr SSH
#   client can leave Ghostty reporting keys as CSI-u (`107;1:3u`) at the shell;
#   popping/disabling these modes at prompt time is safe when outside tmux.
#   It still does NOT touch alt-screen, cursor, or bracketed paste — those are
#   handled by the heavier `hmreset` helper.
#
#   Disable globally for a session with: export HERMES_NO_MOUSE_HEAL=1

__hermes_terminal_heal_bytes() {
  printf '\033[?1016l\033[?1015l\033[?1006l\033[?1003l\033[?1002l\033[?1000l\033[?9l\033[?1004l\033[<u\033[>4m'
}

__hermes_mouse_heal() {
  [ -n "${HERMES_NO_MOUSE_HEAL:-}" ] && return 0
  [ -n "${TMUX:-}" ] && return 0          # inside tmux → leave mouse mode alone
  case "$-" in *i*) ;; *) return 0 ;; esac # interactive shells only
  __hermes_terminal_heal_bytes
}

if [ -n "${ZSH_VERSION:-}" ]; then
  # zsh: run before each prompt via precmd hook (dedup-safe).
  autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook precmd __hermes_mouse_heal
elif [ -n "${BASH_VERSION:-}" ]; then
  # bash: append to PROMPT_COMMAND if not already present.
  case "${PROMPT_COMMAND:-}" in
    *__hermes_mouse_heal*) : ;;
    *) PROMPT_COMMAND="__hermes_mouse_heal${PROMPT_COMMAND:+; $PROMPT_COMMAND}" ;;
  esac
fi
