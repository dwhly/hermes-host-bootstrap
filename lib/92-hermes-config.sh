#!/usr/bin/env bash
# 92-hermes-config: apply the personal ~/.hermes config layer and resolve secrets.
#
# Runs after 90-agents so the hermes binary exists, and after 35-secrets so op
# is installed. If HERMES_CONFIG_REPO is set in ~/.hermes-bootstrap.conf (or the
# environment), this module clones/pulls the private config repo into ~/.hermes,
# resolves ~/.hermes/.env.template via 1Password, runs Hermes config migration,
# and optionally installs/restarts the gateway.
#
# If HERMES_CONFIG_REPO is not set (or clone/auth fails), this module still
# writes a minimal non-interactive OpenRouter config from HERMES_MODEL_* env
# defaults so users do not have to enter the curses `hermes setup` provider
# picker just to get past first boot.
#
# Skip keys:
#   hermes-config       skip this whole module
#   hermes-config-pull  skip pull when ~/.hermes is already git-tracked
#   op-resolve          skip .env.template -> .env resolution
#   hermes-model-config skip non-interactive model/provider config seeding
#   hermes-migrate      skip hermes config migrate/check
#   gateway             skip gateway install/restart actions

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Hermes personal config layer"

if is_skipped hermes-config; then
  skip "hermes-config — opted out via --skip"
  return 0 2>/dev/null || exit 0
fi

HERMES_HOME_DIR="${HERMES_HOME:-$HOME/.hermes}"
CONFIG_REPO="${HERMES_CONFIG_REPO:-}"

# shellcheck disable=SC2016
print_auth_hint() {
  warn "private config clone may require GitHub auth first:"
  warn "  HTTPS: gh auth login && gh auth setup-git"
  warn "  SSH:   ensure this host's SSH key is allowed on GitHub"
}

restore_runtime_from_backup() {
  backup="$1"
  target="$2"
  info "restoring runtime-only files from $backup"
  for item in auth.json state.db state.db-wal state.db-shm kanban.db kanban.db-wal kanban.db-shm \
              logs sessions cache image_cache audio_cache pastes lsp \
              hermes-agent .hermes_history channel_directory.json gateway_state.json cron/jobs.json; do
    if [[ -e "$backup/$item" && ! -e "$target/$item" ]]; then
      parent="$(dirname "$target/$item")"
      mkdir -p "$parent"
      cp -R "$backup/$item" "$target/$item"
      info "  restored: $item"
    fi
  done
}

