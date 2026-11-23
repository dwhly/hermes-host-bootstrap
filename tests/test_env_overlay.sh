#!/bin/bash
# Test lib/35-secrets.sh .env template resolution with a fake `op`.
set -u
W=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); export PATH="$T/bin:$PATH"; mkdir -p "$T/bin" "$T/h"
cat > "$T/bin/op" <<'EOF'
#!/bin/bash
# fake op: `op account list` ok; `op inject --force -i IN -o OUT` replaces op://x/NAME/credential with VAL_NAME; fails if FAIL_ON matches IN
[ "$1" = account ] && exit 0
while [ $# -gt 0 ]; do case "$1" in -i) IN=$2; shift;; -o) OUT=$2; shift;; esac; shift; done
[ -n "${FAIL_ON:-}" ] && [[ "$IN" == *"$FAIL_ON"* ]] && exit 1
sed -E 's#op://[^/]+/([^/]+)/credential#VAL_\1#' "$IN" > "$OUT"
EOF
chmod +x "$T/bin/op"
blk=$(awk '/^if have op && \[\[ -f "\$ENV_TEMPLATE" \]\]/{p=1} p{print} p&&/^fi$/{exit}' "$W/lib/35-secrets.sh")
printf '%s\n' "$blk" > "$T/blk.sh"
run() { # $1 FAIL_ON. Fresh strict-mode bash, like production (lib runs under set -euo pipefail).
  FAIL_ON="$1" T="$T" PATH="$PATH" bash -c 'set -euo pipefail; umask 022
    have() { command -v "$1" >/dev/null; }; is_skipped() { return 1; }; info() { :; }; warn() { echo "WARN $*"; }; ok() { :; }
    ENV_HERMES="$T/h"; ENV_TEMPLATE="$T/h/.env.template"; ENV_RESOLVED="$T/h/.env"; ENV_TEMPLATE_HOST="$T/h/.env.template.h-test"
    export FAIL_ON; . "$T/blk.sh"'; }
reset() { printf 'OPENROUTER_API_KEY=op://hermes/OpenRouter/credential\nFOO=op://hermes/Foo/credential\n' > "$T/h/.env.template"
  printf 'TELEGRAM_BOT_TOKEN=op://hermes/Tg/credential\nOPENROUTER_API_KEY=op://hermes/OpenRouter-h-test/credential\n' > "$T/h/.env.template.h-test"
  printf 'OPENROUTER_API_KEY=OLD_PER_HOST\nINLINE_ONLY=keepme\n' > "$T/h/.env"; }
fail=0; chk() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
reset; run ""
chk "one OPENROUTER line"            '[ $(grep -c ^OPENROUTER_API_KEY= $T/h/.env) = 1 ]'
chk "overlay value wins"             'grep -qx OPENROUTER_API_KEY=VAL_OpenRouter-h-test $T/h/.env'
chk "first match is overlay value"   '[ "$(grep -m1 ^OPENROUTER_API_KEY= $T/h/.env)" = OPENROUTER_API_KEY=VAL_OpenRouter-h-test ]'
chk "shared non-overridden kept"     'grep -qx FOO=VAL_Foo $T/h/.env'
chk "overlay-only key added"         'grep -qx TELEGRAM_BOT_TOKEN=VAL_Tg $T/h/.env'
chk "inline value preserved"         'grep -qx INLINE_ONLY=keepme $T/h/.env'
chk "mode 600"                       '[ "$(stat -c %a $T/h/.env 2>/dev/null || stat -f %Lp $T/h/.env)" = 600 ]'
reset; cp "$T/h/.env" "$T/before"; out=$(run "h-test" || true)
chk "overlay fail keeps .env"        'cmp -s $T/h/.env $T/before'
chk "overlay fail warns"             'echo "$out" | grep -q "keeping existing"'
chk "no tmp files left"              '! ls -A $T/h | grep -q tmp'
reset; printf '# comments only\n' > "$T/h/.env.template.h-test"; rc=0; run "" || rc=$?
chk "empty overlay: exits 0"          '[ $rc = 0 ]'
chk "empty overlay: shared used"      'grep -qx OPENROUTER_API_KEY=VAL_OpenRouter $T/h/.env'
# fake mv records each source file's mode before moving it, so a world-readable temp file is caught while it exists
mkdir -p "$T/mvbin"; printf '#!/bin/bash\nsrc="${@: -2:1}"; [ -f "$src" ] && { stat -c %%a "$src" 2>/dev/null || stat -f %%Lp "$src"; } >> "%s/modes"\nexec /bin/mv "$@"\n' "$T" > "$T/mvbin/mv"; chmod +x "$T/mvbin/mv"
reset; : > "$T/modes"; PATH="$T/mvbin:$PATH" run "" >/dev/null
chk "temp files never world-readable" '[ -s $T/modes ] && ! grep -qvE "^[0-7]?[0-7]00$" $T/modes'
reset; rm -f "$T/h/.env.template.h-test"; run ""
chk "no overlay: shared key used"    'grep -qx OPENROUTER_API_KEY=VAL_OpenRouter $T/h/.env && [ $(grep -c ^OPENROUTER_API_KEY= $T/h/.env) = 1 ]'
reset; out=$(run ".env.template" || true); chk "shared fail keeps .env" '[ "$(cat $T/h/.env)" = "$(printf "OPENROUTER_API_KEY=OLD_PER_HOST\nINLINE_ONLY=keepme")" ]'
rm -rf "$T"; exit $fail
