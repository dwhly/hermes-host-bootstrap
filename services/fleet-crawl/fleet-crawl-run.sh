#!/bin/bash
# fleet-crawl launcher (PROTOTYPE): read the upstream key from the fleet 1Password vault into this
# process's environment only, then exec the relay. Nothing secret is written to disk.
set -euo pipefail
# shellcheck disable=SC1090
eval "$(grep -E '^(export )?OP_SERVICE_ACCOUNT_TOKEN=' /root/.hermes-bootstrap.conf)"
export OP_SERVICE_ACCOUNT_TOKEN
. /srv/fleet-crawl/fleet-crawl.conf          # non-secret settings (upstream URL, vault ref, listen)
FLEETCRAWL_UPSTREAM_KEY=$(op read "$FLEETCRAWL_KEY_REF")
unset OP_SERVICE_ACCOUNT_TOKEN
export FLEETCRAWL_UPSTREAM FLEETCRAWL_UPSTREAM_KEY FLEETCRAWL_LISTEN FLEETCRAWL_LOG
exec /usr/bin/python3 /srv/fleet-crawl/fleet-crawl-relay.py
