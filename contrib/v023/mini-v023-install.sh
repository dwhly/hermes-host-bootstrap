#!/bin/bash
# Side-by-side Hermes v0.23 (stable) trial install on a Mac. Touches only ~/hermes-trial.
# Live install (~/.hermes, ~/.local/bin/hermes, launchd jobs, herdr ws) must stay byte-identical.
set -u
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
T="$HOME/hermes-trial"; H="$T/home"; D="$T/hermes-agent"
mkdir -p "$T/bin" "$H" "$T/evidence"
snap() {  # fingerprint everything the live install depends on
  {
    for f in "$HOME"/.local/bin/hermes* /usr/local/bin/hermes "$HOME"/.zshrc "$HOME"/.zprofile "$HOME"/.bashrc "$HOME"/.bash_profile "$HOME"/.profile "$HOME"/.hermes/config.yaml "$HOME"/.hermes/.env; do
      [ -e "$f" ] && echo "$(shasum -a 256 "$f" | cut -c1-16) $f"
    done
    ls "$HOME/Library/LaunchAgents" 2>/dev/null | grep -iE 'hermes|herdr' | sed 's/^/agent /'
    launchctl list 2>/dev/null | grep -iE 'hermes|herdr' | awk '{print "job", $3}'
    echo "live-version $(hermes --version 2>/dev/null | head -1)"
    echo "live-head $(git -C "$HOME/.hermes/hermes-agent" rev-parse HEAD 2>/dev/null)"
  } | sort
}
snap > "$T/evidence/before.txt"

# Minimal trial config: same model as live, never publish commands onto PATH.
if [ ! -f "$H/config.yaml" ]; then
  def=$(awk '/^model:/{m=1;next} m&&/^[^ ]/{m=0} m&&/default:/{print $2; exit}' "$HOME/.hermes/config.yaml")
  cat > "$H/config.yaml" <<EOF
model:
  default: ${def:-~anthropic/claude-opus-latest}
  provider: openrouter
  base_url: https://openrouter.ai/api/v1
cli:
  expose_on_path: false
EOF
fi
# Only the model key; no messaging tokens, so the trial gateway can't fight the live bots.
if [ ! -f "$H/.env" ]; then
  umask 077; grep -E '^OPENROUTER_API_KEY=' "$HOME/.hermes/.env" > "$H/.env"; umask 022
fi
echo "env keys copied: $(cut -d= -f1 "$H/.env" | tr '\n' ' ')"

curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o "$T/install.sh"
HERMES_HOME="$H" bash "$T/install.sh" --channel stable --dir "$D" --hermes-home "$H" \
  --skip-setup --skip-browser --non-interactive > "$T/evidence/install.log" 2>&1 < /dev/null
echo "installer exit=$?"

cat > "$T/bin/hermes23" <<EOF
#!/bin/bash
export HERMES_HOME="$H"
exec "$D/.hermes/bin/hermes" "\$@"
EOF
chmod +x "$T/bin/hermes23"
echo "trial-version $("$T/bin/hermes23" --version 2>&1 | head -1)"
echo "trial-tag $(git -C "$D" describe --tags 2>/dev/null)"

snap > "$T/evidence/after.txt"
if diff -u "$T/evidence/before.txt" "$T/evidence/after.txt" > "$T/evidence/live-diff.txt"; then
  echo "LIVE UNTOUCHED"
else
  echo "LIVE CHANGED:"; cat "$T/evidence/live-diff.txt"
fi
echo DONE
