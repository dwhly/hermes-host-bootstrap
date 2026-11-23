#!/bin/bash
# Test lib/35-secrets.sh .env template resolution with a fake `op`.
set -u
W=/root/worktrees/env-overlay; T=$(mktemp -d); export PATH="$T/bin:$PATH"; mkdir -p "$T/bin" "$T/h"
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
run() { # $1 FAIL_ON
  ( have() { command -v "$1" >/dev/null; }; is_skipped() { return 1; }; info() { :; }; warn() { echo "WARN $*"; }; ok() { :; }
    ENV_HERMES="$T/h"; ENV_TEMPLATE="$T/h/.env.template"; ENV_RESOLVED="$T/h/.env"; ENV_TEMPLATE_HOST="$T/h/.env.template.h-test"
    FAIL_ON="$1"; export FAIL_ON; eval "$blk" ); }
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
chk "mode 600"                       '[ "$(stat -c %a $T/h/.env)" = 600 ]'
reset; before=$(sha256sum < "$T/h/.env"); out=$(run "h-test")
chk "overlay fail keeps .env"        '[ "$(sha256sum < $T/h/.env)" = "$before" ]'
chk "overlay fail warns"             'echo "$out" | grep -q "keeping existing"'
chk "no tmp files left"              '[ -z "$(ls -A $T/h | grep tmp)" ]'
reset; rm -f "$T/h/.env.template.h-test"; run ""
chk "no overlay: shared key used"    'grep -qx OPENROUTER_API_KEY=VAL_OpenRouter $T/h/.env && [ $(grep -c ^OPENROUTER_API_KEY= $T/h/.env) = 1 ]'
reset; out=$(run ".env.template"); chk "shared fail keeps .env" '[ "$(cat $T/h/.env)" = "$(printf "OPENROUTER_API_KEY=OLD_PER_HOST\nINLINE_ONLY=keepme")" ]'
rm -rf "$T"; exit $fail
