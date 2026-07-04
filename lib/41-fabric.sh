#!/usr/bin/env bash
# 41-fabric: Fabric — Daniel Miessler's AI CLI (patterns/prompts over any LLM).
# Cross-platform Go binary; installed via the official release-binary installer
# (no Go toolchain needed). https://github.com/danielmiessler/fabric
#
# Fleet model: this module is how a NEW package joins the fleet AND how its
# per-host config is kept current. Every host picks up the binary + a rendered
# ~/.config/fabric/.env on its next bootstrap (or `bootstrap --only 41-fabric`),
# so config is CONSTRUCTED on bootstrap and REFRESHED on every run — no manual
# `fabric --setup` per host. The console's provisioning checks surface which
# hosts have it. See docs: the package-deploy flow + fleet-management playbook.
#
# Config layering (why we render an .env instead of `fabric --setup`):
#   • The API key is a SECRET → it comes from the fleet secrets path
#     (1Password → ~/.hermes/.env via lib/35-secrets.sh, which runs BEFORE this
#     module). We read OPENROUTER_API_KEY from the already-resolved ~/.hermes/.env
#     and never hardcode it. Fabric has a NATIVE OpenRouter vendor, so no
#     OpenAI-compat base-URL hackery is needed (fabric's OpenAI vendor ignores
#     OPENAI_BASE_URL and always hits api.openai.com — verified 2026-07-03).
#   • The non-secret defaults (vendor/model/patterns repo) are rendered here.
# Single-provider by design: the whole fleet routes through OpenRouter, so fabric
# reuses OPENROUTER_API_KEY rather than needing a new key.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Fabric (AI CLI)"

# Recommended tier (R): a useful AI tool, not essential to a base node.
if ! tier_allows R; then
  skip "fabric skipped (tier below R)"
  return 0 2>/dev/null || exit 0
fi

if is_skipped fabric; then
  skip "fabric skipped (HERMES_SKIP includes fabric)"
  return 0 2>/dev/null || exit 0
fi

install_dir="$HOME/.local/bin"
mkdir -p "$install_dir"

# ── 1. Install the binary if missing (idempotent) ──────────────────────
if have fabric || [[ -x "$install_dir/fabric" ]]; then
  skip "fabric already installed: $("$install_dir/fabric" --version 2>/dev/null | head -1 || fabric --version 2>/dev/null | head -1 || echo present)"
else
  info "installing fabric via official release-binary installer → $install_dir"
  if curl -fsSL https://raw.githubusercontent.com/danielmiessler/fabric/main/scripts/installer/install.sh \
       | INSTALL_DIR="$install_dir" bash; then
    if have fabric || [[ -x "$install_dir/fabric" ]]; then
      ok "fabric installed: $("$install_dir/fabric" --version 2>/dev/null | head -1 || echo ok)"
    else
      warn "fabric installer ran but the binary isn't on PATH — check $install_dir and your PATH"
    fi
  else
    warn "fabric install failed — install manually: https://github.com/danielmiessler/fabric (release installer or 'go install …/cmd/fabric@latest')"
    return 0 2>/dev/null || exit 0
  fi
fi

fabric_bin="$install_dir/fabric"
have fabric && fabric_bin="fabric"

# ── 2. Render ~/.config/fabric/.env from the resolved fleet key (every run) ──
# Sourced from ~/.hermes/.env (populated by lib/35-secrets.sh before this module).
FABRIC_MODEL="${FABRIC_DEFAULT_MODEL:-anthropic/claude-sonnet-4.5}"
HERMES_ENV="${HERMES_HOME:-$HOME/.hermes}/.env"
FABRIC_CFG_DIR="$HOME/.config/fabric"
FABRIC_ENV="$FABRIC_CFG_DIR/.env"

or_key=""
if [[ -f "$HERMES_ENV" ]]; then
  # Extract OPENROUTER_API_KEY value; strip quotes/CR. Never echoed.
  or_key="$(grep -E '^OPENROUTER_API_KEY=' "$HERMES_ENV" | head -1 | cut -d= -f2- | tr -d '\r\n' | sed -E 's/^["'\'']//; s/["'\'']$//')"
fi

if [[ -z "$or_key" ]]; then
  warn "OPENROUTER_API_KEY not found in $HERMES_ENV — fabric config NOT rendered."
  warn "  Resolve fleet secrets first (op inject via lib/35-secrets), then re-run --only=41-fabric."
else
  mkdir -p "$FABRIC_CFG_DIR"
  umask 077
  {
    echo "# Fabric config — RENDERED BY bootstrap lib/41-fabric.sh (do not hand-edit)."
    echo "# Key sourced from ~/.hermes/.env (1Password-resolved). Native OpenRouter vendor."
    echo "OPENROUTER_API_KEY=$or_key"
    echo "DEFAULT_VENDOR=OpenRouter"
    echo "DEFAULT_MODEL=$FABRIC_MODEL"
    echo "PATTERNS_LOADER_GIT_REPO_URL=https://github.com/danielmiessler/fabric.git"
    echo "PATTERNS_LOADER_GIT_REPO_PATTERNS_FOLDER=data/patterns"
  } > "$FABRIC_ENV"
  chmod 600 "$FABRIC_ENV"
  ok "rendered $FABRIC_ENV (vendor=OpenRouter model=$FABRIC_MODEL)"

  # ── 3. Download patterns if absent (idempotent; needs the key above) ──
  if [[ ! -d "$FABRIC_CFG_DIR/patterns" ]] || [[ -z "$(ls -A "$FABRIC_CFG_DIR/patterns" 2>/dev/null)" ]]; then
    info "downloading fabric patterns (first run)"
    if "$fabric_bin" -U >/dev/null 2>&1; then
      ok "fabric patterns installed: $(ls "$FABRIC_CFG_DIR/patterns" 2>/dev/null | wc -l | tr -d ' ') patterns"
    else
      warn "fabric pattern download failed — run '$fabric_bin -U' manually"
    fi
  else
    skip "fabric patterns already present: $(ls "$FABRIC_CFG_DIR/patterns" 2>/dev/null | wc -l | tr -d ' ')"
  fi
fi
