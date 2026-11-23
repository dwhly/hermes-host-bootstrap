# fleet-egress

**Residential / unblocked egress as a fleet service.** Some sites (YouTube first; also
Reddit, LinkedIn, Amazon, ticketing, many SaaS login walls) bot-wall or refuse datacenter
IPs. Our cloud hosts (h-do1, h-af, h-btp — DigitalOcean) get `RequestBlocked` / "Sign in to
confirm you're not a bot"; residential hosts (the home Minis) do not. fleet-egress lets any
tool on any tailnet host egress "as a residential client" by setting one env var.

```
any fleet host ──HTTPS_PROXY──▶ fleet-egress gateway (h-do1 100.122.202.37:3128, tailnet only)
                                   │ policy: domain allowlist → ordered routes, rate caps
                                   ├─▶ paid-residential (Webshare Rotating Residential, 1 GB/mo) PRIMARY
                                   ├─▶ home-h-mini2  (ssh -D tunnel, Dan's home IP) LAST-RESORT, 2/min 10/hr
                                   ├─▶ home-h-mini   (same home IP — shared cap group)
                                   └─▶ 403 for non-allowlisted hosts (not an open proxy)
```

## Measured 2026-11-22 (characterization)
| Host | Egress | youtube-transcript-api |
|---|---|---|
| h-mini2, h-mini | residential (same home IP) | ✅ 4/4 |
| h-do1, h-af, h-btp | DigitalOcean | ❌ 100% RequestBlocked/IpBlocked (h-do1 gets 1 lucky request) |
| h-do1 via gateway → h-mini2 | residential | ✅ 7/7 |
| home IP after ~50 fetches / 15 min | residential | ❌ IpBlocked (429) — throttled, household-wide |

**Lesson:** a single home IP is a *small, fragile* budget, not a solution. Hence the rate caps
(`per_minute`/`per_hour`, shared by `ip_group`), client-side caching, and a pooled fallback.

## Strategy catalog (YouTube transcripts — and the general class)
| # | Strategy | Cost | Reliability from cloud | Notes |
|---|---|---|---|---|
| 1 | Direct from a residential host | free | n/a (only residential) | works until per-IP throttle |
| 2 | **Own residential egress** (this gateway → home Macs) | free | good at low volume | one IP; capped; Macs must be up |
| 3 | **Rotating residential proxy pool** (Webshare Residential, IPRoyal, Decodo, Bright Data, Oxylabs) | ~$1–7/GB (~$0.15–1.40 per 1k transcripts) | high (maintainer-recommended) | plugs into gateway as `paid-residential` → *general* for every site |
| 4 | **Hosted transcript API** (Supadata, TranscriptAPI, YTAPI, Transkrio, sum.video, Apify actors) | free tiers 100–200; ~$1–5 per 1k | high | YouTube-specific; Supadata adds AI transcription when no captions |
| 5 | Hosted scraper (Firecrawl, ScrapingBee, Zyte, ScraperAPI) | credit-based | high | *general* for web pages; Firecrawl YouTube = page markdown / audio |
| 6 | Audio download + Whisper (yt-dlp via 2/3 → local whisper / AssemblyAI) | compute or ~$0.15/hr | high | only path for videos with no captions |
| 7 | Cookies of a logged-in account | free | medium | **NOT recommended** — YouTube bans the account |
| ✗ | Datacenter proxies / Webshare free tier / static residential | cheap | blocked | don't buy these |

## Components (all in hermes-host-bootstrap — the single source of truth)
- `fleet-egress/fleet_egress_gateway.py` — stdlib-only asyncio CONNECT proxy; JSON config; `GET /status`.
- `fleet-egress/config.json` — policies (domain allowlist) + ordered routes; `${ENV}` routes auto-disable
  when the secret is unset. Installed to `/etc/fleet-egress/config.json`.
- `fleet-egress/systemd/*.service` — gateway + `fleet-egress-tunnel@<host>` (ssh -D home reserve).
- `fleet-egress/tunnels/<host>.env` — non-secret tunnel targets (ssh target + local SOCKS port).
- `scripts/fleet-egress` — `fleet-egress run -- <cmd>` / `status` / `url` (general consumer).
- `scripts/fleet-yt-transcript` — cache → egress → yt-dlp (via egress) → Supadata (`SUPADATA_API_KEY`); `direct` (this host's own IP) is opt-in only via `FLEET_YT_STRATEGIES` (home-IP policy).
- `lib/72-fleet-egress.sh` — installs the client on every host; on the boss (owns 100.122.202.37) also
  the gateway, tunnels, and `/etc/fleet-egress/secrets.env` rebuilt from 1Password
  (`op://hermes/Webshare/proxy_username` + `-rotate`, `proxy_password`; kept as-is if op is unavailable).
- Preserved hosts (h-af, h-btp): `scripts/fleet-enroll-existing <host> <ip> fleet-egress-client`.

## Operating
- Install / re-assert: `./bootstrap.sh --only=72-fleet-egress` (any host).
- Health: `fleet-egress status` (routes, ok/fail, home-reserve use in the last hour).
- Add a blocked site: add its domain to a policy in `fleet-egress/config.json`, commit, re-run the module
  on the boss. Never allowlist `google.com` (CAPTCHA redirects must fail so the client retries a new IP).
- Rotate the pool credential: change it in Webshare, update the 1Password item, re-run the module.

## Status
LIVE (2026-11-23). Policy (product owner): the home IP is a last-resort reserve, never primary.
Webshare Rotating Residential (1 GB/mo, auto-renewing): 55-video benchmark via the gateway = 51/55
first pass, 55/55 after client fixes (retry on CAPTCHA-redirect ProxyError; dash-leading ids); 0 home
use. The same Webshare login exits DATACENTER IPs when no Residential plan is active — verify ASNs
(`curl -x <url> https://ipinfo.io/org`) after any plan change.
