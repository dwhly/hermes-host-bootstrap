#!/bin/sh
# A0 pulse: shell only on no-op. Phase A's Go updater is deliberately not here.
# Invoked in an empty environment by a zero-argument root entry point.
set -eu
BASE=/usr/local/lib/hermes-host-bootstrap/hermes_converger/step0
# shellcheck source=hermes_converger/step0/trust.sh
. "$BASE/trust.sh"
STATE=/var/lib/chief/currency-step0
trusted_path "$STATE"
trusted_path /etc/chief/node.env
now=$(/bin/date +%s)
last=0
if [ -f "$STATE/last-check" ]; then
    trusted_path "$STATE/last-check"
    read -r last < "$STATE/last-check" || last=0
fi
case "$last" in ''|*[!0-9]*) last=0;; esac
trigger=periodic
wake=linux
full=yes
if [ "$(/usr/bin/uname -s)" = Darwin ]; then
    boot=$(/usr/sbin/sysctl -n kern.boottime 2>/dev/null || echo unknown)
    wake=$(/usr/sbin/sysctl -n kern.waketime 2>/dev/null || echo unknown)
    full=no
    # Default remains report-only until the paired Q6 field measurements pass.
    # Display-on is necessary, never a stamp alone or a caller hint.
    if [ -f /etc/chief/wake-qualified ]; then
        trusted_path /etc/chief/wake-qualified
        if /usr/sbin/ioreg -r -n IODisplayWrangler -d 1 | /usr/bin/grep -Eq '"CurrentPowerState"[[:space:]]*=[[:space:]]*4'; then full=yes; fi
    fi
else
    boot=$(/bin/cat /proc/sys/kernel/random/boot_id)
fi
old_boot=''
if [ -f "$STATE/boot" ]; then trusted_path "$STATE/boot"; old_boot=$(/bin/cat "$STATE/boot"); fi
previous=''
if [ -f "$STATE/wake" ]; then trusted_path "$STATE/wake"; previous=$(/bin/cat "$STATE/wake"); fi
[ "$wake" = "$previous" ] || trigger=wake
[ "$last" != 0 ] || trigger=boot
# Fixed files under a root-owned non-writable directory; readers never follow a
# link and never read more than 257 bytes. Python consumes under the shared lock.
for hint in login wake network request; do
    [ ! -s "/var/lib/chief/requests/$hint" ] || trigger=$hint
done
url=$(/usr/bin/sed -n 's/^CHIEF_CORE_URL=//p' /etc/chief/node.env)
[ -n "$url" ] || { hold missing_core_url; exit 1; }
online=no
/usr/bin/curl --silent --max-time 1 --connect-timeout 1 --noproxy '*' --output /dev/null -- "$url/health" && online=yes
old_online=no
if [ -f "$STATE/online" ]; then trusted_path "$STATE/online"; read -r old_online < "$STATE/online" || old_online=no; fi
if [ "$online" != "$old_online" ]; then
    if [ "$online" = yes ]; then
        # Persist return independently of the worker lock. A busy worker cannot
        # erase the observation merely by coalescing this pulse.
        [ -f /var/lib/chief/requests/network ] && [ ! -L /var/lib/chief/requests/network ] || exit 1
        printf 'network\n' > /var/lib/chief/requests/network
        trigger=network
    fi
    observation=$(/usr/bin/mktemp "$STATE/.online.XXXXXX")
    printf '%s\n' "$online" > "$observation"
    /bin/mv -f "$observation" "$STATE/online"
fi
# A return to full wake must not wait for the next five-minute report interval.
old_full=no
if [ -f "$STATE/full" ]; then trusted_path "$STATE/full"; read -r old_full < "$STATE/full" || old_full=no; fi
[ "$full" != yes ] || [ "$old_full" = yes ] || trigger=wake
[ "$boot" = "$old_boot" ] || trigger=boot
# Spool flooding cannot force Python more than once/minute. Wake and reconnect
# survive a busy worker because only its lock holder commits these stamps.
if [ $((now - last)) -ge 0 ] && [ $((now - last)) -lt 60 ]; then printf 'chief-pulse at=%s decision=noop python=0 full=%s online=%s\n' "$now" "$full" "$online"; exit 0; fi
if [ "$trigger" = periodic ] && [ $((now - last)) -ge 0 ] && [ $((now - last)) -lt 300 ]; then printf 'chief-pulse at=%s decision=noop python=0 full=%s online=%s\n' "$now" "$full" "$online"; exit 0; fi
trusted_tree /usr/local/lib/hermes-host-bootstrap/hermes_converger
trusted_python
printf 'chief-pulse at=%s decision=check trigger=%s full=%s online=%s\n' "$now" "$trigger" "$full" "$online"
export CHIEF_PULSE_BOOT=$boot CHIEF_PULSE_TRIGGER=$trigger CHIEF_PULSE_WAKE=$wake CHIEF_PULSE_ONLINE=$online CHIEF_PULSE_FULL=$full
exec "$PY" -I -S -B -c 'import sys; sys.path.insert(0,"/usr/local/lib/hermes-host-bootstrap"); from hermes_converger.runtime import run; raise SystemExit(run("converge"))'
