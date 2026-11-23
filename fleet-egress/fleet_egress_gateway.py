#!/usr/bin/env python3
"""fleet-egress gateway — allowlisting HTTP CONNECT proxy with ordered upstream routes.

Problem class: some sites (YouTube, Reddit, LinkedIn, Amazon, ...) refuse or bot-wall
requests from datacenter IPs. Cloud fleet hosts need to reach them "as a residential
client". This gateway lets ANY tool on ANY tailnet host do that by setting
HTTPS_PROXY=http://<gateway>:3128 — no per-tool integration.

Routing: a request's host is matched against policies (domain suffix lists). Each policy
names an ordered list of routes; the gateway tries them in order until one connects.
Hosts matching no policy are rejected (403) — this is NOT an open proxy.

Route types:
  socks5  {"addr": "127.0.0.1:1081"}                      e.g. an `ssh -D` tunnel to a home Mac
  http    {"url": "http://user:pass@p.webshare.io:80"}    e.g. a paid rotating-residential pool
  direct  {}                                              connect from the gateway host itself

Stdlib only (Python 3.9+). GET /status (non-proxy request) returns JSON route health/counters.
"""
from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import socket
import struct
import sys
import time
import urllib.parse

log = logging.getLogger("fleet-egress")
CONNECT_TIMEOUT = 10.0


class Route:
    def __init__(self, name: str, spec: dict):
        self.name, self.type = name, spec["type"]
        self.spec = spec
        self.ok = self.fail = 0
        self.last_error: str | None = None
        self.last_ok_at: float | None = None
        self.down_until = 0.0  # simple circuit breaker
        # rate caps protect scarce egress (a single home IP gets throttled by YouTube at ~50
        # fetches/15min — measured 2026-11-22). Over cap => route skipped, next route tried.
        self.caps = {60: spec.get("per_minute"), 3600: spec.get("per_hour")}
        self.recent: list[float] = []
        self.capped = 0

    def over_cap(self) -> bool:
        now = time.time()
        self.recent[:] = [t for t in self.recent if now - t < 3600]  # in place: list is shared per ip_group
        return any(lim is not None and sum(1 for t in self.recent if now - t < win) >= lim
                   for win, lim in self.caps.items())

    async def open(self, host: str, port: int):
        if self.type == "direct":
            return await asyncio.open_connection(host, port)
        if self.type == "socks5":
            h, p = self.spec["addr"].rsplit(":", 1)
            r, w = await asyncio.open_connection(h, int(p))
            w.write(b"\x05\x01\x00"); await w.drain()
            if (await r.readexactly(2)) != b"\x05\x00":
                raise OSError("socks5: auth negotiation refused")
            hb = host.encode()
            w.write(b"\x05\x01\x00\x03" + bytes([len(hb)]) + hb + struct.pack(">H", port)); await w.drain()
            rep = await r.readexactly(4)
            if rep[1] != 0:
                raise OSError(f"socks5: connect failed code={rep[1]}")
            atyp = rep[3]
            n = 4 if atyp == 1 else 16 if atyp == 4 else (await r.readexactly(1))[0]
            await r.readexactly(n + 2)
            return r, w
        if self.type == "http":
            u = urllib.parse.urlsplit(self.spec["url"])
            r, w = await asyncio.open_connection(u.hostname, u.port or 80)
            hdr = f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n"
            if u.username:
                cred = f"{urllib.parse.unquote(u.username)}:{urllib.parse.unquote(u.password or '')}"
                hdr += "Proxy-Authorization: Basic " + base64.b64encode(cred.encode()).decode() + "\r\n"
            w.write((hdr + "\r\n").encode()); await w.drain()
            status = await r.readline()
            if b" 200" not in status:
                raise OSError(f"upstream http proxy: {status.decode(errors='replace').strip()}")
            while (await r.readline()) not in (b"\r\n", b"\n", b""):
                pass
            return r, w
        raise ValueError(f"unknown route type {self.type}")

    def status(self) -> dict:
        return {"type": self.type, "ok": self.ok, "fail": self.fail, "capped": self.capped,
                "caps": {"per_minute": self.caps[60], "per_hour": self.caps[3600]},
                "used_last_hour": len([t for t in self.recent if time.time() - t < 3600]),
                "last_error": self.last_error,
                "last_ok_at": self.last_ok_at, "circuit_open": time.time() < self.down_until}


