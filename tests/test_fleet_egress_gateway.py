"""fleet-egress gateway regression tests (stdlib unittest; runs under pytest too).

Covers the review findings: allowlist bypass via malformed hostnames (NUL / IP literals), port
restriction, shared home-IP cap under concurrency (reserve before await, refund on failure), and
bounded request heads (size + deadline).
"""
import asyncio
import importlib.util
import pathlib
import unittest

_P = pathlib.Path(__file__).resolve().parents[1] / "fleet-egress" / "fleet_egress_gateway.py"
_spec = importlib.util.spec_from_file_location("fleet_egress_gateway", _P)
gw = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gw)

CFG = {
    "listen": [],
    "routes": {
        "home-a": {"type": "socks5", "addr": "127.0.0.1:1", "ip_group": "home", "per_minute": 2, "per_hour": 10},
        "home-b": {"type": "socks5", "addr": "127.0.0.1:2", "ip_group": "home", "per_minute": 2, "per_hour": 10},
    },
    "policies": [{"name": "yt", "match": ["youtube.com"], "routes": ["home-a", "home-b"]}],
}


class FakeWriter:
    def __init__(self):
        self.buf = b""
        self.closed = False

    def write(self, b):
        self.buf += b

    async def drain(self):
        pass

    def close(self):
        self.closed = True

    def get_extra_info(self, _):
        return ("100.64.0.1", 1)


def reader_for(data: bytes, eof=True):
    r = asyncio.StreamReader()
    r.feed_data(data)
    if eof:
        r.feed_eof()
    return r


class CanonicalHost(unittest.TestCase):
    def test_accepts_normal_names(self):
        self.assertEqual(gw.canonical_host("WWW.YouTube.com."), "www.youtube.com")

    def test_rejects_bypasses(self):
        for bad in ["127.0.0.1\x00.youtube.com", "127.0.0.1", "10.0.0.1.youtube.com.1", "a..youtube.com",
                    "-a.youtube.com", "a b.youtube.com", "youtube.com\r\nX: y", "[::1]", "x" * 300 + ".youtube.com",
                    "youtube", ""]:
            self.assertIsNone(gw.canonical_host(bad), repr(bad))


class Handle(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.g = gw.Gateway({k: (dict(v) if isinstance(v, dict) else v) for k, v in CFG.items()})
        self.opened = []

    async def _run(self, req: bytes):
        w = FakeWriter()
        await self.g.handle(reader_for(req), w)
        return w.buf

    async def test_nul_bypass_rejected_and_never_forwarded(self):
        async def boom(host, port):
            self.opened.append(host)
            raise AssertionError("must not open")
        for r in self.g.routes.values():
            r.open = boom
        out = await self._run(b"CONNECT 127.0.0.1\x00.youtube.com:443 HTTP/1.1\r\n\r\n")
        self.assertIn(b"403", out)
        self.assertEqual(self.opened, [])

    async def test_port_restricted(self):
        out = await self._run(b"CONNECT www.youtube.com:22 HTTP/1.1\r\n\r\n")
        self.assertIn(b"403", out)

    async def test_unlisted_host_rejected(self):
        out = await self._run(b"CONNECT example.com:443 HTTP/1.1\r\n\r\n")
        self.assertIn(b"403", out)

    async def test_concurrent_requests_respect_shared_cap(self):
        async def slow_open(host, port):
            self.opened.append(host)
            await asyncio.sleep(0.05)
            return reader_for(b""), FakeWriter()
        for r in self.g.routes.values():
            r.open = slow_open
        reqs = [self._run(b"CONNECT www.youtube.com:443 HTTP/1.1\r\n\r\n") for _ in range(20)]
        outs = await asyncio.gather(*reqs)
        self.assertEqual(len(self.opened), 2, "shared ip_group cap is 2/min across both routes")
        self.assertEqual(sum(b"200 Connection" in o for o in outs), 2)
        self.assertEqual(sum(b"502" in o for o in outs), 18)

    async def test_failed_attempts_are_refunded(self):
        async def fail_open(host, port):
            raise OSError("down")
        self.g.routes["home-a"].open = fail_open
        self.g.routes["home-b"].open = fail_open
        await self._run(b"CONNECT www.youtube.com:443 HTTP/1.1\r\n\r\n")
        self.assertEqual(len(self.g.routes["home-a"].recent), 0)

    async def test_oversized_head_dropped(self):
        req = b"CONNECT www.youtube.com:443 HTTP/1.1\r\n" + b"X: " + b"a" * (gw.HEADER_MAX_BYTES + 10) + b"\r\n\r\n"
        out = await self._run(req)
        self.assertNotIn(b"200", out)

    async def test_slow_head_times_out(self):
        old = gw.HEADER_TIMEOUT
        gw.HEADER_TIMEOUT = 0.1
        try:
            w = FakeWriter()
            await asyncio.wait_for(self.g.handle(reader_for(b"CONNECT www.youtube.com:443 HTTP/1.1\r\n", eof=False), w), 2)
            self.assertTrue(w.closed)
            self.assertNotIn(b"200", w.buf)
        finally:
            gw.HEADER_TIMEOUT = old


if __name__ == "__main__":
    unittest.main()
