#!/usr/bin/env bash
# remote-hmw-target.sh — runs ON the target as root. Makes the host an `hmw <host>` target:
# installs the herdr release binary (same method as lib/42-herdr.sh) and links the reviewed
# workspace helpers from the pinned bootstrap baseline into ~/.local/bin.
set -euo pipefail
base=/opt/hermes-host-bootstrap-baseline
bin="$HOME/.local/bin"
mkdir -p "$bin"

if ! command -v herdr >/dev/null 2>&1 && [[ ! -x "$bin/herdr" ]]; then
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)  asset=herdr-linux-x86_64 ;;
    Linux-aarch64) asset=herdr-linux-aarch64 ;;
    *) echo "unsupported platform for herdr: $(uname -s)-$(uname -m)"; exit 1 ;;
  esac
  # Pin to the version proven on existing fleet targets (h-btp) unless overridden.
  ver="${HERDR_VERSION:-v0.8.2}"
  tmp="$(mktemp)"
  curl -fsSL "https://github.com/ogulcancelik/herdr/releases/download/${ver}/${asset}" -o "$tmp" \
    || curl -fsSL "https://github.com/ogulcancelik/herdr/releases/download/${ver#v}/${asset}" -o "$tmp"
  install -m 0755 "$tmp" "$bin/herdr"; rm -f "$tmp"
fi
echo "herdr: $("$bin/herdr" --version 2>/dev/null | head -1 || herdr --version | head -1)"

for s in hermes-workspace hermes-pane hermes-host-resolve hermes-terminal-reset herdr-new-agent hermes-exit; do
  [[ -f "$base/scripts/$s" ]] || { echo "missing $base/scripts/$s"; exit 1; }
  chmod +x "$base/scripts/$s"
  ln -sfn "$base/scripts/$s" "$bin/$s"
done
chmod +x "$base/scripts/hmw-herdr.sh" && ln -sfn "$base/scripts/hmw-herdr.sh" "$bin/hmw-herdr"
command -v tmux >/dev/null || echo "note: tmux not installed (herdr backend does not need it)"
echo "hmw target helpers linked into $bin"
