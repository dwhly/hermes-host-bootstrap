#!/usr/bin/env python3
"""Exercise the sourced guard in real shells, using a harmless tmux function."""
import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
GUARD = Path(os.environ.get("AUTOATTACH_GUARD", ROOT / "dotfiles/tmux-autoattach.sh"))


class AutoattachTest(unittest.TestCase):
    def check_guard(self, extra, expected, interactive=True):
        shells = [("bash", ["--noprofile", "--norc"]), ("zsh", ["-f"])]
        for name, flags in shells:
            binary = shutil.which(name)
            if not binary:
                continue
            with self.subTest(shell=name, env=extra, interactive=interactive):
                env = os.environ.copy()
                for key in ("TMUX", "NO_TMUX", "HERDR_ENV", "HERDR_PANE_ID", "SSH_CONNECTION", "SSH_TTY"):
                    env.pop(key, None)
                env.update(extra)
                env["GUARD"] = str(GUARD)
                command = 'tmux() { printf "TMUX_CALLED:%s\\n" "$*"; }; . "$GUARD"; printf "GUARD_DONE\\n"'
                result = subprocess.run(
                    [binary, *flags, "-ic" if interactive else "-c", command],
                    env=env, text=True, capture_output=True, timeout=5,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("GUARD_DONE", result.stdout)
                self.assertEqual("TMUX_CALLED:attach -t main" in result.stdout, expected, result.stdout)

    def test_plain_interactive_ssh_attaches(self):
        self.check_guard({"SSH_CONNECTION": "client 1 server 22"}, True)

    def test_ssh_tty_only_attaches(self):
        self.check_guard({"SSH_TTY": "/dev/pts/test"}, True)

    def test_restored_herdr_pane_skips_without_no_tmux(self):
        self.check_guard({"SSH_CONNECTION": "client 1 server 22", "HERDR_PANE_ID": "w6:p1"}, False)

    def test_herdr_marker_alone_skips(self):
        self.check_guard({"SSH_TTY": "/dev/pts/test", "HERDR_ENV": "1"}, False)

    def test_empty_herdr_markers_do_not_disable_normal_ssh(self):
        self.check_guard({"SSH_TTY": "/dev/pts/test", "HERDR_ENV": "", "HERDR_PANE_ID": ""}, True)

    def test_nonherdr_marker_does_not_disable_normal_ssh(self):
        self.check_guard({"SSH_TTY": "/dev/pts/test", "HERDR_ENV": "0"}, True)

    def test_existing_tmux_skips(self):
        self.check_guard({"SSH_CONNECTION": "client 1 server 22", "TMUX": "socket,1,0"}, False)

    def test_explicit_opt_out_skips(self):
        self.check_guard({"SSH_CONNECTION": "client 1 server 22", "NO_TMUX": "1"}, False)

    def test_local_shell_skips(self):
        self.check_guard({}, False)

    def test_noninteractive_ssh_skips(self):
        self.check_guard({"SSH_CONNECTION": "client 1 server 22"}, False, interactive=False)


if __name__ == "__main__":
    unittest.main(verbosity=2)
