#!/bin/sh
# Shared read-only lock checks and acquisition. Source only from a trusted tree.
closure_lock_identity() {
    lock=/run/chief-currency-closure.lock
    if [ "$OS" = Darwin ]; then
        boot_id=$(/usr/sbin/sysctl -n kern.bootsessionuuid) || { hold boot_identity_unavailable; return 1; }
        # A boot identity is also a filename component, never arbitrary output.
        case "$boot_id" in ''|*[!a-zA-Z0-9-]*) hold invalid_boot_identity; return 1;; esac
        lock=/var/lib/chief/chief-currency-closure.$boot_id.lock
    else
        boot_id=$(/bin/cat /proc/sys/kernel/random/boot_id) || { hold boot_identity_unavailable; return 1; }
    fi
    [ -n "$boot_id" ] || { hold missing_boot_identity; return 1; }
}

closure_lock_check() {
    [ ! -e "$lock.reclaim" ] && [ ! -L "$lock.reclaim" ] || {
        hold closure_reclaim_pending; return 1;
    }
    closure_lock_holder_check
}

closure_lock_holder_check() {
    [ ! -e "$lock" ] && [ ! -L "$lock" ] && return 0
    trusted_tree "$lock" || return 1
    [ -d "$lock" ] && [ ! -L "$lock" ] || { hold invalid_closure_lock; return 1; }
    holder=0
    [ ! -f "$lock/pid" ] || read -r holder < "$lock/pid" || holder=0
    case "$holder" in ''|*[!0-9]*) holder=0;; esac
    if [ "$holder" != 0 ] && kill -0 "$holder" 2>/dev/null; then
        printf 'closure already running; revocation pending\n'
        hold closure_already_running; return 1
    fi
    # No pid may be the interval between mkdir and publication. Never reclaim
    # that interval; a killed publisher needs administrator repair (or reboot).
    [ "$holder" != 0 ] || { hold closure_pid_publication_pending; return 1; }
}

closure_lock_acquire() {
    closure_lock_check || return 75
    if ! /bin/mkdir "$lock" 2>/dev/null; then
        closure_lock_check || return 75
        # Single reclaimer, with a second liveness check AFTER serialization.
        # Never reap this guard by PID: that would recreate the same race. An
        # interrupted guard is a visible hold until admin repair or next boot.
        /bin/mkdir "$lock.reclaim" 2>/dev/null || return 75
        trap '/bin/rmdir "$lock.reclaim"' EXIT
        closure_lock_holder_check || return 75
        /bin/rm -rf "$lock"
        # A first-time acquirer can win the mkdir while we reclaim. Respect it.
        /bin/mkdir "$lock" 2>/dev/null || return 75
        printf '%s\n' "$boot_id" > "$lock/boot"
        printf '%s\n' "$$" > "$lock/pid"
        # Disarm before release: an EXIT after rmdir must never remove a
        # successor's guard. Interruption before rmdir remains a visible hold.
        trap - EXIT
        /bin/rmdir "$lock.reclaim"
        return 0
    fi
    printf '%s\n' "$boot_id" > "$lock/boot"
    printf '%s\n' "$$" > "$lock/pid"
}
