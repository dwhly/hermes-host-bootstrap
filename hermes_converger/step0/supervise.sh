#!/bin/sh
set -eu
BASE=/opt/chief/lib/hermes-host-bootstrap/hermes_converger/step0
# shellcheck source=hermes_converger/step0/trust.sh
. "$BASE/trust.sh"
STATE=/var/lib/chief/currency-step0
trusted_path "$STATE"
now=$(/bin/date +%s)
last=0
if [ -f "$STATE/last-health" ]; then
    trusted_path "$STATE/last-health"
    read -r last < "$STATE/last-health" || last=0
fi
case "$last" in ''|*[!0-9]*) last=0;; esac
healthy=no
if [ -f "$STATE/supervisor-targets" ]; then
    trusted_path "$STATE/supervisor-targets"
    healthy=yes
    while read -r manager target; do
        case "$manager" in
            launchd)
                if ! /bin/launchctl print "$target" 2>/dev/null | /usr/bin/grep -q 'state = running'; then healthy=no; fi;;
            systemd)
                /usr/bin/systemctl is-active --quiet "$target" || healthy=no;;
            docker)
                trusted_path /usr/bin/docker || { healthy=no; continue; }
                [ "$(/usr/bin/docker inspect --format '{{.State.Running}}' "$target" 2>/dev/null)" = true ] || healthy=no;;
            *) healthy=no;;
        esac
    done < "$STATE/supervisor-targets"
fi
if [ "$healthy" = yes ] && [ $((now - last)) -ge 0 ] && [ $((now - last)) -lt 300 ]; then
    printf 'chief-supervisor decision=noop python=0\n'
    exit 0
fi
trusted_runtime
exec "$PY" -I -S -B -c 'import sys; sys.path.append("/opt/chief/lib/hermes-host-bootstrap"); from hermes_converger.runtime import run; raise SystemExit(run("supervisor"))'
