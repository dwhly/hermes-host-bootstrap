#!/usr/bin/env bash
# 05-ssh-access: opt-in SSH reachability helpers.
#
# This module is deliberately conservative: it does not open SSH or add keys
# unless the operator provides explicit env/config variables. It is useful for
# fleet bring-up where a relay host needs passwordless automation access after
# the human has run bootstrap locally once.
#
# Skip keys:
#   authorized-keys     skip ~/.ssh/authorized_keys management
#   mac-remote-login    skip macOS Remote Login enablement
#
# Env/config variables:
#   HERMES_AUTHORIZED_KEYS       newline-separated public keys to ensure
#   HERMES_AUTHORIZED_KEYS_FILE  file containing public keys to ensure
#   HERMES_MAC_REMOTE_LOGIN=1    macOS only: enable Remote Login for $USER

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "SSH access"

ensure_authorized_key() {
  local key="$1"
  [[ -n "$key" ]] || return 0
  [[ "$key" =~ ^[[:space:]]*# ]] && return 0
  # Accept common OpenSSH public key prefixes. Reject arbitrary text so a bad
  # config line does not poison authorized_keys.
  if [[ ! "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+ ]]; then
    warn "skipping invalid public key line: ${key:0:32}..."
    return 0
  fi

  local ssh_dir="$HOME/.ssh"
  local auth_file="$ssh_dir/authorized_keys"
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  touch "$auth_file"
  chmod 600 "$auth_file"
  ensure_line "$key" "$auth_file"
  chmod 600 "$auth_file"
}

if ! is_skipped authorized-keys; then
  added_any=0
  if [[ -n "${HERMES_AUTHORIZED_KEYS_FILE:-}" ]]; then
    if [[ -f "$HERMES_AUTHORIZED_KEYS_FILE" ]]; then
      info "ensuring authorized keys from $HERMES_AUTHORIZED_KEYS_FILE"
      while IFS= read -r key_line || [[ -n "$key_line" ]]; do
        ensure_authorized_key "$key_line"
        added_any=1
      done < "$HERMES_AUTHORIZED_KEYS_FILE"
    else
      warn "HERMES_AUTHORIZED_KEYS_FILE set but not found: $HERMES_AUTHORIZED_KEYS_FILE"
    fi
  fi

  if [[ -n "${HERMES_AUTHORIZED_KEYS:-}" ]]; then
    info "ensuring authorized keys from HERMES_AUTHORIZED_KEYS"
    while IFS= read -r key_line || [[ -n "$key_line" ]]; do
      ensure_authorized_key "$key_line"
      added_any=1
    done <<< "$HERMES_AUTHORIZED_KEYS"
  fi

  if [[ "$added_any" -eq 0 ]]; then
    skip "no HERMES_AUTHORIZED_KEYS(_FILE) configured"
  fi
else
  skip "authorized-keys — opted out via --skip"
fi

if [[ "$OS" == "macos" ]] && [[ "${HERMES_MAC_REMOTE_LOGIN:-0}" == "1" ]] && ! is_skipped mac-remote-login; then
  if sudo -n true 2>/dev/null; then
    info "enabling macOS Remote Login for SSH"
    sudo systemsetup -setremotelogin on >/dev/null 2>&1 || warn "systemsetup could not enable Remote Login"
    # Ensure the current user is allowed when macOS has a restricted access group.
    sudo dseditgroup -o edit -a "$USER" -t user com.apple.access_ssh >/dev/null 2>&1 || true
    ok "macOS Remote Login requested for $USER"
  else
    warn "macOS Remote Login requested but sudo needs a TTY/password; run locally or use hermes-reload --interactive-sudo"
  fi
elif [[ "$OS" == "macos" ]]; then
  skip "macOS Remote Login not changed (set HERMES_MAC_REMOTE_LOGIN=1 to opt in)"
fi

ok "SSH access pass complete"
