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
        while [ ! -e "$destination" ]; do destination=${destination%/*}; done
        [ -d "$destination" ] || { hold "not a destination directory: $destination"; return 1; }
    elif [ "${2:-}" = dir ]; then
        [ -d "$destination" ] || { hold "not a destination directory: $destination"; return 1; }
    fi
    [ -d "$destination" ] || [ -f "$destination" ] || { hold "not a regular file/directory: $destination"; return 1; }
    trusted_path "$destination"
}

preflight_policy() {
    # Flatten the supported include tree and run the SAME rule renderer as
    # removal, entirely through pipes. visudo -c -f - never stages a file.
    policy=$(
        for file in /etc/sudoers /etc/sudoers.d/*; do
            [ -f "$file" ] || continue
            /usr/bin/awk -f "$BASE/sudoers.awk" "$file" || exit 1
        done
    ) || return 1
    printf '%s\n' "$policy" | /usr/bin/sed '/^[[:space:]]*[#@]includedir[[:space:]]/d' |
        /usr/sbin/visudo -c -f -
}

preflight_lock() {
    if [ "$OS" = Darwin ]; then
        lock=/var/lib/chief/chief-currency-closure.lock
        current_boot=$(/usr/sbin/sysctl -n kern.boottime) || return 1
    else
        lock=/run/chief-currency-closure.lock
        current_boot=$(/bin/cat /proc/sys/kernel/random/boot_id) || return 1
    fi
    [ -n "$current_boot" ] || { hold missing_boot_identity; return 1; }
    preflight_destination "$lock" || return 1
    [ -d "$lock" ] || return 0
    trusted_tree "$lock" || return 1
    holder=0 holder_boot=''
    [ ! -f "$lock/pid" ] || read -r holder < "$lock/pid" || holder=0
    [ ! -f "$lock/boot" ] || IFS= read -r holder_boot < "$lock/boot" || holder_boot=''
    case "$holder" in ''|*[!0-9]*) holder=0;; esac
    if { [ "$holder_boot" = "$current_boot" ] || [ -z "$holder_boot" ]; } &&
       [ "$holder" != 0 ] && kill -0 "$holder" 2>/dev/null; then
        hold closure_already_running; return 1
    fi
}

closure_preflight() {
    failures=0
    preflight_check /bin/sh -c '[ "$(/usr/bin/id -u)" = 0 ]'
    payload_ok=yes
    trusted_tree "$BASE/.." || { failures=$((failures + 1)); payload_ok=no; }
    for dir in /var/log /etc /var; do preflight_check trusted_path "$dir"; done
    for dir in /opt/chief/bin /opt/chief/lib/hermes-host-bootstrap /var/lib/chief/currency-step0 \
               /var/lib/chief/converger /var/lib/chief/requests /etc/chief; do
        preflight_check preflight_destination "$dir" dir
    done
    for path in /etc/chief/node.env /etc/chief/supervisor-allowlist.json \
                /etc/chief/node-plan.key /etc/chief/node-auth.token /var/log/chief-closure.log; do
        preflight_check preflight_destination "$path"
    done
    for name in hermes-converger chief-node-supervisor chief-update chief-update-request; do
        preflight_check preflight_destination "/opt/chief/bin/$name"
    done
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
        preflight_check preflight_destination /var/lib/chief/chief-currency-closure.lock
        preflight_check preflight_destination /var/lib/chief/runtime
        preflight_check preflight_destination /var/lib/chief/reconcile.lock
        preflight_check preflight_destination /var/lib/chief/convergence
        preflight_check /usr/sbin/sysctl -n kern.boottime
        for dir in /Library/LaunchDaemons /Library/LaunchAgents; do preflight_check trusted_path "$dir"; done
        for name in com.chief.node-reconcile com.chief.node-supervisor com.chief.update-request; do
            preflight_check preflight_destination "/Library/LaunchDaemons/$name.plist"
            for suffix in log err; do preflight_check preflight_destination "/var/log/$name.$suffix"; done
        done
        preflight_check preflight_destination /Library/LaunchAgents/com.chief.update-login.plist
    else
        preflight_check trusted_path /run
        preflight_check preflight_destination /run/chief-currency-closure.lock
        preflight_check preflight_destination /run/chief
        for dir in /etc/systemd/system /etc/systemd /usr/lib/systemd; do preflight_check trusted_path "$dir"; done
        for path in /etc/systemd/user /usr/lib/systemd/system-sleep \
                    /etc/systemd/user/chief-update-login.service /usr/lib/systemd/system-sleep/chief-update-resume; do
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
    preflight_check preflight_lock
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
