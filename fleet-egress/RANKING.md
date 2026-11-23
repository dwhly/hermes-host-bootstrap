# fleet-egress vendor ranking (2026-11-22)

Analyst-judgement scores (1–5) weighted into /100; computed in code. Weights: yt 25, general 20, cost 15, friction 10, fit 10, nocap 5, trust 10, evidence 5.
Keys: yt = YouTube transcript reliability from cloud; general = other bot-walled sites; cost = at ~1–3k transcripts/mo; friction = account/KYC/billing; fit = works for ANY tool via the gateway; nocap = captionless fallback; trust = maturity/ethics; evidence = proof quality (our test / maintainer > vendor claim).
Gates: usable by an individual; vendor operating. Policy: Dan's home IP is a last-resort reserve, never primary.

| # | Option | Type | Score | YT | Gen | Cost | Friction | Fit | NoCap | Trust | Evid | Entry cost / notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Webshare Residential | proxy pool | 92 | 5 | 5 | 5 | 4 | 5 | 1 | 4 | 5 | $3.50/mo for 1 GB (~2-3k transcripts); monthly, no rollover |
| 2 | Decodo Residential | proxy pool | 85 | 4 | 5 | 5 | 4 | 5 | 1 | 4 | 3 | $4 PAYG for 1 GB; Google targets explicitly allowed |
| 3 | IPRoyal Residential | proxy pool | 78 | 4 | 5 | 3 | 5 | 5 | 1 | 3 | 2 | $7.35 for 1 GB, never expires |
| 4 | Evomi Core Residential | proxy pool | 72 | 3 | 4 | 5 | 4 | 5 | 1 | 3 | 1 | $14.85 min (15 GB PAYG, never expires) |
| 5 | Oxylabs Residential | proxy pool | 72 | 3 | 5 | 3 | 3 | 5 | 1 | 5 | 1 | $15/mo; 'some Google domains' restricted |
| 6 | Oxylabs Web Scraper API | scraper API | 72 | 4 | 5 | 3 | 3 | 2 | 1 | 5 | 2 | $15/mo prepaid; youtube_transcript source |
| 7 | Home IP via Minis (reserve) | own egress | 72 | 3 | 3 | 5 | 5 | 5 | 1 | 2 | 5 | free; ONE IP, throttled after ~50 fetches; household impact |
| 8 | ScrapingBee | scraper API | 71 | 4 | 4 | 4 | 4 | 2 | 1 | 4 | 2 | 1,000 free; $19/mo; dedicated YouTube subtitles endpoint |
| 9 | Bright Data Unlocker + YT dataset | scraper API | 70 | 4 | 5 | 3 | 2 | 2 | 1 | 5 | 2 | 5k free/mo; $1.50/1k; KYC may apply |
| 10 | Apify transcript actors | transcript API | 68 | 3 | 4 | 4 | 4 | 2 | 2 | 4 | 3 | $5/mo free usage; actors ~$1-10/1k; quality varies |
| 11 | Firecrawl | scraper API | 68 | 2 | 4 | 4 | 5 | 2 | 2 | 5 | 4 | 1,000 free/mo, no card; Hobby $19/mo 5k pages |
| 12 | Supadata | transcript API | 66 | 4 | 3 | 3 | 4 | 2 | 5 | 3 | 2 | 100 free/mo; $17/mo for 3,000; AI transcribe 2 cr/min |
| 13 | Rayobyte Residential | proxy pool | 65 | 3 | 4 | 4 | 1 | 5 | 1 | 4 | 1 | $3.50/GB but passport KYC first |
| 14 | Scrapfly | scraper API | 62 | 3 | 4 | 3 | 4 | 2 | 1 | 4 | 1 | 1,000 free/mo; $30/mo |
| 15 | YTAPI | transcript API | 60 | 4 | 1 | 5 | 5 | 2 | 1 | 2 | 2 | 200 free; $9 for 2,000, never expire; failures free |
| 16 | PacketStream | proxy pool | 59 | 3 | 3 | 4 | 3 | 4 | 1 | 2 | 1 | $50 min at $1/GB; proxyware sourcing |
| 17 | TranscriptAPI | transcript API | 58 | 4 | 1 | 5 | 4 | 2 | 1 | 2 | 2 | 100 free; $5/mo for 1,000 |
| 18 | ScrapeCreators | transcript API | 58 | 3 | 3 | 4 | 4 | 2 | 1 | 2 | 2 | 100 free; $47 pack, never expire; many social sites |
| 19 | Zyte API | scraper API | 57 | 2 | 4 | 3 | 3 | 2 | 1 | 5 | 1 | $5 credit; PAYG per site tier |
| 20 | ScraperAPI | scraper API | 57 | 2 | 4 | 3 | 4 | 2 | 1 | 4 | 1 | 1,000 free/mo; $49/mo |
| 21 | Jina Reader | scraper API | 48 | 1 | 1 | 4 | 5 | 2 | 1 | 4 | 4 | 10M free tokens; our test: no transcript, Reddit 403 |
| ✗ | Bright Data Residential | proxy pool | GATE FAIL: KYC: registered companies only | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | $499/mo |
| ✗ | NetNut | proxy pool | GATE FAIL: domains seized by FBI Jul 2026 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | — |

## Hands-on evidence
- Our test: datacenter IPs 0% (youtube-transcript-api, yt-dlp); home IP 100% until throttled at ~50 fetches/15 min.
- Firecrawl keyless, n=2: TED talk full transcript (no timestamps); 3Blue1Brown no transcript (page chrome only). h-af refused keyless as 'VPN/proxy IP'.
- Jina Reader: no transcript; Reddit 403.
- Bandwidth per transcript ≈ 0.3–0.5 MB (maintainer measured ~260–280 KB) → ~2–3k transcripts/GB → ~$0.001–0.002 each at $3.50/GB.

Raw research: subagent reports deleg_120156df (hosted transcript APIs, residential proxies, scraper APIs).
