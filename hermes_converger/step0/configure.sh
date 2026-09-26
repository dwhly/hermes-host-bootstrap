#!/bin/sh
# Config repair must work even when Python is unavailable and jobs stay held.
# Called inside the sanitized closure after validating the whole payload tree.
configure_node_env() {
    host=$(/bin/hostname)
    old_id='' old_core=''
    if [ -e /etc/chief/node.env ] || [ -L /etc/chief/node.env ]; then
        trusted_path /etc/chief/node.env || return 1
        old_id=$(/usr/bin/sed -n 's/^CHIEF_NODE_ID=//p' /etc/chief/node.env)
        old_core=$(/usr/bin/sed -n 's/^CHIEF_CORE_URL=//p' /etc/chief/node.env)
        [ -n "$old_id" ] && [ -n "$old_core" ] || { hold missing_node_identity_or_core; return 1; }
    fi
    selected=''
    for record in "$BASE"/hosts/*.env; do
        id='' fqdn=''
        while IFS='=' read -r key value; do
            case "$key" in CHIEF_NODE_ID) id=$value;; REGISTRY_FQDN) fqdn=$value;; esac
        done < "$record"
        if [ "${host%%.*}" = "$id" ] || [ "${host%%.*}" = "${fqdn%%.*}" ]; then selected=$record; break; fi
    done
    if [ -z "$selected" ]; then
        case "$old_id" in h-[a-z0-9]*)
            case "$old_id" in *[!a-z0-9-]*) ;; *)
                [ ! -f "$BASE/hosts/$old_id.env" ] || selected=$BASE/hosts/$old_id.env;; esac;; esac
    fi
    [ -n "$selected" ] || { hold host_not_in_trusted_registry; return 1; }
    id='' core='' runtime_user=''
    while IFS='=' read -r key value; do
        case "$key" in CHIEF_NODE_ID) id=$value;; CHIEF_CORE_URL) core=$value;; CHIEF_RUNTIME_USER) runtime_user=$value;; esac
    done < "$selected"
    if [ -e /etc/chief/node.env ]; then
        # Never rewrite owner config on preserved hosts, even when invalid.
        # Accept only the established grammar; comments and bytes are retained.
        /usr/bin/awk -F= '
            /^#/ || /^$/ { next }
            NF != 2 || seen[$1]++ { exit 1 }
            $1 !~ /^(CHIEF_NODE_ID|CHIEF_CORE_URL|CHIEF_NODE_PLAN_KEY|CHIEF_NODE_AUTH_TOKEN|CHIEF_RUNTIME_USER)$/ { exit 1 }
        ' /etc/chief/node.env || { hold unexpected_node_config; return 1; }
        [ "$old_id" = "$id" ] || { hold node_identity_conflicts_with_registry; return 1; }
        core=$old_core
        for pair in CHIEF_NODE_PLAN_KEY=/etc/chief/node-plan.key CHIEF_NODE_AUTH_TOKEN=/etc/chief/node-auth.token "CHIEF_RUNTIME_USER=$runtime_user"; do
            key=${pair%%=*}
            actual=$(/usr/bin/sed -n "s/^$key=//p" /etc/chief/node.env)
            [ -z "$actual" ] || [ "$key=$actual" = "$pair" ] || { hold unexpected_node_config_value; return 1; }
        done
    fi
    printf '%s\n' "$core" | /usr/bin/grep -Eq '^https?://[a-zA-Z0-9.-]+(:[0-9]+)?/?$' || { hold invalid_core_url; return 1; }
    case "$id:$core" in h-do1:*) ;; *://127.0.0.1*|*://localhost*|*://0.0.0.0*) hold loopback_core_on_remote_node; return 1;; esac
    /usr/bin/id -u "$runtime_user" >/dev/null || { hold registry_runtime_user_missing; return 1; }
    [ ! -e /etc/chief/node.env ] || return 0
    # Preserved owner files are never seeded or repaired by foundation closure.
    case "$id" in h-af|h-btp) hold preserved_node_config_missing; return 1;; esac
    tmp=$(/usr/bin/mktemp /etc/chief/.node-env.XXXXXX)
    {
        printf 'CHIEF_NODE_ID=%s\nCHIEF_CORE_URL=%s\n' "$id" "$core"
        printf 'CHIEF_NODE_PLAN_KEY=/etc/chief/node-plan.key\nCHIEF_NODE_AUTH_TOKEN=/etc/chief/node-auth.token\n'
        printf 'CHIEF_RUNTIME_USER=%s\n' "$runtime_user"
    } > "$tmp"
    /usr/sbin/chown root:chief "$tmp" 2>/dev/null || /bin/chown root:chief "$tmp"
    /bin/chmod 0640 "$tmp"
    /bin/mv -f "$tmp" /etc/chief/node.env
}
