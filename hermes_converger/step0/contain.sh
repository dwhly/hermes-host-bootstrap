#!/bin/sh
remove_grants() {
    # Stage the whole standard include tree. Never replace policy that has not
    # passed a combined visudo -c. Nonstandard includes require admin review.
    trusted_path /etc/sudoers
    trusted_path /etc/sudoers.d
    /usr/sbin/visudo -c
    stage=$(/usr/bin/mktemp -d /etc/.chief-sudoers.XXXXXX)
    /bin/mkdir "$stage/d"
    for f in /etc/sudoers /etc/sudoers.d/*; do
        [ -f "$f" ] || continue
        trusted_path "$f"
        # Only the standard includedir is supported; unknown policy is a hold.
        if /usr/bin/grep -E '^[[:space:]]*([#@]include)' "$f" | /usr/bin/grep -Ev '^[[:space:]]*([#@]includedir)[[:space:]]+(/private)?/etc/sudoers[.]d/?[[:space:]]*$' >/dev/null; then
            hold "nonstandard sudoers include: $f"; return 1
        fi
        out=$stage/d/${f##*/}
        [ "$f" != /etc/sudoers ] || out=$stage/main
        /usr/bin/awk '# Remove complete logical rules mentioning any retired entry point, including
# continuations and mixed command lists. Preserve unrelated rules byte-for-byte.
function flush() {
    if (record ~ /\/usr\/local\/bin\/(hermes-converger|chief-node-supervisor|chief-update)([[:space:],\\]|$)/ && record !~ /^[[:space:]]*#/) {
        if (record ~ /^[[:space:]]*Cmnd_Alias[[:space:]]/) {
            # Keep alias references valid, but give them only a fixed failing
            # command. They can no longer invoke any Chief entry point.
            gsub(/\/usr\/local\/bin\/(hermes-converger|chief-node-supervisor|chief-update)/, "/usr/bin/false", record)
            printf "%s", record
        } else {
            print "# Step 0: retired Chief privilege rule."
        }
    } else {
        printf "%s", record
    }
    record = ""
}
{ record = record $0 "\n"; if ($0 !~ /\\[[:space:]]*$/) flush() }
END { if (record != "") flush() }
' "$f" > "$out"
        /bin/chmod 0440 "$out"
        # sudo refuses policy not owned by uid 0 / gid 0. A NEW file's group is the directory's group on macOS
        # (wheel, gid 0) but the PROCESS's group on Linux (h-do1: chief), and mv carries it onto /etc/sudoers.
        # So set the owner explicitly. (Linux closure left /etc/sudoers root:chief and sudo broken.)
        /usr/sbin/chown 0:0 "$out" 2>/dev/null || /bin/chown 0:0 "$out"
    done
    /usr/bin/sed "s|/private/etc/sudoers[.]d|$stage/d|g; s|/etc/sudoers[.]d|$stage/d|g" "$stage/main" > "$stage/check"
    /bin/chmod 0440 "$stage/check"
    /usr/sbin/chown 0:0 "$stage/check" 2>/dev/null || /bin/chown 0:0 "$stage/check"
    /usr/sbin/visudo -c -f "$stage/check"
    # This is the last privileged phase. Atomic renames within /etc; no grant
    # restoration, bootstrap/service activation, or privileged remote call follows.
    for f in "$stage"/d/*; do
        [ -f "$f" ] || continue
        /bin/mv -f "$f" "/etc/sudoers.d/${f##*/}"
    done
    /bin/mv -f "$stage/main" /etc/sudoers
    # An explicit check: `set -e` does not apply when the caller runs this function inside a condition, and a
    # post-swap failure (for example, wrong owner) must never be reported as a successful closure.
    /usr/sbin/visudo -c || { hold sudoers_postcheck_failed; return 1; }
    /bin/rm -rf "$stage"
    # Effective policy catches aliases, wildcards and directory grants that a
    # literal rule rewrite cannot safely remove. Root is already unrestricted.
    for user in dano danz; do # generated runtime users
        [ "$user" != root ] || continue
        /usr/bin/id -u "$user" >/dev/null 2>&1 || continue
        listing=$(/usr/bin/sudo -ll -U "$user") || { hold "effective_policy_query_failed:$user"; return 1; }
        # sudo -ll expands aliases and prints per-rule Options and Commands.
        patterns=$(printf '%s\n' "$listing" | /usr/bin/awk '
            /^Sudoers entry:/ { free=0; commands=0 }
            /Options:/ { free=($0 ~ /!authenticate/) }
            /Commands:/ { commands=1; next }
            commands && free { sub(/^[ \t]+/, ""); print }
        ')
        while IFS= read -r rule; do
            [ -n "$rule" ] || continue
            case "$rule" in !*) continue;; esac
            pattern=${rule%% *}
            for command in /opt/chief/bin/hermes-converger /opt/chief/bin/chief-node-supervisor /opt/chief/bin/chief-update /usr/local/bin/hermes-converger /usr/local/bin/chief-node-supervisor /usr/local/bin/chief-update; do
                case "$pattern" in ALL) hold "remaining_passwordless_grant:$user:$pattern"; return 1;; esac
                # sudo command patterns deliberately retain glob semantics.
                # shellcheck disable=SC2254
                case "$command" in $pattern) hold "remaining_passwordless_grant:$user:$pattern"; return 1;; esac
                case "$pattern" in */) case "$command" in "$pattern"*) hold "remaining_passwordless_grant:$user:$pattern"; return 1;; esac;; esac
            done
        done <<EOF