class Gateway:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.routes = {n: Route(n, s) for n, s in cfg["routes"].items()}
        groups: dict[str, list] = {}  # routes sharing a public IP share one rate-cap window
        for n, r in self.routes.items():
            r.recent = groups.setdefault(r.spec.get("ip_group", n), [])
        self.policies = cfg["policies"]
        self.started = time.time()
        self.rejected = 0

    def policy_for(self, host: str):
        host = host.lower().rstrip(".")
        for pol in self.policies:
            for suf in pol["match"]:
                suf = suf.lower().lstrip(".")
                if host == suf or host.endswith("." + suf):
                    return pol
        return None

    async def handle(self, reader, writer):
        peer = writer.get_extra_info("peername")
        try:
            line = await asyncio.wait_for(reader.readline(), 15)
            parts = line.decode(errors="replace").split()
            while (await reader.readline()) not in (b"\r\n", b"\n", b""):
                pass
            if len(parts) < 2:
                return
            method, target = parts[0].upper(), parts[1]
            if method != "CONNECT":
                body = json.dumps(self.status(), indent=2) if target.startswith("/status") else \
                    "fleet-egress: only CONNECT (https) is proxied; GET /status for health\n"
                code = "200 OK" if target.startswith("/status") else "405 Method Not Allowed"
                writer.write(f"HTTP/1.1 {code}\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n{body}".encode())
                await writer.drain(); return
            host, _, port = target.rpartition(":")
            host, port = host.strip("[]"), int(port or 443)
            pol = self.policy_for(host)
            if pol is None:
                self.rejected += 1
                log.info("REJECT %s %s:%s (no policy)", peer[0], host, port)
                writer.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n"); await writer.drain(); return
            up = None
            for rn in pol["routes"]:
                route = self.routes[rn]
                if time.time() < route.down_until:
                    continue
                if route.over_cap():
                    route.capped += 1
                    log.info("route %s over rate cap, skipping for %s", rn, host)
                    continue
                try:
                    up = await asyncio.wait_for(route.open(host, port), CONNECT_TIMEOUT)
                    route.ok += 1; route.last_ok_at = time.time(); route.recent.append(time.time())
                    log.info("OK %s %s:%s via %s [%s]", peer[0], host, port, rn, pol["name"])
                    break
                except Exception as e:  # try next route
                    route.fail += 1; route.last_error = f"{type(e).__name__}: {e}"[:200]
                    route.down_until = time.time() + 30
                    log.warning("route %s failed for %s: %s", rn, host, route.last_error)
            if up is None:
                writer.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"); await writer.drain(); return
            writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n"); await writer.drain()
            ur, uw = up
            await asyncio.gather(_pipe(reader, uw), _pipe(ur, writer))
        except Exception as e:
            log.debug("conn error %s: %s", peer, e)
        finally:
            writer.close()

    def status(self) -> dict:
        return {"service": "fleet-egress", "uptime_s": int(time.time() - self.started), "rejected": self.rejected,
                "policies": [{"name": p["name"], "match": p["match"], "routes": p["routes"]} for p in self.policies],
                "routes": {n: r.status() for n, r in self.routes.items()}}


async def _pipe(r, w):
    try:
        while data := await r.read(65536):
            w.write(data); await w.drain()
    except Exception:
        pass
    finally:
        try:
            w.close()
        except Exception:
            pass


def _expand_env(obj):
    if isinstance(obj, str):
        return os.path.expandvars(obj)
    if isinstance(obj, dict):
        return {k: _expand_env(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_expand_env(v) for v in obj]
    return obj


async def main(cfg_path: str):
    cfg = json.load(open(cfg_path))
    # routes whose spec references an unset ${ENV} are dropped (e.g. paid pool not purchased yet)
    cfg["routes"] = {n: s for n, s in _expand_env(cfg["routes"]).items() if "${" not in json.dumps(s)}
    for p in cfg["policies"]:
        p["routes"] = [r for r in p["routes"] if r in cfg["routes"]]
    gw = Gateway(cfg)
    servers = []
    for addr in cfg["listen"]:
        h, p = addr.rsplit(":", 1)
        servers.append(await asyncio.start_server(gw.handle, h, int(p), reuse_address=True))
        log.info("listening on %s", addr)
    log.info("routes: %s", list(gw.routes))
    await asyncio.gather(*(s.serve_forever() for s in servers))


if __name__ == "__main__":
    logging.basicConfig(level=os.environ.get("FLEET_EGRESS_LOG", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
    asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else "/etc/fleet-egress/config.json"))
