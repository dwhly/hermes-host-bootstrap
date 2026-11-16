"""hermes-testcap: argv matcher and size parsing (the parts that decide what gets capped)."""
import importlib.machinery
import importlib.util
from pathlib import Path

import pytest

_P = Path(__file__).resolve().parents[1] / "scripts" / "hermes-testcap"
_L = importlib.machinery.SourceFileLoader("hermes_testcap", str(_P))
_S = importlib.util.spec_from_loader("hermes_testcap", _L)
tc = importlib.util.module_from_spec(_S)
_L.exec_module(tc)


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
