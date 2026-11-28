#!/usr/bin/env python3
"""fleet-crawl relay (PROTOTYPE) — the fleet's shared crawl/search service, hosted on h-do1.

Fleet nodes call this instead of a vendor: they hold NO vendor key. The relay forwards the
vendor-compatible API (today: Firecrawl's /v1, /v2 REST paths) to FLEETCRAWL_UPSTREAM and adds the
fleet key itself. Swapping vendors later = change the upstream + key here (or put a translation
layer here); nodes keep pointing at FLEETCRAWL_API_URL.

Env (set by fleet-crawl-run.sh; the key is never written to disk by this service):
  FLEETCRAWL_UPSTREAM      e.g. https://api.firecrawl.dev   (the ONLY vendor-specific setting)
  FLEETCRAWL_UPSTREAM_KEY  upstream API key (read from 1Password at start)
  FLEETCRAWL_LISTEN        127.0.0.1:3990  (published tailnet-only via `tailscale serve`)
  FLEETCRAWL_LOG           /var/log/fleet-crawl/requests.tsv
"""
import json, os, subprocess, sys, threading, time, urllib.error, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("FLEETCRAWL_UPSTREAM", "").rstrip("/")
KEY = os.environ.pop("FLEETCRAWL_UPSTREAM_KEY", "")
HOST, _, PORT = os.environ.get("FLEETCRAWL_LISTEN", "127.0.0.1:3990").rpartition(":")
LOG = os.environ.get("FLEETCRAWL_LOG", "/var/log/fleet-crawl/requests.tsv")
ALLOWED_PREFIXES = ("/v1/", "/v2/")
MAX_BODY = 4 * 1024 * 1024
if not UPSTREAM or not KEY:
    sys.exit("fleet-crawl: FLEETCRAWL_UPSTREAM and FLEETCRAWL_UPSTREAM_KEY are required")

_names, _names_at, _lock = {}, 0.0, threading.Lock()


def node_name(ip: str) -> str:
    """Tailnet IP -> host name, refreshed from `tailscale status --json` at most every 10 min."""
    global _names, _names_at
    with _lock:
        if time.time() - _names_at > 600:
            try:
                st = json.loads(subprocess.run(["tailscale", "status", "--json"], capture_output=True,
                                               text=True, timeout=10).stdout)
                peers = list((st.get("Peer") or {}).values()) + [st.get("Self") or {}]
                # DNSName's first label is the fleet host name (h-mini2); HostName can be "Dan’s Mac mini".
                _names = {a: (p.get("DNSName") or "").split(".")[0] or p.get("HostName", "?")
                          for p in peers for a in p.get("TailscaleIPs") or []}
            except Exception:
                pass
            _names_at = time.time()
        return _names.get(ip, ip or "?")


def log_line(*cols):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a") as f:
            f.write("\t".join(str(c) for c in cols) + "\n")
    except OSError:
        pass


class Relay(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "fleet-crawl/0.1"

    def log_message(self, *a):  # quiet stderr; we keep our own TSV
        pass

    def _send(self, code, body: bytes, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _relay(self):
        t0 = time.time()
        client_ip = (self.headers.get("X-Forwarded-For") or self.client_address[0]).split(",")[0].strip()
        node = node_name(client_ip)
        path = self.path
        if path in ("/healthz", "/fleet/healthz"):
            return self._send(200, b'{"ok":true,"service":"fleet-crawl"}')
        if not path.startswith(ALLOWED_PREFIXES):
            log_line(time.strftime("%F %T"), node, self.command, path[:120], 404, 0, 0)
            return self._send(404, b'{"error":"fleet-crawl: unsupported path"}')
        n = int(self.headers.get("Content-Length") or 0)
        if n > MAX_BODY:
            return self._send(413, b'{"error":"fleet-crawl: request too large"}')
        body = self.rfile.read(n) if n else None
        req = urllib.request.Request(UPSTREAM + path, data=body, method=self.command)
        req.add_header("Authorization", f"Bearer {KEY}")  # caller's Authorization (if any) is discarded
        req.add_header("Content-Type", self.headers.get("Content-Type") or "application/json")
        safe = "".join(c if c.isascii() and (c.isalnum() or c in "-_.") else "_" for c in node)[:40]
        req.add_header("User-Agent", f"fleet-crawl/0.1 (node={safe})")
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                code, data, ctype = r.status, r.read(), r.headers.get("Content-Type", "application/json")
        except urllib.error.HTTPError as e:
            code, data, ctype = e.code, e.read(), e.headers.get("Content-Type", "application/json")
        except Exception as e:
            print(f"fleet-crawl upstream error from {node}: {type(e).__name__}: {str(e)[:160]}", flush=True)
            code, data, ctype = 502, json.dumps({"error": f"fleet-crawl upstream: {type(e).__name__}"}).encode(), "application/json"
        log_line(time.strftime("%F %T"), node, self.command, path.split("?")[0][:120], code, len(data),
                 int((time.time() - t0) * 1000))
        self._send(code, data, ctype)

    do_GET = do_POST = do_PUT = do_DELETE = _relay


if __name__ == "__main__":
    srv = ThreadingHTTPServer((HOST, int(PORT)), Relay)
    print(f"fleet-crawl listening on {HOST}:{PORT} -> upstream configured", flush=True)
    srv.serve_forever()
