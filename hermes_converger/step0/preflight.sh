#!/bin/sh
# Read-only administrator checks. Do not call receipt/trusted_entries/runtime:
# those helpers may create state, rotate logs or populate the trust cache.
preflight_check() {
    if ( "$@" ); then return 0; fi
    failures=$((failures + 1))
    hold "preflight check failed: $*" || :
}

# Missing install destinations are allowed only beneath a trusted existing chain.
preflight_destination() {
    destination=$1
    [ ! -L "$destination" ] || { hold "destination symlink: $destination"; return 1; }
    if [ ! -e "$destination" ]; then
        while [ ! -e "$destination" ]; do
            [ ! -L "$destination" ] || { hold "destination symlink: $destination"; return 1; }
            destination=${destination%/*}
        done
        [ -d "$destination" ] || { hold "not a destination directory: $destination"; return 1; }
    elif [ "${2:-file}" = dir ]; then
        [ -d "$destination" ] || { hold "not a destination directory: $destination"; return 1; }
    else
        [ -f "$destination" ] || { hold "not a destination file: $destination"; return 1; }
    fi
    [ -d "$destination" ] || [ -f "$destination" ] || { hold "not a regular file/directory: $destination"; return 1; }
    trusted_path "$destination"
}

# The fixed dispatcher uses lstat and refuses aliases in its installed entry
# chain, even when a general trusted_path traversal would accept the target.
preflight_entry_chain() (
    entry=$1
    while [ "$entry" != / ] && [ -n "$entry" ]; do
        case "$OS:$entry" in Darwin:/var|Darwin:/etc) ;;
            *) [ ! -L "$entry" ] || { hold "entry symlink: $entry"; return 1; };; esac
        entry=${entry%/*}
    done
)

preflight_policy() {
    # Flatten the supported include tree and run the SAME rule renderer as
    # removal, entirely through pipes. visudo -c -f - never stages a file.
    policy=$(
        for file in /etc/sudoers /etc/sudoers.d/*; do
            [ -f "$file" ] || continue
            case "${file##*/}" in *.*|*~) continue;; esac
            /usr/bin/awk -f "$BASE/sudoers.awk" "$file" || exit 1
        done
    ) || return 1
    printf '%s\n' "$policy" | /usr/bin/sed '/^[[:space:]]*[#@]includedir[[:space:]]/d' |
        /usr/sbin/visudo -c -f -
}

preflight_lock() {
    lock='' # populated by the shared identity helper
    closure_lock_identity || return 1
    preflight_destination "$lock" dir || return 1
    closure_lock_check
}

