#!/usr/bin/env bash
# remote-cli-tools.sh — runs ON a Linux target as root. Installs the 1Password CLI (op) and the
# GitHub CLI (gh) from their official apt repositories (same sources as lib/35-secrets.sh).
# Package install only: no credentials, no .env rendering, no config changes.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
changed=0
if ! command -v op >/dev/null 2>&1; then
  install -d -m 0755 /usr/share/keyrings /etc/debsig/policies/AC2D62742012EA22 /usr/share/debsig/keyrings/AC2D62742012EA22
  curl -fsS https://downloads.1password.com/linux/keys/1password.asc | gpg --dearmor --yes --output /usr/share/keyrings/1password-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" >/etc/apt/sources.list.d/1password.list
  curl -fsS https://downloads.1password.com/linux/debian/debsig/1password.pol >/etc/debsig/policies/AC2D62742012EA22/1password.pol
  curl -fsS https://downloads.1password.com/linux/keys/1password.asc | gpg --dearmor --yes --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg
  changed=1
fi
if ! command -v gh >/dev/null 2>&1; then
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" >/etc/apt/sources.list.d/github-cli.list
  changed=1
fi
if (( changed )); then
  apt-get update -qq >/dev/null
  apt-get install -y -qq 1password-cli gh >/dev/null
fi
echo "op $(op --version)"
echo "$(gh --version | head -1)"
