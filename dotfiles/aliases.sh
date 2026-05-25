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
alias r='hermes-reload'
# ── END core ──

# ── BEGIN hermes ──
alias hm='hermes'
# ── END hermes ──

# ── BEGIN git ──
# (empty — add git-related aliases here via the add-shell-alias skill)
# ── END git ──

# ── BEGIN tmux ──
# (empty — add tmux-related aliases here via the add-shell-alias skill)
# ── END tmux ──

# ── BEGIN misc ──
# (empty — catch-all for aliases that don't fit other sections)
# ── END misc ──
