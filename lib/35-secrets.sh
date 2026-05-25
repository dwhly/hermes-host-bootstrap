#!/usr/bin/env bash
# 35-secrets: 1Password CLI (op) + secrets-management plumbing.
#
# Installs the 1Password CLI on Mac (brew cask) and Linux (apt repo) so
# that secrets in ~/.hermes/.env can be stored as op:// references in
# git-tracked .env.template files and resolved at runtime.
#
# Skip key: op. Lockout-safe (no destructive ops; install only).
#
# This module runs early in the chain (numeric 35) so later modules
# that depend on secrets (90-agents installing hermes, gateway config)
# can use `op inject` if they need to.

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "1Password CLI (op) — secrets management"

if is_skipped op; then
  skip "--skip=op passed"
  return 0 2>/dev/null || exit 0
fi

# Already installed?
if have op; then
  skip "1Password CLI already installed: $(op --version 2>/dev/null || echo unknown)"
else
  if [[ "$OS" == "macos" ]]; then
    if have brew; then
      info "installing 1Password CLI via Homebrew"
      brew install 1password-cli || warn "brew install 1password-cli failed"
    else
      warn "Homebrew missing — install op from https://developer.1password.com/docs/cli/get-started/"
    fi
  else
    # Linux: 1Password's apt repo
    case "$OS" in
      ubuntu|debian)
        require_sudo
        info "adding 1Password apt repository"
        # Add 1Password's signing key and apt source. This is the official
        # documented install path: https://developer.1password.com/docs/cli/get-started/#install
        if [[ ! -f /usr/share/keyrings/1password-archive-keyring.gpg ]]; then
          curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
            sudo gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg
        fi
        if [[ ! -f /etc/apt/sources.list.d/1password.list ]]; then
          echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/amd64 stable main' | \
            sudo tee /etc/apt/sources.list.d/1password.list > /dev/null
        fi
        # 1Password's debsig policy (verifies package integrity post-install)
        if [[ ! -d /etc/debsig/policies/AC2D62742012EA22 ]]; then
          sudo mkdir -p /etc/debsig/policies/AC2D62742012EA22/
          curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol | \
            sudo tee /etc/debsig/policies/AC2D62742012EA22/1password.pol > /dev/null
          sudo mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22
          curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
            sudo gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg
        fi
        apt_refresh
        apt_install 1password-cli
        ;;
      fedora|rhel|centos)
        warn "1Password CLI install on $OS not automated yet — see https://developer.1password.com/docs/cli/get-started/"
        ;;
      *)
        warn "1Password CLI: don't know how to install on OS=$OS"
        ;;
    esac
  fi
fi

# ── Hermes .env template processing ────────────────────────────────────
# If a ~/.hermes/.env.template exists (committed to the user's config repo
# with op:// references), resolve it into ~/.hermes/.env at every bootstrap
# run so the resolved values are current. Idempotent.
#
# Authentication preference:
#   1. OP_SERVICE_ACCOUNT_TOKEN (env or ~/.hermes-bootstrap.conf) — preferred
#      for headless Linux hosts. The token is itself a secret, but it's the
#      ONE secret that bootstraps all others.
#   2. Interactive `op signin` session — works on Mac (Touch ID) and any
#      host where a human can authenticate.
#
# If neither auth path is set up yet, we skip silently with a warn —
# users on a fresh box need to set up auth manually before the first
# template resolution can succeed.
ENV_TEMPLATE="${HERMES_HOME:-$HOME/.hermes}/.env.template"
ENV_RESOLVED="${HERMES_HOME:-$HOME/.hermes}/.env"

if have op && [[ -f "$ENV_TEMPLATE" ]] && ! is_skipped op-resolve; then
  if op account list >/dev/null 2>&1; then
    info "resolving $ENV_TEMPLATE → $ENV_RESOLVED via op inject"
    if op inject -i "$ENV_TEMPLATE" -o "$ENV_RESOLVED.tmp" 2>/dev/null; then
      chmod 600 "$ENV_RESOLVED.tmp"
      mv "$ENV_RESOLVED.tmp" "$ENV_RESOLVED"
      ok "resolved $(grep -c '^[^#]' "$ENV_RESOLVED" 2>/dev/null || echo 0) variables"
    else
      warn "op inject failed — check that referenced vault items exist and you're signed in"
      rm -f "$ENV_RESOLVED.tmp"
    fi
  else
    warn "$ENV_TEMPLATE found but no 1Password session active."
    warn "  Interactive (Mac):     op signin"
    warn "  Headless (Linux):      export OP_SERVICE_ACCOUNT_TOKEN=ops_... in ~/.hermes-bootstrap.conf"
    warn "  Then re-run bootstrap to resolve secrets."
  fi
elif [[ -f "$ENV_TEMPLATE" ]] && ! have op; then
  warn "$ENV_TEMPLATE found but op is not installed — skipping resolution"
fi

ok "1Password CLI step complete"
