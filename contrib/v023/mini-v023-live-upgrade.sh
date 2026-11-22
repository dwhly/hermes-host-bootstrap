#!/bin/bash
# Upgrade THIS Mac's live Hermes to stable v0.23 with the official installer (guinea pig: h-mini).
# Backup already taken: ~/hermes-backups/pre-v023-home (+ state.db.pre-v023). Run detached; logs to ~/hermes-backups/upgrade.log
set -u
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
L="$HOME/hermes-backups"; mkdir -p "$L"
echo "== start $(date)"; echo "before: $(hermes --version | head -1)"
cp -p "$HOME/.local/bin/hermes" "$L/local-bin-hermes.pre-v023"
for f in .zshrc .zprofile .bashrc .profile; do [ -f "$HOME/$f" ] && cp -p "$HOME/$f" "$L/$f.pre-v023"; done
git -C "$HOME/.hermes/hermes-agent" diff > "$L/theme-local-patch.diff"
curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o "$L/install.sh"
bash "$L/install.sh" --channel stable --dir "$HOME/.hermes/hermes-agent" --hermes-home "$HOME/.hermes" \
  --skip-setup --skip-browser --non-interactive < /dev/null
echo "installer exit=$?"
hash -r
echo "after: $(hermes --version | head -1)"; echo "tag: $(git -C "$HOME/.hermes/hermes-agent" describe --tags)"
echo "launcher:"; ls -la "$HOME/.local/bin/hermes"; head -3 "$HOME/.local/bin/hermes"
for f in .zshrc .zprofile .bashrc .profile; do [ -f "$HOME/$f" ] && ! cmp -s "$HOME/$f" "$L/$f.pre-v023" && { echo "changed: $f"; diff "$L/$f.pre-v023" "$HOME/$f"; }; done
echo "== end $(date)"