closure_preflight() {
    failures=0
    preflight_check /bin/sh -c '[ "$(/usr/bin/id -u)" = 0 ]'
    # Missing executable dependencies are visible before any policy/job writes.
    for tool in /bin/sh /bin/cat /bin/chmod /bin/cp /bin/date /bin/hostname /bin/mkdir /bin/mv \
                /bin/rm /bin/rmdir /bin/sleep /bin/sync /usr/bin/awk /usr/bin/cmp \
                /usr/bin/find /usr/bin/grep /usr/bin/id /usr/bin/install /usr/bin/mktemp \
                /usr/bin/readlink /usr/bin/sed /usr/bin/stat /usr/bin/sudo /usr/bin/uname /usr/sbin/visudo; do
        preflight_check test -x "$tool"
    done
    if [ "$OS" = Darwin ]; then
        for tool in /bin/launchctl /bin/ls /usr/bin/dscl /usr/sbin/dseditgroup /usr/sbin/sysctl; do
            preflight_check test -x "$tool"
        done
    else
        for tool in /usr/bin/systemctl /usr/bin/getent /usr/sbin/groupadd /usr/sbin/usermod; do
            preflight_check test -x "$tool"
        done
    fi
    payload_ok=yes
    trusted_tree "$BASE/.." || { failures=$((failures + 1)); payload_ok=no; }
    for dir in /var/log /etc /var; do preflight_check trusted_path "$dir"; done
    if [ "$BASE" = /opt/chief/lib/hermes-host-bootstrap/hermes_converger/step0 ]; then
        preflight_check trusted_path /opt/chief/bin
    fi
    # The legacy bridge runs these checks before it copies any payload. The
    # private archive route never enters the bridge or relies on /usr/local.
    if [ "$OS" = Darwin ] && [ ! -f "$STATE/prepared" ] &&
       [ "$BASE" = /usr/local/lib/hermes-host-bootstrap/hermes_converger/step0 ]; then
        preflight_check trusted_path /usr/local/bin/hermes-converger
        preflight_check trusted_tree /usr/local/lib/hermes-host-bootstrap/hermes_converger
    fi
    for dir in /opt/chief/bin /opt/chief/lib/hermes-host-bootstrap /var/lib/chief/currency-step0 \
               /var/lib/chief/converger /var/lib/chief/requests /etc/chief; do
        preflight_check preflight_destination "$dir" dir
    done
    for entry in /opt/chief/bin /opt/chief/lib/hermes-host-bootstrap/hermes_converger/step0 \
                 /var/lib/chief/currency-step0 /var/lib/chief/requests /etc/chief/node.env; do
        preflight_check preflight_entry_chain "$entry"
    done
    for path in /etc/chief/node.env /etc/chief/supervisor-allowlist.json \
                /etc/chief/node-plan.key /etc/chief/node-auth.token /var/log/chief-closure.log; do
        preflight_check preflight_destination "$path"
    done
    for name in hermes-converger chief-node-supervisor chief-update chief-update-request; do
        preflight_check preflight_destination "/opt/chief/bin/$name"
        preflight_check preflight_entry_chain "/opt/chief/bin/$name"
    done
    if [ -f "$STATE/prepared" ]; then
        # Prepared entries take the fast dispatcher path and require these
        # existing files; prospective installation checks alone are insufficient.
        for path in /etc/chief/node.env /var/lib/chief/requests \
                    /opt/chief/bin/hermes-converger /opt/chief/bin/chief-node-supervisor /opt/chief/bin/chief-update \
                    /opt/chief/lib/hermes-host-bootstrap/hermes_converger/step0/trust.sh \
                    /opt/chief/lib/hermes-host-bootstrap/hermes_converger/step0/pulse.sh \
                    /opt/chief/lib/hermes-host-bootstrap/hermes_converger/step0/supervise.sh; do
            preflight_check trusted_path "$path"
            preflight_check preflight_entry_chain "$path"
        done
    fi
    for path in /opt/chief/lib/hermes-host-bootstrap/hermes_converger /var/lib/chief/currency-step0 /var/lib/chief/converger; do
        [ ! -e "$path" ] || preflight_check trusted_tree "$path"
    done
    # Hint files are the intentional group-writable exception, never code/state.
    for hint in login wake network request; do
        path=/var/lib/chief/requests/$hint
        if [ -e "$path" ] || [ -L "$path" ]; then
            preflight_check /bin/sh -c '[ -f "$1" ] && [ ! -L "$1" ]' sh "$path"
        fi
    done
    if [ "$OS" = Darwin ]; then
        preflight_check preflight_destination /var/lib/chief/reconcile.lock
        preflight_check preflight_destination /var/lib/chief/convergence dir
        preflight_check /usr/sbin/sysctl -n kern.bootsessionuuid
        for dir in /Library/LaunchDaemons /Library/LaunchAgents; do preflight_check trusted_path "$dir"; done
        for name in com.chief.node-reconcile com.chief.node-supervisor com.chief.update-request; do
            preflight_check preflight_destination "/Library/LaunchDaemons/$name.plist"
            for suffix in log err; do preflight_check preflight_destination "/var/log/$name.$suffix"; done
        done
        preflight_check preflight_destination /Library/LaunchAgents/com.chief.update-login.plist
    else
        preflight_check trusted_path /run
        preflight_check preflight_destination /run/chief-currency-closure.lock dir
        preflight_check preflight_destination /run/chief dir
        for dir in /etc/systemd/system /etc/systemd /usr/lib/systemd; do preflight_check trusted_path "$dir"; done
        for path in /etc/systemd/user /usr/lib/systemd/system-sleep; do
            preflight_check preflight_destination "$path" dir
        done
        for path in /etc/systemd/user/chief-update-login.service /usr/lib/systemd/system-sleep/chief-update-resume; do
            preflight_check preflight_destination "$path"
        done
        for definition in "$BASE"/systemd/*; do
            unit=${definition##*/}
            preflight_check preflight_destination "/etc/systemd/system/$unit"
            for manager_dir in /etc/systemd/system /run/systemd/system; do
                override=$manager_dir/$unit.d
                if [ -e "$override" ] || [ -L "$override" ]; then
                    preflight_check trusted_path "$manager_dir"
                fi
            done
            # Unit-specific overrides will be archived. Global/type-wide ones
            # survive installation and cause the same hold as closure's check.
            loaded=$(/usr/bin/systemctl show "$unit" --property=LoadState --value) || {
                if [ "$loaded" != not-found ]; then
                    failures=$((failures + 1)); hold "effective_unit_query_failed:$unit" || :
                fi
            }
            [ "$loaded" != not-found ] || continue
            fragment=$(/usr/bin/systemctl show "$unit" --property=FragmentPath --value) || {
                failures=$((failures + 1)); hold "effective_unit_query_failed:$unit" || :; fragment='';
            }
            case "$fragment" in
                ''|/etc/systemd/system/"$unit"|/run/systemd/system/"$unit"|/usr/lib/systemd/system/"$unit"|/lib/systemd/system/"$unit") ;;
                *) failures=$((failures + 1)); hold "effective_unit_override:$unit:$fragment" || :;;
            esac
            drops=$(/usr/bin/systemctl show "$unit" --property=DropInPaths --value) || {
                failures=$((failures + 1)); hold "effective_unit_query_failed:$unit" || :; drops='';
            }
            for drop in $drops; do
                case "$drop" in /etc/systemd/system/"$unit".d/*|/run/systemd/system/"$unit".d/*) ;;
                    *) failures=$((failures + 1)); hold "effective_unit_override:$unit:$drop" || :;; esac
            done
        done
    fi
    if [ "$payload_ok" = yes ]; then
        # shellcheck source=hermes_converger/step0/closure-lock.sh
        . "$BASE/closure-lock.sh"
        preflight_check preflight_lock
    fi
    preflight_check trusted_path /etc/sudoers
    preflight_check trusted_path /etc/sudoers.d
    preflight_check /usr/sbin/visudo -c
    for path in /etc/sudoers /etc/sudoers.d/*; do
        [ -e "$path" ] || continue
        preflight_check trusted_path "$path"
        if /usr/bin/grep -E '^[[:space:]]*([#@]include)' "$path" | /usr/bin/grep -Ev '^[[:space:]]*([#@]includedir)[[:space:]]+(/private)?/etc/sudoers[.]d/?[[:space:]]*$' >/dev/null; then
            failures=$((failures + 1)); hold "nonstandard sudoers include: $path" || :
        fi
    done
    if [ "$payload_ok" = yes ]; then
        # shellcheck source=hermes_converger/step0/configure.sh
        . "$BASE/configure.sh"
        preflight_check configure_node_env --check
        preflight_check preflight_policy
    else
        hold 'payload-dependent checks unavailable: unsafe payload' || :
    fi
    if trusted_python; then
        if [ "$payload_ok" = yes ]; then
            preflight_check "$PY" -I -S -B -c 'import sys; sys.path.append(sys.argv[1]); from hermes_converger.preflight import check; raise SystemExit(check())' "${BASE%/hermes_converger/step0}"
        fi
    else
        failures=$((failures + 1)); hold trusted_python_unavailable || :
    fi
    [ "$failures" = 0 ] || return 1
    printf 'chief Step 0 preflight: PASS (read-only; no closure performed)\n'
}
