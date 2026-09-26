#!/bin/sh
# Reviewed closure carried INSIDE hermes_converger by the old chief-update.
set -eu
if [ "${1:-}" = --plan ]; then
    case "${2:-}" in macos|linux) platform=$2;; *) echo 'usage: close.sh --plan macos|linux' >&2; exit 2;; esac
    [ "$#" = 2 ] || exit 2
    printf '%s\n' "Step 0 closure ($platform): no changes"
    if [ "$platform" = macos ]; then
        printf '%s\n' '1. Existing access: sudo -n /usr/local/bin/chief-update (old updater installs origin/main package + two launchers).' \
          '2. Final privileged invocation: sudo -n /usr/local/bin/hermes-converger (no arguments).'
    else
        printf '%s\n' '1. Plain root: install the reviewed hermes_converger payload in /usr/local/lib/hermes-host-bootstrap.' \
          '2. In the same root session: /bin/sh /usr/local/lib/hermes-host-bootstrap/hermes_converger/step0/close.sh.'
    fi
    printf '%s\n' \
      '   Validate root ownership and every parent; stop old convergence jobs; install hardened entry points.' \
      '   Provision node.env from trusted registry/root files; validate root-only Python or record HOLD.' \
      '   Switch root units/plists; install boot/login/wake/network/periodic readers; preserve owner services.'
    if [ "$platform" = macos ]; then
        printf '%s\n' '   Mac: RunAtLoad, login LaunchAgent, calendar minute + WatchPaths; dark/unknown wake report-only; Q6 qualification hold.'
    else
        printf '%s\n' '   Linux: h-do1 boot reconcile independent of Core; user-manager login, system-sleep, network-online, timer + path.' \
          '   h-do1/h-af/h-btp: run reviewed close.sh directly as root; preserve node and owner workload units.'
    fi
    printf '%s\n' '3. LAST privileged phase: remove hermes-converger, chief-node-supervisor and chief-update grants; visudo -c original and staged policy; replace; visudo -c.' \
      '4. Unprivileged proof: no NOPASSWD entries, fixed argv, root parent chains, node.env identity, closure receipt or visible HOLD.' \
      'No later sudo grant is needed; do not restore the grants. Unreachable Mac: same closure from an administrator console.'
    exit 0
fi
[ "$#" = 0 ] || { echo 'chief closure: arguments refused' >&2; exit 2; }
# The public launcher has already checked the full payload tree. Direct root
# installation must use the reviewed root-owned tree, never a login checkout.
BASE=/usr/local/lib/hermes-host-bootstrap/hermes_converger/step0
# shellcheck source=hermes_converger/step0/trust.sh
. "$BASE/trust.sh"
[ "$(/usr/bin/id -u)" = 0 ] || { hold 'root required'; exit 1; }
trusted_tree /usr/local/lib/hermes-host-bootstrap/hermes_converger || exit 1
trusted_path /usr/local/bin || exit 1
OS=$(/usr/bin/uname -s)
STATE=/var/lib/chief/currency-step0

# shellcheck source=hermes_converger/step0/contain.sh
. "$BASE/contain.sh"

# Stop vulnerable readers FIRST. If any later preparation fails, the EXIT trap
# still closes their sudo access. A failed closure never reenables old jobs.
stop_jobs
trap 'trap - EXIT; contain preparation_failed' EXIT
if [ "$OS" = Darwin ]; then
    /usr/bin/dscl . -read /Groups/chief >/dev/null 2>&1 || /usr/sbin/dseditgroup -o create chief
else
    /usr/bin/getent group chief >/dev/null || /usr/sbin/groupadd --system chief
fi
trusted_path /var
trusted_path /etc
for dir in /var/lib /var/lib/chief /etc/chief; do
    if [ -e "$dir" ]; then trusted_path "$dir"; else /usr/bin/install -d -o root -g chief -m 0750 "$dir"; fi
    trusted_path "$dir"
done
for dir in "$STATE" /var/lib/chief/requests /var/lib/chief/converger; do
    [ ! -e "$dir" ] || trusted_path "$dir"
    /usr/bin/install -d -o root -g chief -m 0750 "$dir"
done
trusted_path "$STATE"
trusted_path /var/lib/chief/requests
for hint in login wake network request; do
    [ ! -L "/var/lib/chief/requests/$hint" ] || exit 1
    /usr/bin/install -o root -g chief -m 0620 /dev/null "/var/lib/chief/requests/$hint"
done
for name in hermes-converger chief-node-supervisor chief-update chief-update-request; do
    [ ! -e "/usr/local/bin/$name" ] || trusted_path "/usr/local/bin/$name"
    [ ! -L "/usr/local/bin/$name" ] || exit 1
    /usr/bin/install -o root -m 0755 "$BASE/bin/$name" "/usr/local/bin/$name"
