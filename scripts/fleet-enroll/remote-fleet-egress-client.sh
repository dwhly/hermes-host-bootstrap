#!/usr/bin/env bash
# remote-fleet-egress-client.sh — runs ON the target as root. Installs the fleet-egress client commands
# (fleet-yt-transcript, fleet-egress) and the youtube-transcripts skill for each named local account on a
# baseline-enrolled host, where lib/72-fleet-egress.sh never runs.
#
#   remote-fleet-egress-client.sh <payload.tgz> <user>...
#
# The payload (built on the boss from committed bootstrap + hermes-config sources) is unpacked into a
# root-owned /opt/fleet-egress-client; each account gets ~/.local/bin symlinks into it and a copy of the
# skill in its EXISTING ~/.hermes/skills (a Hermes home is never created). Additive and idempotent; never
# touches services, cron jobs or other skills. Writes into non-root homes run AS that account (runuser).
set -euo pipefail
payload="${1:?usage: remote-fleet-egress-client.sh <payload.tgz> <user>...}"; shift
(( $# > 0 )) || { echo "usage: remote-fleet-egress-client.sh <payload.tgz> <user>..."; exit 2; }
[[ -f "$payload" ]] || { echo "missing payload $payload"; exit 1; }
dest=/opt/fleet-egress-client
rm -rf "$dest.new"; install -d -m 0755 "$dest.new"
tar -xzf "$payload" -C "$dest.new" --no-same-owner
# Explicit modes (never inherit the builder's umask): dirs + commands 0755, everything else 0644.
chown -R 0:0 "$dest.new"
find "$dest.new" -type d -exec chmod 0755 {} +
find "$dest.new" -type f -exec chmod 0644 {} +
chmod 0755 "$dest.new"/bin/*
rm -rf "$dest.old"; [[ ! -d "$dest" ]] || mv "$dest" "$dest.old"; mv "$dest.new" "$dest"; rm -rf "$dest.old"
echo "payload: $(cat "$dest/PROVENANCE" 2>/dev/null | tr '\n' ' ')"
rc_status=0

as_user() {
  local user="$1" uid="$2"; shift 2
  if [[ "$uid" == 0 ]]; then "$@"; else runuser -u "$user" -- "$@"; fi
}

for user in "$@"; do
  if [[ ! "$user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then echo "$user: invalid account name; skipped"; rc_status=1; continue; fi
  if ! entry="$(getent passwd "$user")"; then echo "$user: no such account; skipped (accounts are never created)"; rc_status=1; continue; fi
  uid="$(printf '%s' "$entry" | cut -d: -f3)"
  home="$(printf '%s' "$entry" | cut -d: -f6)"
  if [[ -z "$home" || "$home" == / || ! -d "$home" || -L "$home" || "$(stat -c %u "$home")" != "$uid" ]]; then
    echo "$user: home '$home' unusable (missing, /, symlink, or not owned); skipped"; rc_status=1; continue
  fi
  as_user "$user" "$uid" mkdir -p "$home/.local/bin"
  for c in fleet-yt-transcript fleet-egress; do
    as_user "$user" "$uid" ln -sfn "$dest/bin/$c" "$home/.local/bin/$c"
  done
  skill="no ~/.hermes (skill not installed)"
  if [[ -d "$home/.hermes" && ! -L "$home/.hermes" ]]; then
    as_user "$user" "$uid" mkdir -p "$home/.hermes/skills/media/youtube-transcripts"
    as_user "$user" "$uid" install -m 0644 /dev/stdin "$home/.hermes/skills/media/youtube-transcripts/SKILL.md" \
      <"$dest/skill/SKILL.md"
    skill="skill media/youtube-transcripts installed"
  fi
  echo "$user: fleet-yt-transcript + fleet-egress linked; $skill"
done
exit "$rc_status"
