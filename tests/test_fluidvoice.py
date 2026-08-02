#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "deploy-fluidvoice-fleet.py"

spec = importlib.util.spec_from_file_location("fluidvoice_rollout", SCRIPT)
assert spec and spec.loader
rollout = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = rollout
spec.loader.exec_module(rollout)


class RolloutTests(unittest.TestCase):
    def test_load_hosts_filters_os_role_and_missing_target(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fixtures = {
                "client.yaml": {"hostname": "client", "os": {"kind": "macos"}, "bootstrap": {"role": "client"}, "ssh_user": "u", "tailscale_ip": "1.1.1.1"},
                "both.yaml": {"hostname": "both", "os": {"kind": "macos"}, "bootstrap": {"role": "both"}, "ssh_user": "v", "ssh_host": "mac"},
                "server.yaml": {"hostname": "server", "os": {"kind": "macos"}, "bootstrap": {"role": "server"}, "ssh_user": "s", "tailscale_ip": "2.2.2.2"},
                "unknown.yaml": {"hostname": "unknown", "os": {"kind": "macos"}, "ssh_user": "x", "tailscale_ip": "3.3.3.3"},
                "linux.yaml": {"hostname": "linux", "os": {"kind": "ubuntu"}, "bootstrap": {"role": "client"}, "ssh_user": "r", "tailscale_ip": "4.4.4.4"},
                "notarget.yaml": {"hostname": "notarget", "os": {"kind": "macos"}, "bootstrap": {"role": "client"}, "ssh_user": "u"},
            }
            for name, data in fixtures.items():
                (root / name).write_text(__import__("yaml").safe_dump(data))
            with mock.patch.object(rollout, "HOSTS_DIR", root):
                self.assertEqual(
                    rollout.load_hosts(),
                    [
                        {"name": "both", "target": "v@mac"},
                        {"name": "client", "target": "u@1.1.1.1"},
                    ],
                )

    def test_converge_classifies_installed_pending_and_error(self) -> None:
        host = {"name": "mac", "target": "u@mac"}
        cases = [
            (mock.Mock(returncode=0, stdout="FLUIDVOICE_OK 1.6.6\n", stderr=""), {"status": "installed", "detail": "1.6.6"}),
            (mock.Mock(returncode=255, stdout="", stderr="timeout"), {"status": "pending", "detail": "sleeping-or-unreachable"}),
            (mock.Mock(returncode=2, stdout="FLUIDVOICE_ERROR bootstrap-repo-missing\n", stderr=""), {"status": "error", "detail": "bootstrap-repo-missing"}),
            (mock.Mock(returncode=1, stdout="", stderr="final failure\n"), {"status": "error", "detail": "final failure"}),
        ]
        for completed, expected in cases:
            with self.subTest(expected=expected), mock.patch.object(rollout.subprocess, "run", return_value=completed):
                self.assertEqual(rollout.converge(host), expected)
        with mock.patch.object(rollout.subprocess, "run", side_effect=rollout.subprocess.TimeoutExpired("ssh", 1)):
            self.assertEqual(rollout.converge(host), {"status": "pending", "detail": "sleeping-or-unreachable"})

    def test_main_is_quiet_when_state_is_unchanged(self) -> None:
        state = {"hosts": {"mac": {"status": "installed", "detail": "1.6.6"}}}
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "state.json"
            path.write_text(json.dumps(state))
            output = io.StringIO()
            with (
                mock.patch.object(rollout, "STATE_PATH", path),
                mock.patch.object(rollout, "load_hosts", return_value=[{"name": "mac", "target": "u@mac"}]),
                mock.patch.object(rollout, "converge", return_value=state["hosts"]["mac"]),
                contextlib.redirect_stdout(output),
            ):
                self.assertEqual(rollout.main(), 0)
            self.assertEqual(output.getvalue(), "")


class MacModuleTests(unittest.TestCase):
    def make_stubs(self, root: Path, *, initial_login_path: str, create_ok: bool = True) -> tuple[Path, Path]:
        bin_dir = root / "bin"
        state_dir = root / "state"
        app = root / "FluidVoice.app"
        (app / "Contents").mkdir(parents=True)
        bin_dir.mkdir(); state_dir.mkdir()
        (state_dir / "login_path").write_text(initial_login_path)
        (state_dir / "show_window").write_text("1")

        def script(name: str, body: str) -> None:
            path = bin_dir / name
            path.write_text("#!/bin/bash\nset -euo pipefail\n" + body)
            path.chmod(path.stat().st_mode | stat.S_IXUSR)

        script("uname", "[[ ${1:-} == -s ]] && echo Darwin || echo arm64\n")
        script("brew", "exit 0\n")
        script("defaults", f'''state={state_dir!s}
printf '%s\\n' "$*" >> "$state/defaults_calls"
if [[ $1 == read && $2 == *Contents/Info ]]; then
  [[ $3 == CFBundleShortVersionString ]] && echo 1.6.6 || echo com.FluidApp.app
elif [[ $1 == write ]]; then
  [[ $3 == ShowMainWindowAtLoginLaunch ]] && echo 0 > "$state/show_window"
elif [[ $1 == read && $2 == com.FluidApp.app && $3 == ShowMainWindowAtLoginLaunch ]]; then
  cat "$state/show_window"
fi
exit 0
''')
        create = "echo \"$APP_PATH\" > \"$STATE/login_path\"" if create_ok else "exit 1"
        script("osascript", f'''STATE={state_dir!s}; APP_PATH={app!s}; args="$*"
printf '%s\\n' "$args" >> "$STATE/osascript_calls"
if grep -q "get path" <<<"$args"; then cat "$STATE/login_path"
elif grep -q "delete login item" <<<"$args"; then : > "$STATE/login_path"
elif grep -q "make login item" <<<"$args"; then {create}
else exit 0
fi
''')
        return bin_dir, app

    def run_module(self, *, initial_login_path: str, create_ok: bool = True) -> tuple[subprocess.CompletedProcess[str], Path]:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        bin_dir, app = self.make_stubs(root, initial_login_path=initial_login_path, create_ok=create_ok)
        env = os.environ.copy()
        env.update({
            "PATH": f"{bin_dir}:/usr/bin:/bin",
            "TIER": "recommended",
            "ROLE": "client",
            "HERMES_SKIP": "",
            "FLUIDVOICE_APP_PATH": str(app),
        })
        result = subprocess.run(["/bin/bash", str(ROOT / "lib/43-fluidvoice.sh")], env=env, text=True, capture_output=True)
        return result, root

    def test_stale_login_item_is_repaired(self) -> None:
        result, root = self.run_module(initial_login_path="/Old/FluidVoice.app")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("repairing stale FluidVoice login item path", result.stdout)
        self.assertEqual((root / "state/login_path").read_text().strip(), str(root / "FluidVoice.app"))
        self.assertEqual((root / "state/show_window").read_text().strip(), "0")

    def test_registration_failure_fails_closed(self) -> None:
        result, _ = self.run_module(initial_login_path="", create_ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not register FluidVoice", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
