"""hermes-testcap: argv matcher and size parsing (the parts that decide what gets capped)."""
import importlib.machinery
import os
import importlib.util
from pathlib import Path

import pytest

_P = Path(__file__).resolve().parents[1] / "scripts" / "hermes-testcap"
_L = importlib.machinery.SourceFileLoader("hermes_testcap", str(_P))
_S = importlib.util.spec_from_loader("hermes_testcap", _L)
tc = importlib.util.module_from_spec(_S)
_L.exec_module(tc)
tc.LOG = os.devnull  # never write test events into the live log


@pytest.mark.parametrize("argv", [
    ["/usr/local/lib/hermes-agent/venv/bin/python", "-m", "pytest", "-q", "-x"],
    ["python3.12", "-mpytest"],
    ["/root/work/board-venv/bin/python", "-u", "-m", "pytest", "tests"],
    ["/venv/bin/python", "/venv/bin/pytest", "-q"],
    ["pytest", "-q"],
    ["/root/.local/bin/py.test"],
    ["node", "/repo/node_modules/.bin/vitest", "run"],
    ["node", "/repo/node_modules/vitest/vitest.mjs", "run"],
    ["node", "/repo/node_modules/jest/bin/jest.js"],
    ["node", "/repo/node_modules/@playwright/test/cli.js", "test"],
    ["/repo/node_modules/.bin/playwright", "test", "--project=chromium"],
    ["cargo", "test", "--workspace"],
    ["/usr/local/go/bin/go", "test", "./..."],
    ["python3", "-X", "importtime", "-m", "pytest"],
    ["node", "--max-old-space-size=4096", "/repo/node_modules/.bin/vitest", "run"],
    ["node", "-r", "ts-node/register", "/repo/node_modules/jest/bin/jest.js"],
    ["/repo/node_modules/.bin/vitest", "run"],
    ["python3", "-Bm", "pytest"],
    ["python3", "-um", "pytest", "-q"],
    ["python3", "-mpytest"],
    ["python3", "-Ximporttime", "-m", "pytest"],
    ["python3", "--", "/venv/bin/pytest"],
    ["node", "--require=ts-node/register", "/repo/node_modules/.bin/jest"],
    ["node", "--", "/repo/node_modules/.bin/vitest"],
])
def test_matches_test_runners(argv):
    assert tc.is_test_runner(argv)


@pytest.mark.parametrize("argv", [
    [],
    ["bash", "-c", "cd x && python -m pytest -q"],   # the shell itself; its pytest child is matched instead
    ["grep", "pytest", "log.txt"],
    ["python3", "-m", "http.server", "8765"],
    ["python3", "/usr/local/bin/hermes-testcap"],
    ["python", "script.py", "pytest"],
    ["node", "server.js", "test"],
    ["/repo/node_modules/.bin/playwright", "install"],
    ["node", "/x/cli.js", "test"],                    # a cli.js that is not playwright
    ["cargo", "build"],
    ["go", "build", "./..."],
    ["vim", "test_foo.py"],
    ["vim", "jest"],                                  # Codex r1: argument named like a runner
    ["grep", "vitest", "log.txt"],
    ["node", "server.js", "jest"],
    ["node", "server.js", "vitest"],
    ["python3", "-c", "import pytest"],
    ["python3", "-m", "pip", "install", "pytest"],
    ["node", "-e", "require('jest')"],
    ["less", "/repo/node_modules/.bin/playwright"],
    ["python3", "-c'print(1)'", "pytest"],            # Codex r2: attached inline code
    ["python3", "-cprint(1)", "pytest"],
    ["python3", "-uc", "print(1)", "pytest"],
    ["python3", "-", "pytest"],                       # program from stdin
    ["python3", "-m", "pip", "pytest"],
    ["node", "--eval=0", "jest"],
    ["node", "--print=1", "vitest"],
    ["node", "-pe", "1", "jest"],
    ["node", "-", "jest"],
])
def test_ignores_everything_else(argv):
    assert not tc.is_test_runner(argv)


def test_parse_size():
    assert tc.parse_size("6G") == 6 << 30
    assert tc.parse_size("512M") == 512 << 20
    assert tc.parse_size("1.5G") == int(1.5 * (1 << 30))
    assert tc.parse_size("4096") == 4096


def test_in_testcap():
    assert tc.in_testcap("/testcap.slice/testcap-12.scope")
    assert not tc.in_testcap("/user.slice/user-0.slice/session-c1.scope")
    assert not tc.in_testcap(None)


def test_scope_properties_one_entry_per_property_for_many_pids():
    """Codex r1 BLOCKER: the property count must not grow with the number of processes."""
    props = tc.scope_properties([11, 12, 13, 14], ["pytest"])
    names = [n for n, _, _ in props]
    assert names == ["PIDFDs", "Slice", "MemoryMax", "MemorySwapMax", "CollectMode", "Description"]
    assert props[0] == ("PIDFDs", "ah", [11, 12, 13, 14])
    assert dict((n, v) for n, _, v in props)["MemoryMax"] == 6 << 30


def test_migrator_submit_never_blocks_and_dedupes():
    """Codex r2: a stalled systemd must not block the scan. submit() only queues; the stalled call runs on the
    migrator thread."""
    import threading
    import time as _t
    gate = threading.Event()

    class Stalled:
        def StartTransientUnit(self, *a, **k):
            gate.wait(5)

    m = tc.Migrator(mgr_factory=Stalled)
    me = os.getpid()
    ident = tc.read_stat(me)[1]
    t0 = _t.monotonic()
    first = m.submit("testcap-x.scope", [(me, ident)], ["pytest"], "capped")
    again = m.submit("testcap-x.scope", [(me, ident)], ["pytest"], "capped")
    assert _t.monotonic() - t0 < 0.2
    assert first is True
    gate.set()
    assert again in (False, True)  # deduped while in flight (False) unless the first already finished


def test_pin_rejects_changed_identity():
    me = os.getpid()
    assert tc.pin(me, -1) is None  # wrong starttime: never pinned