bootstrap_config_repo() {
  if [[ -z "$CONFIG_REPO" ]]; then
    skip "HERMES_CONFIG_REPO not set — leaving ~/.hermes as local-only config"
    return 0
  fi

  if ! have git; then
    warn "git not installed — cannot clone HERMES_CONFIG_REPO"
    return 1
  fi

  if [[ -d "$HERMES_HOME_DIR/.git" ]]; then
    ok "$HERMES_HOME_DIR is already git-tracked"
    cd "$HERMES_HOME_DIR"
    if ! is_skipped hermes-config-pull; then
      info "fetching personal config repo"
      git fetch origin --prune || {
        warn "git fetch failed — keeping existing config"
        print_auth_hint
        return 0
      }
      current_branch="$(git branch --show-current 2>/dev/null || echo main)"
      if git rev-parse --verify "origin/$current_branch" >/dev/null 2>&1; then
        if git merge-base --is-ancestor HEAD "origin/$current_branch" 2>/dev/null; then
          git merge --ff-only "origin/$current_branch" || warn "fast-forward merge failed — local config may have drift"
        else
          warn "local config has commits not on origin/$current_branch — not auto-merging"
        fi
      fi
    fi
    return 0
  fi

  info "cloning personal config: $CONFIG_REPO → $HERMES_HOME_DIR"

  backup=""
  if [[ -d "$HERMES_HOME_DIR" ]]; then
    # If a previous failed bootstrap already saved a real Hermes dir, reuse it
    # rather than backing up an empty retry directory and restoring from that.
    for candidate in "$HERMES_HOME_DIR".pre-config-sync-*.bak; do
      [[ -d "$candidate" ]] || continue
      if [[ -e "$candidate/state.db" || -e "$candidate/hermes-agent" ]]; then
        backup="$candidate"
      fi
    done

    if [[ -z "$backup" ]]; then
      backup="${HERMES_HOME_DIR}.pre-config-sync-$(date +%Y%m%d-%H%M%S).bak"
      info "backing up existing $HERMES_HOME_DIR → $backup"
      mv "$HERMES_HOME_DIR" "$backup"
    else
      info "using existing real backup: $backup"
      rm -rf "$HERMES_HOME_DIR"
    fi
  fi

  mkdir -p "$(dirname "$HERMES_HOME_DIR")"
  if ! git clone "$CONFIG_REPO" "$HERMES_HOME_DIR"; then
    warn "config clone failed"
    print_auth_hint
    if [[ -n "$backup" && ! -d "$HERMES_HOME_DIR" ]]; then
      info "restoring original $HERMES_HOME_DIR from $backup"
      mv "$backup" "$HERMES_HOME_DIR"
    fi
    return 1
  fi

  if [[ -n "$backup" ]]; then
    restore_runtime_from_backup "$backup" "$HERMES_HOME_DIR"
    info "backup retained at $backup (safe to delete after verifying)"
  fi

  ok "personal config repo cloned"
}

resolve_env_template() {
  env_template="$HERMES_HOME_DIR/.env.template"
  env_resolved="$HERMES_HOME_DIR/.env"
  env_template_host="$HERMES_HOME_DIR/.env.template.$(hostname -s 2>/dev/null || hostname)"

  [[ -f "$env_template" ]] || return 0

  if is_skipped op-resolve; then
    skip "op-resolve — opted out via --skip"
    return 0
  fi

  if ! have op; then
    warn "$env_template exists but op is not installed — cannot resolve secrets"
    return 0
  fi

  if ! op account list >/dev/null 2>&1; then
    warn "$env_template found but no 1Password session/service token is active"
    warn "  Mac: enable 1Password desktop CLI integration, then run op signin once"
    warn "  Linux: set OP_SERVICE_ACCOUNT_TOKEN in ~/.hermes-bootstrap.conf"
    return 0
  fi

  info "resolving $env_template → $env_resolved via op inject"
  if op inject --force -i "$env_template" -o "$env_resolved.tmp" 2>/dev/null; then
    if [[ -f "$env_template_host" ]]; then
      info "applying per-host overlay: $env_template_host"
      if op inject --force -i "$env_template_host" -o "$env_resolved.host.tmp" 2>/dev/null; then
        {
          echo ""
          echo "# ── per-host overlay ($(basename "$env_template_host")) ──"
          grep -E '^[A-Z_][A-Z0-9_]*=' "$env_resolved.host.tmp" || true
        } >> "$env_resolved.tmp"
        rm -f "$env_resolved.host.tmp"
      else
        warn "op inject failed on $env_template_host — overlay skipped"
        rm -f "$env_resolved.host.tmp"
      fi
    fi

    if [[ -f "$env_resolved" ]]; then
      template_keys="$(grep -E '^[A-Z_][A-Z0-9_]*=' "$env_resolved.tmp" | cut -d= -f1 | sort -u || true)"
      {
        echo ""
        echo "# ── inline values (preserved from existing .env; not in template) ──"
        while IFS= read -r line; do
          [[ "$line" =~ ^[A-Z_][A-Z0-9_]*= ]] || continue
          key="${line%%=*}"
          if ! printf '%s\n' "$template_keys" | grep -qx "$key"; then
            echo "$line"
          fi
        done < "$env_resolved"
      } >> "$env_resolved.tmp"
    fi
    chmod 600 "$env_resolved.tmp"
    mv "$env_resolved.tmp" "$env_resolved"
    resolved_count="$(grep -cE '^[A-Z_][A-Z0-9_]*=' "$env_resolved" 2>/dev/null || echo 0)"
    ok "resolved + merged: $resolved_count variables total in .env"
  else
    warn "op inject failed — check vault/item refs in .env.template"
    rm -f "$env_resolved.tmp"
  fi
}

