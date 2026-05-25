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

# Aliases — modern unix replacements
command -v eza   >/dev/null 2>&1 && alias ls='eza --group-directories-first'
command -v eza   >/dev/null 2>&1 && alias ll='eza -lah --group-directories-first --git'
command -v bat   >/dev/null 2>&1 && alias cat='bat --paging=never'
command -v rg    >/dev/null 2>&1 && alias grep='rg'

# Editor
export EDITOR="${EDITOR:-nvim}"
export VISUAL="$EDITOR"

# Strip `# trailing comments` like bash does. Without this, a pasted
# command like `ssh host  # connect` makes zsh treat `#` as a literal
# argument, which can produce confusing errors (e.g. "Could not resolve
# hostname #"). interactive_comments aligns zsh with bash here.
setopt interactive_comments
