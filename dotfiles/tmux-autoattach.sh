# ── hermes-host-bootstrap tmux auto-attach ──
# shellcheck shell=sh
# Sourced from ~/.bashrc and/or ~/.zshrc. Safe to re-source.
#
# When you SSH (or mosh) into the box for an interactive login, this drops
# you into a tmux session named "main" — attaching to an existing one if
# present, otherwise creating it. Disconnects don't kill anything; just
# reconnect to pick up where you left off.
#
# Guards (all must be true to fire):
#   - tmux is on PATH
#   - we're NOT already inside a tmux session ($TMUX unset)
#   - we ARE inside an SSH/mosh session ($SSH_CONNECTION or $SSH_TTY set)
#   - the shell is interactive ($- contains 'i')
#
# This deliberately skips scp/rsync/non-interactive ssh commands.
#
# Opt out per-session: `NO_TMUX=1 ssh host`
# Opt out permanently: comment out the source line in your rc file, or
# delete this file.

if command -v tmux >/dev/null 2>&1 \
   && [ -z "${TMUX:-}" ] \
   && [ -z "${NO_TMUX:-}" ] \
   && { [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_TTY:-}" ]; } \
   && case "$-" in *i*) true ;; *) false ;; esac
then
  tmux attach -t main 2>/dev/null || exec tmux new -s main
fi
