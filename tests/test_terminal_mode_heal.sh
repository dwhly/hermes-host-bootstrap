#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat >"$TMP/bin/clear" <<'EOF'
#!/usr/bin/env bash
printf 'clear-called\n' >>"$HEAL_LOG"
EOF
cat >"$TMP/bin/stty" <<'EOF'
#!/usr/bin/env bash
printf 'stty:%s\n' "$*" >>"$HEAL_LOG"
EOF
chmod +x "$TMP/bin/clear" "$TMP/bin/stty"

export HEAL_LOG="$TMP/calls.log"
: >"$HEAL_LOG"
PATH="$TMP/bin:/usr/bin:/bin" TERM=xterm-256color \
  "$ROOT/scripts/hermes-terminal-reset" --no-clear >"$TMP/reset.bytes"

grep -Fx 'stty:sane' "$HEAL_LOG"
if grep -q 'clear-called' "$HEAL_LOG"; then
  printf 'no-clear mode unexpectedly cleared the screen\n' >&2
  exit 1
fi
python3 - "$TMP/reset.bytes" <<'PY'
from pathlib import Path
import sys
b = Path(sys.argv[1]).read_bytes()
for seq in (b'\x1b[<u', b'\x1b[>4m', b'\x1b[?1006l'):
    assert seq in b, (seq, b)
PY

PATH="$TMP/bin:/usr/bin:/bin" TERM=xterm-256color \
  "$ROOT/scripts/hermes-terminal-reset" >"$TMP/reset-clear.bytes"
grep -Fx 'clear-called' "$HEAL_LOG"

heal_bytes="$(
  # shellcheck disable=SC1090
  source "$ROOT/dotfiles/mouse-heal.sh"
  __hermes_terminal_heal_bytes
)"
case "$heal_bytes" in
  *$'\033[<u'*$'\033[>4m'*) ;;
  *) printf 'prompt heal is missing extended-key reset bytes\n' >&2; exit 1 ;;
esac

printf '%s\n' 'PASS: terminal reset and prompt heal clear extended keyboard modes'