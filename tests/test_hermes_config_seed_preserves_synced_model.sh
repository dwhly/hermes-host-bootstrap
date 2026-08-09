#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/.hermes" "$TMP/bin"

cat >"$TMP/home/.hermes/config.yaml" <<'YAML'
model:
  provider: openrouter
  default: openai/gpt-5.6-sol
  base_url: https://openrouter.ai/api/v1
  api_mode: chat_completions
YAML

cat >"$TMP/bin/hermes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$TMP/bin/op" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$TMP/bin/hermes" "$TMP/bin/op"

HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" REPO_ROOT="$ROOT" \
  TIER=recommended ROLE=client OS=macos ARCH=arm64 IS_HEADLESS=0 \
  HERMES_CONFIG_REPO= HERMES_MODEL_DEFAULT=openai/gpt-5.5 \
  HERMES_SKIP=op-resolve,gateway \
  bash "$ROOT/lib/92-hermes-config.sh" >/dev/null

actual="$(python3 - "$TMP/home/.hermes/config.yaml" <<'PY'
import sys, yaml
print(yaml.safe_load(open(sys.argv[1]))['model']['default'])
PY
)"
[[ "$actual" == openai/gpt-5.6-sol ]]
printf '%s\n' 'PASS: synced model.default survives bootstrap seeding'
