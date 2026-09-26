#!/bin/sh
# Sourced by the clean fixed launcher after trusted_entries; no no-op Python.
set -eu
now=$(/bin/date +%s)
read_state last-check 0
last=$value
case "$last" in ''|*[!0-9]*) last=0;; esac
trigger=periodic
pending=no
wake=linux
full=yes
if [ "$TRUST_OS" = Darwin ]; then
    # One sysctl, no sed/grep pipelines or second uname.
    epochs=$(/usr/sbin/sysctl -n kern.boottime kern.waketime 2>/dev/null) || epochs='unknown
unknown'
    boot=${epochs%%'
'*}
    wake=${epochs#*'
'}
    full=no
    power=$(/usr/sbin/ioreg -r -n IOPMrootDomain -d 1) || power=''
    case "$power" in
        *'"SystemPowerStateCapabilities" = '*)
            caps=${power#*'"SystemPowerStateCapabilities" = '}
            caps=${caps%%[!0-9]*}
            case "$caps" in ''|*[!0-9]*) ;; *) [ $((caps & 3)) -ne 3 ] || full=yes;; esac;;
    esac
else
    IFS= read -r boot < /proc/sys/kernel/random/boot_id
fi
read_state boot ''; old_boot=$value
read_state wake ''; previous=$value
[ "$wake" = "$previous" ] || trigger=wake
[ "$last" != 0 ] || trigger=boot
for hint in login wake network request; do
    if [ -s "$REQUESTS/$hint" ]; then trigger=$hint; pending=yes; fi
done
url=''
while IFS='=' read -r name value; do
    [ "$name" != CHIEF_CORE_URL ] || url=$value
done < "$CONFIG"
[ -n "$url" ] || { hold missing_core_url; exit 1; }
online=no
# Cold/relayed Tailscale paths need more than one second. Retry one miss without
# adding any work to the normal successful probe (six seconds maximum total).
probe_core() {
    /usr/bin/curl --silent --max-time 3 --connect-timeout 3 --noproxy '*' --output /dev/null -- "$url/health"
}
if probe_core || probe_core; then online=yes; fi
read_state online no; old_online=$value
if [ "$online" != "$old_online" ]; then
    if [ "$online" = yes ]; then
        [ -f "$REQUESTS/network" ] && [ ! -L "$REQUESTS/network" ] || exit 1
        printf 'network\n' > "$REQUESTS/network"
        trigger=network
    fi
    observation=$(/usr/bin/mktemp "$STATE/.online.XXXXXX")
    printf '%s\n' "$online" > "$observation"
    /bin/mv -f "$observation" "$STATE/online"
fi
read_state full no; old_full=$value
[ "$full" != yes ] || [ "$old_full" = yes ] || trigger=wake
[ "$boot" = "$old_boot" ] || trigger=boot
# Worker commits stamps under the shared lock. Pending wake/return survives a
# busy worker. Offline suppression is bounded by the last worker check; explicit
# hints and the half-hour fallback still run even during a persistent outage.
noop=no
if [ "$online" = no ] && [ "$trigger" = periodic ] && [ "$pending" = no ] &&
   [ $((now - last)) -ge 0 ] && [ $((now - last)) -lt 1800 ]; then noop=yes; fi
if [ $((now - last)) -ge 0 ]; then
    [ $((now - last)) -ge 60 ] || noop=yes
    [ "$trigger" != periodic ] || [ $((now - last)) -ge 300 ] || noop=yes
fi
if [ "$noop" = yes ]; then
    printf 'chief-pulse at=%s decision=noop python=0 full=%s online=%s\n' "$now" "$full" "$online"
    exit 0
fi
trusted_runtime
printf 'chief-pulse at=%s decision=check trigger=%s full=%s online=%s\n' "$now" "$trigger" "$full" "$online"
export CHIEF_PULSE_BOOT=$boot CHIEF_PULSE_TRIGGER=$trigger CHIEF_PULSE_WAKE=$wake CHIEF_PULSE_ONLINE=$online CHIEF_PULSE_FULL=$full
exec "$PY" -I -S -B -c 'import sys; sys.path.append("/opt/chief/lib/hermes-host-bootstrap"); from hermes_converger.runtime import run; raise SystemExit(run("converge"))'
