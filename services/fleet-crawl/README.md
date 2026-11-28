# fleet-crawl — fleet common service (PROTOTYPE, live on h-do1 since 2026-11-28)

Shared crawl/search relay for `web_search` / `web_extract`. Nodes hold no vendor key; they set
`FLEETCRAWL_API_URL` (hermes-config `.env.template`) plus one vendor adapter line. h-do1 adds the key.

- Live: `/srv/fleet-crawl/` + `/etc/systemd/system/fleet-crawl.service`, listening 127.0.0.1:3991,
  published tailnet-only: `tailscale serve --bg --https=3990 http://127.0.0.1:3991`.
- Key: `op://hermes/Firecrawl - Service and key/API key`, read into the process env at start (never on disk).
- Request log (per node, no bodies): `/var/log/fleet-crawl/requests.tsv`.
- Swap vendor: change `FLEETCRAWL_UPSTREAM` + key ref (or add a translation layer); nodes unchanged.
- Rollback: `systemctl disable --now fleet-crawl; tailscale serve --https=3990 off`.

TODO (gated build): bootstrap module with host-identity gate (boss only), log rotation, tests, review.