seed_model_config() {
  if is_skipped hermes-model-config; then
    skip "hermes-model-config — opted out via --skip"
    return 0
  fi

  mkdir -p "$HERMES_HOME_DIR"

  provider="${HERMES_MODEL_PROVIDER:-openrouter}"
  model="${HERMES_MODEL_DEFAULT:-${HERMES_DEFAULT_MODEL:-openai/gpt-5.5}}"
  base_url="${HERMES_MODEL_BASE_URL:-https://openrouter.ai/api/v1}"
  api_mode="${HERMES_MODEL_API_MODE:-chat_completions}"

  # Keep this deliberately small and non-interactive. The synced config repo
  # can still override with richer routing, but a fresh host gets a valid
  # provider/model immediately and never needs the curses setup picker.
  python3 - "$HERMES_HOME_DIR/config.yaml" "$provider" "$model" "$base_url" "$api_mode" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
provider, model, base_url, api_mode = sys.argv[2:6]
try:
    import yaml
except Exception as exc:
    raise SystemExit(f"PyYAML required to seed Hermes config: {exc}")

if path.exists():
    data = yaml.safe_load(path.read_text()) or {}
    if not isinstance(data, dict):
        data = {}
else:
    data = {}

model_cfg = data.get("model")
if isinstance(model_cfg, str):
    model_cfg = {"default": model_cfg}
elif not isinstance(model_cfg, dict):
    model_cfg = {}

model_cfg["provider"] = provider
model_cfg["default"] = model
model_cfg["base_url"] = base_url
model_cfg["api_mode"] = api_mode
data["model"] = model_cfg

# Safer TUI default: avoid DECSET 1003 any-motion/hover mouse tracking.
# The TUI still supports scroll/click with "wheel", and users can opt back
# into full hover tracking via /mouse all.
display_cfg = data.get("display")
if not isinstance(display_cfg, dict):
    display_cfg = {}
display_cfg.setdefault("mouse_tracking", "wheel")
data["display"] = display_cfg

path.write_text(yaml.safe_dump(data, sort_keys=False))
PY
  ok "Hermes model config seeded: $provider / $model"
}

migrate_and_check() {
  if is_skipped hermes-migrate; then
    skip "hermes-migrate — opted out via --skip"
    return 0
  fi

  if ! have hermes; then
    warn "hermes not on PATH — cannot run config migrate/check"
    return 0
  fi

  if [[ -f "$HERMES_HOME_DIR/config.yaml" ]]; then
    info "running hermes config migrate"
    hermes config migrate || warn "hermes config migrate failed"
    info "running hermes config check"
    hermes config check || warn "hermes config check reported issues"
  fi
}

setup_gateway_if_requested() {
  if is_skipped gateway; then
    skip "gateway — opted out via --skip"
    return 0
  fi

  if ! have hermes; then
    return 0
  fi

  if [[ "${HERMES_GATEWAY_INSTALL:-0}" == "1" ]]; then
    info "installing Hermes gateway service"
    hermes gateway install || warn "hermes gateway install failed"
  fi

  if [[ "${HERMES_GATEWAY_START:-0}" == "1" ]]; then
    info "starting/restarting Hermes gateway"
    if hermes gateway status >/dev/null 2>&1; then
      hermes gateway restart || hermes gateway start || warn "gateway restart/start failed"
    else
      hermes gateway start || warn "gateway start failed"
    fi
  fi
}

bootstrap_config_repo || true
resolve_env_template
seed_model_config
migrate_and_check
setup_gateway_if_requested

ok "Hermes personal config layer complete"
