#!/usr/bin/env bash
# 41-fabric: Fabric — Daniel Miessler's AI CLI (patterns/prompts over any LLM).
# Cross-platform Go binary; installed via the official release-binary installer
# (no Go toolchain needed). https://github.com/danielmiessler/fabric
#
# Fleet model: this module is how a NEW package joins the fleet. Adding it here +
# a verify_check in verify.sh means every host picks it up on its next bootstrap
# (or a targeted `bootstrap --only 41-fabric`), and the console's provisioning
# checks surface which hosts have it. See docs: the package-deploy flow.

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

if have fabric; then
  skip "fabric already installed: $(fabric --version 2>/dev/null | head -1 || echo present)"
  return 0 2>/dev/null || exit 0
fi

# Install location: a user-writable bin already on PATH (no sudo needed). The
# release installer honors INSTALL_DIR. ~/.local/bin is set up earlier in
# bootstrap and is on PATH for both Linux and macOS fleet users.
install_dir="$HOME/.local/bin"
mkdir -p "$install_dir"

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
fi

# NOTE: fabric needs per-user config (API keys, default model) via `fabric --setup`.
# That's a SECRETS/identity step, not a fleet-package step — intentionally NOT done
# here. Wire fabric's model/keys through the same path as other fleet secrets if you
# want it preconfigured (1Password → .env), or run `fabric --setup` once per host.