$patterns
EOF
    done
}

stop_jobs() {
    # Disable EVERY trigger before stopping anything: stopping a service can
    # terminate this shell. Callers must publish a current hold receipt first.
    if [ "$OS" = Darwin ]; then
        for label in com.chief.node-reconcile com.chief.node-supervisor com.chief.update-request; do
            /bin/launchctl disable "system/$label"
        done
        for label in com.chief.node-reconcile com.chief.node-supervisor com.chief.update-request; do
            /bin/launchctl bootout "system/$label" 2>/dev/null || true
        done
    else
        for unit in chief-node-reconcile.service chief-node-converger.service chief-node-supervisor.service chief-node-supervisor.timer chief-update.service chief-update.timer chief-update-request.path chief-update-request.service; do
            /usr/bin/systemctl disable "$unit" 2>/dev/null || true
        done
        for unit in chief-node-supervisor.timer chief-update.timer chief-update-request.path chief-node-reconcile.service chief-node-converger.service chief-node-supervisor.service chief-update.service chief-update-request.service; do
            /usr/bin/systemctl stop "$unit" 2>/dev/null || true
        done
    fi
}

receipt() {
    # Usable even if preparation failed before creating the chief group/state.
    STATE=/var/lib/chief/currency-step0
    for dir in /var/lib /var/lib/chief "$STATE"; do
        if [ ! -e "$dir" ]; then
            trusted_path "${dir%/*}" || return 1
            /usr/bin/install -d -o root -m 0755 "$dir" || return 1
        fi
        trusted_path "$dir" || return 1
    done
    receipt_tmp=$(/usr/bin/mktemp "$STATE/.receipt.XXXXXX") || return 1
    printf 'hold: %s\njobs: %s\ngrants: %s\n' "$1" "$2" "$3" > "$receipt_tmp"
    /bin/chmod 0644 "$receipt_tmp"
    /bin/mv -f "$receipt_tmp" "$STATE/closure-status"
}

send_receipt() {
    # A closed SSH pipe must not interrupt containment or revocation.
    ( /bin/cat "$STATE/closure-status" >&3 ) 2>/dev/null || true
}

contain() {
    containment_reason=$*
    printf 'chief Step 0 HOLD: %s; disabling root jobs and retiring sudo grants\n' "$*" >&2
    OS=$(/usr/bin/uname -s)
    receipt "contained:$containment_reason" disabled pending
    stop_jobs
    trap 'receipt "contained:$containment_reason:${HOLD_REASON:-revocation_failed}" disabled pending; send_receipt' EXIT
    remove_grants
    receipt "contained:$containment_reason" disabled removed
    trap - EXIT
    send_receipt
    exit 1
}

refuse() {
    # Transient post-preparation faults must leave the safe readers enabled so
    # the next pulse retries. Containment is only for the initial unsafe state.
    if { [ -f /var/lib/chief/currency-step0/prepared ] && trusted_path /var/lib/chief/currency-step0/prepared; } ||
       { [ -f /var/lib/chief/currency-step0/grants-removed ] && trusted_path /var/lib/chief/currency-step0/grants-removed; }; then
        hold "$*"; exit 1
    fi
    contain "$@"
}
