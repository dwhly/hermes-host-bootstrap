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
import re
import socket
import struct
import sys
import time
import urllib.parse

log = logging.getLogger("fleet-egress")
CONNECT_TIMEOUT = 10.0
HEADER_TIMEOUT = 15.0       # whole request head (line + headers) must arrive within this
HEADER_MAX_BYTES = 16384    # and fit in this many bytes
IDLE_TIMEOUT = 300.0        # an established tunnel with no traffic either way for this long is closed
MAX_CONNECTIONS = 256       # concurrent client connections; beyond this => 503
DEFAULT_PORTS = [443]       # per-policy "ports" overrides; CONNECT to anything else => 403
# Strict DNS hostname (no IP literals, no control chars/NUL, no empty labels). The canonical, validated
# name is what is forwarded upstream — never the raw client bytes (SOCKS5 servers such as OpenSSH
# truncate at NUL, so "127.0.0.1\0.youtube.com" would otherwise reach the tunnel host's loopback).
_LABEL = r"(?!-)[a-z0-9-]{1,63}(?<!-)"
_HOST_RE = re.compile(rf"^(?=.{{1,253}}$){_LABEL}(?:\.{_LABEL})+$")


def canonical_host(raw: str) -> str | None:
    h = raw.strip().lower().rstrip(".")
    if not _HOST_RE.fullmatch(h) or re.fullmatch(r"[0-9.]+", h):
        return None
    if h.rsplit(".", 1)[-1].isdigit():  # numeric TLD => IP-ish, refuse
        return None
    return h


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

    def reserve(self) -> float | None:
        """Atomically (no await in between) check the shared cap window and take a slot."""
        if self.over_cap():
            return None
        t = time.time(); self.recent.append(t)
        return t

    def refund(self, t: float) -> None:
        try:
            self.recent.remove(t)  # failed attempts don't consume the scarce budget
        except ValueError:
            pass

    def prune(self) -> None:
        now = time.time()
        self.recent[:] = [t for t in self.recent if now - t < 3600]  # in place: list is shared per ip_group

    def over_cap(self) -> bool:
        self.prune()
        now = time.time()
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
        self.busy = 0
        self.sem = asyncio.Semaphore(MAX_CONNECTIONS)

    def policy_for(self, host: str):
        host = host.lower().rstrip(".")
        for pol in self.policies:
            for suf in pol["match"]:
                suf = suf.lower().lstrip(".")
                if host == suf or host.endswith("." + suf):
                    return pol
        return None

    async def handle(self, reader, writer):
        if self.sem.locked():
            self.busy += 1
            writer.write(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            try:
                await writer.drain()
            finally:
                writer.close()
            return
        async with self.sem:
            await self._handle(reader, writer)

    @staticmethod
    async def _read_head(reader) -> bytes:
        head = b""
        while True:
            line = await reader.readline()
            head += line
            if len(head) > HEADER_MAX_BYTES:
                raise ValueError("request head too large")
            if line in (b"\r\n", b"\n", b""):
                return head

    async def _handle(self, reader, writer):
        peer = writer.get_extra_info("peername") or ("?",)
        try:
            head = await asyncio.wait_for(self._read_head(reader), HEADER_TIMEOUT)
            parts = head.split(b"\n", 1)[0].decode(errors="replace").split()
            if len(parts) < 2:
                return
            method, target = parts[0].upper(), parts[1]
            if method != "CONNECT":
                body = json.dumps(self.status(), indent=2) if target.startswith("/status") else \
                    "fleet-egress: only CONNECT (https) is proxied; GET /status for health\n"
                code = "200 OK" if target.startswith("/status") else "405 Method Not Allowed"
                writer.write(f"HTTP/1.1 {code}\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n{body}".encode())
                await writer.drain(); return
            raw_host, _, raw_port = target.rpartition(":")
            host = canonical_host(raw_host)
            port = int(raw_port) if raw_port.isdigit() else -1
            pol = self.policy_for(host) if host else None
            if pol is None or port not in pol.get("ports", DEFAULT_PORTS):
                self.rejected += 1
                log.info("REJECT %s %r:%s (%s)", peer[0], raw_host[:80], raw_port[:8],
                         "bad host" if host is None else "no policy" if pol is None else "port")
                writer.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n"); await writer.drain(); return
            up = None
            for rn in pol["routes"]:
                route = self.routes[rn]
                if time.time() < route.down_until:
                    continue
                slot = route.reserve() if any(route.caps.values()) else 0.0
                if slot is None:
                    route.capped += 1
                    log.info("route %s over rate cap, skipping for %s", rn, host)
                    continue
                try:
                    up = await asyncio.wait_for(route.open(host, port), CONNECT_TIMEOUT)
                    route.ok += 1; route.last_ok_at = time.time()
                    if not slot:
                        route.prune(); route.recent.append(time.time())  # uncapped: usage stats only, bounded to 1h
                    log.info("OK %s %s:%s via %s [%s]", peer[0], host, port, rn, pol["name"])
                    break
                except Exception as e:  # try next route
                    if slot:
                        route.refund(slot)
                    route.fail += 1; route.last_error = f"{type(e).__name__}: {e}"[:200]
                    route.down_until = time.time() + 30
                    log.warning("route %s failed for %s: %s", rn, host, route.last_error)
            if up is None:
                writer.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"); await writer.drain(); return
            writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n"); await writer.drain()
            ur, uw = up
            await _tunnel(reader, writer, ur, uw)
        except Exception as e:
            log.debug("conn error %s: %s", peer, e)
        finally:
            writer.close()

    def status(self) -> dict:
        return {"service": "fleet-egress", "uptime_s": int(time.time() - self.started), "rejected": self.rejected,
                "busy_rejected": self.busy,
                "policies": [{"name": p["name"], "match": p["match"], "routes": p["routes"]} for p in self.policies],
                "routes": {n: r.status() for n, r in self.routes.items()}}


async def _tunnel(cr, cw, ur, uw, idle=None, tick=None):
    """Splice client<->upstream. One watchdog owns expiry: when NEITHER direction has moved bytes for
    `idle` seconds (a blocked write that never drains counts as no progress), both pumps are cancelled
    and both transports aborted, so a stalled peer can never pin a connection slot."""
    idle = IDLE_TIMEOUT if idle is None else idle
    tick = min(30.0, idle / 4) if tick is None else tick
    act = [time.monotonic()]

    async def pump(r, w):
        while data := await r.read(65536):
            w.write(data)
            await w.drain()          # may block on a non-reading peer; the watchdog bounds it
            act[0] = time.monotonic()

    tasks = [asyncio.ensure_future(pump(cr, uw)), asyncio.ensure_future(pump(ur, cw))]
    graceful = False
    try:
        while True:
            done, _ = await asyncio.wait(tasks, timeout=tick, return_when=asyncio.FIRST_COMPLETED)
            if done:  # one side reached EOF (graceful) or errored (abort)
                graceful = all(not t.cancelled() and t.exception() is None for t in done)
                break
            if time.monotonic() - act[0] > idle:
                log.debug("tunnel idle > %ss, closing", idle)
                break
    finally:
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await asyncio.gather(*(_close(w, graceful, idle) for w in (uw, cw)), return_exceptions=True)


async def _close(w, graceful: bool, flush_deadline: float) -> None:
    """Graceful EOF: close() so already-queued bytes are flushed, bounded by a deadline (a peer that
    stops reading can't hold us). Idle expiry / errors: abort() immediately."""
    tr = getattr(w, "transport", None)
    try:
        if graceful:
            w.close()
            try:
                await asyncio.wait_for(w.wait_closed(), flush_deadline)
                return
            except Exception:
                pass
        if tr is not None:
            tr.abort()
        else:
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
