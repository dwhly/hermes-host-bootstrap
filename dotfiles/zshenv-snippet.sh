# ── hermes-host-bootstrap zshenv snippet ──
# Sourced from ~/.zshenv, which zsh reads for EVERY invocation — interactive,
# login, AND non-interactive (`zsh -c` / `zsh -lc`). This is the ONLY zsh
# startup file guaranteed to run for a non-interactive command shell.
#
# WHY THIS EXISTS: the PATH tweaks that put ~/.local/bin (and friends) on PATH
# historically lived only in the zshrc snippet (.zshrc). But .zshrc is sourced
# for INTERACTIVE shells only. A non-interactive login shell — exactly what
# `ssh host 'zsh -lc "some-cli"'` spawns (e.g. hermes-workspace's remote
# dispatch) — sources .zprofile/.zlogin but SKIPS .zshrc, so fleet CLIs in
# ~/.local/bin came back "command not found". Putting the bin dirs here fixes
# that whole class of bug at the source.
#
# Keep this MINIMAL and side-effect-free: .zshenv runs for every shell incl.
# scripts, so no prompts, no `eval` of init hooks, no output. PATH only.
# Everything interactive (prompt, aliases, fnm/zoxide init) stays in .zshrc.
#
# Safe to re-source; idempotent via zsh's `typeset -U path` dedupe.

typeset -U path
path=(
  "$HOME/.local/bin"
  "$HOME/.cargo/bin"
  "$HOME/.local/share/fnm"
  $path
)
export PATH
