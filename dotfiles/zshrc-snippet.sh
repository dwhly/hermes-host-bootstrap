# ── hermes-host-bootstrap zshrc snippet ──
# Sourced from your main .zshrc. Safe to re-source; everything is idempotent.

# History — match what we tell bash to do
export HISTSIZE=50000
export SAVEHIST=50000
export HISTFILE="${HISTFILE:-$HOME/.zsh_history}"
setopt APPEND_HISTORY
setopt INC_APPEND_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_ALL_DUPS
setopt HIST_FIND_NO_DUPS
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY
setopt SHARE_HISTORY

# Path — pick up tools installed by the bootstrap
typeset -U path
path=(
  "$HOME/.local/bin"
  "$HOME/.cargo/bin"
  "$HOME/.local/share/fnm"
  $path
)
export PATH

# fnm (Fast Node Manager)
if command -v fnm >/dev/null 2>&1; then
  eval "$(fnm env --use-on-cd)"
fi

# zoxide — better cd
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh)"
fi

# fzf keybindings + completion (Ubuntu/Debian fzf-shell location)
[[ -f /usr/share/doc/fzf/examples/key-bindings.zsh ]] && \
  source /usr/share/doc/fzf/examples/key-bindings.zsh
[[ -f /usr/share/doc/fzf/examples/completion.zsh ]] && \
  source /usr/share/doc/fzf/examples/completion.zsh

# Aliases — modern unix tools. Convention: use NEW names rather than
# shadowing system commands. Shadowing `grep` with `rg`, `cat` with `bat`,
# or `ls` with `eza` breaks any script or muscle-memory pipeline that
# depends on the system tool's exact behavior (e.g. `grep -E`'s regex
# flavor differs from rg's). Bound enough times in practice that we
# now keep the originals and let users opt into the modern variant.
command -v eza   >/dev/null 2>&1 && alias ll='eza -lah --group-directories-first --git'
command -v eza   >/dev/null 2>&1 && alias lt='eza -lah --group-directories-first --git --tree --level=2'
# Note: NOT aliasing `ls`, `cat`, or `grep` — see comment above.
# To use the modern tool, invoke directly: rg, bat, eza.

# Editor
export EDITOR="${EDITOR:-nvim}"
export VISUAL="$EDITOR"

# Strip `# trailing comments` like bash does. Without this, a pasted
# command like `ssh host  # connect` makes zsh treat `#` as a literal
# argument, which can produce confusing errors (e.g. "Could not resolve
# hostname #"). interactive_comments aligns zsh with bash here.
setopt interactive_comments

# Prompt — show user@host + current path so cwd is always visible.
# Override whatever theme oh-my-zsh loaded (robbyrussell shows path only,
# but we want host first so it's obvious WHICH machine you're on across
# the fleet). Format: "user@host ~/path %" with the % red when last
# command failed (zsh's %(?.green.red) ternary).
#   %n = username
#   %m = short hostname
#   %~ = cwd with $HOME → ~ substitution
#   %(?.OK.FAIL) = ternary on last exit code
#   %F{color}…%f = foreground color
# Tweak via local override after sourcing this snippet if you prefer
# a two-line layout or different colors.
PROMPT='%F{cyan}%n@%m%f %F{yellow}%~%f %(?.%F{green}.%F{red})%#%f '
