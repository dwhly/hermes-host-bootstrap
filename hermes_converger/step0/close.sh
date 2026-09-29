#!/bin/sh
# Reviewed closure carried INSIDE hermes_converger by the old chief-update.
set -eu
umask 027
trap '' HUP PIPE
if [ "${1:-}" = --plan ]; then
    case "${2:-}" in macos|linux) platform=$2;; *) echo 'usage: close.sh --plan macos|linux' >&2; exit 2;; esac
    [ "$#" = 2 ] || exit 2
    printf '%s\n' "Step 0 closure ($platform): no changes"
    if [ "$platform" = macos ]; then
        printf '%s\n' '1. Existing access: sudo -n /usr/local/bin/chief-update (old updater installs origin/main package + two launchers).' \
          '2. Final privileged invocation: sudo -n /usr/local/bin/hermes-converger (no arguments).'
    else
        printf '%s\n' '1. Plain root: install the reviewed hermes_converger payload in /opt/chief/lib/hermes-host-bootstrap.' \
          '2. In the same root session: /bin/sh /opt/chief/lib/hermes-host-bootstrap/hermes_converger/step0/close.sh.'
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
preflight=no
if [ "${1:-}" = --preflight ] && [ "$#" = 1 ]; then preflight=yes; shift; fi
[ "$#" = 0 ] || { echo 'chief closure: arguments refused' >&2; exit 2; }
# The public launcher has already checked the full payload tree. Direct root
# installation must use the reviewed root-owned tree, never a login checkout.
BASE=/opt/chief/lib/hermes-host-bootstrap/hermes_converger/step0
if [ "$preflight" = yes ]; then
    case "$0" in /*/close.sh) BASE=${0%/*};; *) echo 'preflight requires an absolute reviewed script path' >&2; exit 2;; esac
fi
# Bootstrap trust without executing any helper from the selected payload. lstat
# every lexical parent in one batch; reject links, writable chains and Mac ACLs.
# This also protects a direct administrator invocation before importing code.
bootstrap_trust() (
    p=$BASE/trust.sh
    set -- "$p"
    while [ "$p" != / ]; do
        p=${p%/*}; [ -n "$p" ] || p=/
        set -- "$@" "$p"
    done
    if [ "$(/usr/bin/uname -s)" = Darwin ]; then
        radix=0
        metadata=$(/usr/bin/stat -f '%u %p' "$@") || exit 1
        acl=$(/bin/ls -lde "$@") || exit 1
        while IFS= read -r row; do
            row=${row#"${row%%[![:space:]]*}"}
            case "$row" in ??????????+*|[0-9]*:*) exit 1;; esac
        done <<EOF
$acl
EOF
    else
        radix=0x
        metadata=$(/usr/bin/stat -c '%u %f' "$@") || exit 1
    fi
    while read -r uid mode; do
        bits=$(( ${radix}${mode} ))
        [ "$uid" = 0 ] && [ $((bits & 0022)) = 0 ] &&
            { [ $((bits & 0170000)) = $((0040000)) ] || [ $((bits & 0170000)) = $((0100000)) ]; } || exit 1
    done <<EOF
$metadata
EOF
)
bootstrap_trust || { echo 'chief Step 0 HOLD: unsafe bootstrap trust chain' >&2; exit 1; }
# shellcheck source=hermes_converger/step0/trust.sh
. "$BASE/trust.sh"
OS=$(/usr/bin/uname -s)
STATE=/var/lib/chief/currency-step0
if [ "$preflight" = yes ]; then
    trusted_path "$BASE/preflight.sh" || exit 1
    # shellcheck source=hermes_converger/step0/preflight.sh
    . "$BASE/preflight.sh"
    closure_preflight
    exit $?
fi
[ "$(/usr/bin/id -u)" = 0 ] || { hold 'root required'; exit 1; }
trusted_tree /opt/chief/lib/hermes-host-bootstrap/hermes_converger || exit 1
trusted_path /opt/chief/bin || exit 1

# shellcheck source=hermes_converger/step0/contain.sh
. "$BASE/contain.sh"

# Keep all output in a root log even after the SSH pipe disappears. A final
# receipt is also sent to the original caller when that fd remains available.
if [ "$OS" = Darwin ]; then
    # /var/run is group-writable on macOS; root locks use trusted state parents.
    for dir in /var/lib /var/lib/chief; do
        trusted_path "${dir%/*}"
        [ -e "$dir" ] || /usr/bin/install -d -o root -m 0755 "$dir"
        trusted_path "$dir"
    done
fi
# shellcheck source=hermes_converger/step0/closure-lock.sh
. "$BASE/closure-lock.sh"
lock='' # populated by the shared identity helper
closure_lock_identity
trusted_path "${lock%/*}"
closure_lock_acquire
cleanup() { /bin/rm -rf "$lock"; }
trap 'cleanup' EXIT
# The closure log needs a root-only parent chain. On Linux, /var/log is root:syslog 0775 BY DESIGN (rsyslog creates
# its files there), so the trust check correctly refuses it. Linux uses /var/lib/chief instead; macOS keeps /var/log
# (root:wheel 0755).
closure_log_dir=/var/log
if [ "$OS" != Darwin ]; then
    closure_log_dir=/var/lib/chief
    [ -d "$closure_log_dir" ] || /bin/mkdir -m 0755 "$closure_log_dir"
fi
closure_log=$closure_log_dir/chief-closure.log
trusted_path "$closure_log_dir"
[ ! -L "$closure_log" ] || exit 1
[ ! -e "$closure_log" ] || trusted_path "$closure_log"
exec 3>&1
exec >>"$closure_log" 2>&1
trap 'cleanup' EXIT

revocation_failed() {
    receipt "${reason:+$reason,}${HOLD_REASON:-revocation_failed}" "$jobs" pending
    # A killed process leaves no stamp and resumes immediately. Persistent,
    # completed failures retry once per 15 minutes while safe readers continue.
    if [ -f "$STATE/prepared" ]; then
        retry=$(( $(/bin/date +%s) + 900 ))
        printf '%s\n' "$retry" > "$STATE/revocation-retry.new"
        /bin/mv -f "$STATE/revocation-retry.new" "$STATE/revocation-retry"
    fi
    send_receipt
    cleanup
}

finish_revocation() {
    trap 'revocation_failed' EXIT
    remove_grants
    /bin/sync
    receipt "${reason:-none}" "$jobs" removed
    : > "$STATE/grants-removed.new"
    /bin/mv -f "$STATE/grants-removed.new" "$STATE/grants-removed"
    /bin/rm -f "$STATE/revocation-retry"
    trap 'cleanup' EXIT
    send_receipt
}

activate_jobs() {
    if [ "$OS" = Darwin ]; then
        for label in com.chief.node-reconcile com.chief.node-supervisor com.chief.update-request; do
            /bin/launchctl enable "system/$label"
            if /bin/launchctl print "system/$label" >/dev/null 2>&1; then continue; fi
            attempt=0
            until /bin/launchctl bootstrap system "/Library/LaunchDaemons/$label.plist"; do
                attempt=$((attempt + 1))
                [ "$attempt" -lt 5 ] || return 1
                /bin/sleep 1
                /bin/launchctl print "system/$label" >/dev/null 2>&1 && break
            done
        done
    else
        /usr/bin/systemctl enable chief-node-reconcile.service chief-node-supervisor.timer chief-update.timer chief-update-request.path
        /usr/bin/systemctl start chief-node-supervisor.timer chief-update.timer chief-update-request.path
    fi
}

# A prepared reader may finish an interrupted revocation itself. Do not bootout
# the job currently running closure, and never trust prepared as a success receipt.
if [ -f "$STATE/prepared" ] && [ "$(/bin/cat "$STATE/prepared")" = fix1 ]; then
    trusted_path "$STATE/prepared"
    reason=''
    jobs=activation_pending
    receipt revocation_pending "$jobs" pending
    trap 'revocation_failed' EXIT
    activate_jobs
    jobs=enabled
    finish_revocation
    exit 0
fi

# Re-closure can be entered by one of these very jobs after marker loss. Exact
# installed definitions are sufficient to retain the reviewed readers while
# rebuilding preparation; never stop the job performing that recovery.
reviewed_jobs() {
    if [ "$OS" = Darwin ]; then
        for label in com.chief.node-reconcile com.chief.node-supervisor com.chief.update-request; do
            installed=/Library/LaunchDaemons/$label.plist
            trusted_path "$installed" && /usr/bin/cmp -s "$BASE/launchd/$label.plist" "$installed" || return 1
        done
    else
        for definition in "$BASE"/systemd/*; do
            installed=/etc/systemd/system/${definition##*/}
            trusted_path "$installed" && /usr/bin/cmp -s "$definition" "$installed" || return 1
        done
    fi
}
jobs=disabled
retain_readers=no
if reviewed_jobs; then retain_readers=yes; jobs=activation_pending; fi
receipt preparing "$jobs" pending
trap 'trap - EXIT; cleanup; contain preparation_failed' EXIT
[ "$retain_readers" = yes ] || stop_jobs
# Old success markers must never survive an interrupted re-closure.
/bin/rm -f "$STATE/grants-removed"
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
    [ ! -e "/opt/chief/bin/$name" ] || trusted_path "/opt/chief/bin/$name"
    [ ! -L "/opt/chief/bin/$name" ] || exit 1
    /usr/bin/install -o root -m 0755 "$BASE/bin/$name" "/opt/chief/bin/$name"
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
    if ! "$PY" -I -S -B -c 'import sys; sys.path.append("/opt/chief/lib/hermes-host-bootstrap"); from hermes_converger.runtime import configure; configure()'; then
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
jobs=disabled
receipt "${reason:-revocation_pending}" disabled pending
if [ -z "$reason" ]; then
    # Marker only selects hardened execution; never makes a caller authoritative.
    [ ! -L "$STATE/prepared" ] || exit 1
    printf 'fix1\n' > "$STATE/prepared"
    # From here, errors retain enabled safe readers and visible pending status.
    jobs=activation_pending
    trap 'revocation_failed' EXIT
    trusted_runtime
    activate_jobs
    jobs=enabled
else
    printf 'chief Step 0 HOLD: %s; root jobs remain disabled\n' "$reason" >&2
    receipt "$reason" disabled pending
    stop_jobs
fi
finish_revocation
printf 'chief Step 0: grants removed; hold=%s\n' "${reason:-none}"
[ -z "$reason" ]
