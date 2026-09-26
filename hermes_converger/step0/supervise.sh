#!/bin/sh
# Sourced by the clean fixed launcher after trusted_entries.
# read_state sets value in the calling shell.
# shellcheck disable=SC2154
set -eu
now=$(/bin/date +%s)
read_state last-health 0
last=$value
case "$last" in ''|*[!0-9]*) last=0;; esac
changed=yes
if [ -f "$STATE/supervisor-targets" ] && [ ! -L "$STATE/supervisor-targets" ]; then
    changed=no
    while read -r manager target previous retry; do
        active=no
        case "$manager" in
            launchd)
                status=$(/bin/launchctl print "$target" 2>/dev/null) || status=''
                case "$status" in *'state = running'*) active=yes;; esac;;
            systemd)
                /usr/bin/systemctl is-active --quiet "$target" && active=yes;;
            docker)
                trusted_path /usr/bin/docker || { changed=yes; continue; }
                status=$(/usr/bin/docker inspect --format '{{.State.Running}}' "$target" 2>/dev/null) || status=''
                [ "$status" != true ] || active=yes;;
            *) changed=yes;;
        esac
        [ "$active" = "$previous" ] || changed=yes
        case "$retry" in ''|*[!0-9]*) retry=0;; esac
        if [ "$active" = no ] && [ "$retry" -gt 0 ] && [ "$now" -ge "$retry" ]; then changed=yes; fi
    done < "$STATE/supervisor-targets"
fi
# A stable dead/quarantined/report-only target is also a no-op. Fresh health and
# admission/restart decisions are re-evaluated at least every five minutes.
if [ "$changed" = no ] && [ $((now - last)) -ge 0 ] && [ $((now - last)) -lt 300 ]; then
    printf 'chief-supervisor decision=noop python=0\n'
    exit 0
fi
trusted_runtime
exec "$PY" -I -S -B -c 'import sys; sys.path.append("/opt/chief/lib/hermes-host-bootstrap"); from hermes_converger.runtime import run; raise SystemExit(run("supervisor"))'