done
safe_install() {
    source=$1 destination=$2 permissions=${3:-0644}
    trusted_path "${destination%/*}"
    [ ! -L "$destination" ] || { hold "destination symlink: $destination"; return 1; }
    [ ! -e "$destination" ] || trusted_path "$destination"
    /usr/bin/install -o root -m "$permissions" "$source" "$destination"
}
# shellcheck source=hermes_converger/step0/configure.sh
. "$BASE/configure.sh"
reason=''
if ! configure_node_env; then reason=node_config_invalid; fi
if ! trusted_python; then reason="${reason:+$reason,}trusted_python_unavailable"; fi
if [ -z "$reason" ]; then
    if ! "$PY" -I -S -B -c 'import sys; sys.path.insert(0,"/usr/local/lib/hermes-host-bootstrap"); from hermes_converger.runtime import configure; configure()'; then
        reason=node_config_invalid
    fi
fi
# Always install safe definitions, including when held. No owner workload or
# chief-node.service replacement (h-btp has its own user/layout).
if [ "$OS" = Darwin ]; then
    trusted_path /Library/LaunchDaemons
    trusted_path /Library/LaunchAgents
    for name in com.chief.node-reconcile com.chief.node-supervisor com.chief.update-request; do
        safe_install "$BASE/launchd/$name.plist" "/Library/LaunchDaemons/$name.plist"
    done
    safe_install "$BASE/launchd/com.chief.update-login.plist" /Library/LaunchAgents/com.chief.update-login.plist
else
    trusted_path /etc/systemd/system
    for f in "$BASE"/systemd/*; do
        # Retire per-unit overrides before loading the fixed root command. Keep
        # an audit copy, never source or execute its contents.
        for manager_dir in /etc/systemd/system /run/systemd/system; do
            override=$manager_dir/${f##*/}.d
            if [ -e "$override" ] || [ -L "$override" ]; then
                trusted_path "$manager_dir"
                retired=$(/usr/bin/mktemp -d "$STATE/retired-overrides.XXXXXX")
                /bin/mv "$override" "$retired/"
            fi
        done
        safe_install "$f" "/etc/systemd/system/${f##*/}"
    done
    trusted_path /etc/systemd
    trusted_path /usr/lib/systemd
    for dir in /etc/systemd/user /usr/lib/systemd/system-sleep; do
        [ ! -e "$dir" ] || trusted_path "$dir"
        /usr/bin/install -d -m 0755 "$dir"
    done
    trusted_path /etc/systemd/user
    trusted_path /usr/lib/systemd/system-sleep
    safe_install "$BASE/chief-update-login.service" /etc/systemd/user/chief-update-login.service
    safe_install "$BASE/chief-update-resume" /usr/lib/systemd/system-sleep/chief-update-resume 0755
    /usr/bin/systemctl daemon-reload
    if [ -z "$reason" ]; then
        for f in "$BASE"/systemd/*; do
            unit=${f##*/}
            drops=$(/usr/bin/systemctl show "$unit" --property=DropInPaths --value)
            fragment=$(/usr/bin/systemctl show "$unit" --property=FragmentPath --value)
            if [ -n "$drops" ] || [ "$fragment" != "/etc/systemd/system/$unit" ]; then
                # Global/type-wide overrides can affect owner workloads. Do not
                # edit them; leave Chief jobs disabled and show the reason.
                reason="effective_unit_override:$unit"
                break
            fi
        done
    fi
    /usr/bin/systemctl --global enable chief-update-login.service
fi
# Receipt precedes revocation; sudoers.closed is intentionally NOT asserted here.
printf '%s\n' "prepared: $OS" "hold: ${reason:-none}" > "$STATE/closure-status"
if [ -z "$reason" ]; then
    # Marker only selects hardened execution; never makes a caller authoritative.
    [ ! -L "$STATE/prepared" ] || exit 1
    : > "$STATE/prepared"
    if [ "$OS" = Darwin ]; then
        for label in com.chief.node-reconcile com.chief.node-supervisor com.chief.update-request; do
            /bin/launchctl enable "system/$label"
            /bin/launchctl bootstrap system "/Library/LaunchDaemons/$label.plist"
        done
    else
        /usr/bin/systemctl enable chief-node-reconcile.service chief-node-supervisor.timer chief-update.timer chief-update-request.path
        /usr/bin/systemctl start chief-node-supervisor.timer chief-update.timer chief-update-request.path
    fi
else
    printf 'chief Step 0 HOLD: %s; root jobs remain disabled\n' "$reason" >&2
fi
trap - EXIT
remove_grants
printf 'chief Step 0: grants removed; hold=%s\n' "${reason:-none}"
