"""Module 97's deterministic renderer and narrowly scoped supervisor adapter."""
import os
from pathlib import Path
import plistlib
import re
import subprocess

from .common import atomic_write, digest, existing, rooted

REPO = Path(__file__).resolve().parents[2]
LABEL = 'com.hermes.dashboard-server'


def env_digest(path):
    """Mirror the launcher's owned assignments without evaluating or logging secrets."""
    values = {}
    for line in (existing(path) or b'').splitlines():
        if line.startswith(b'export '):
            line = line[7:]
        key, sep, value = line.partition(b'=')
        if sep and (key.startswith(b'HERMES_DASHBOARD_BASIC_AUTH_') or key == b'HERMES_DASHBOARD_PUBLIC_URL'):
            values[key] = value
    return (digest(b'\0'.join(key + b'=' + values[key] for key in sorted(values))) + '\n').encode()


def command(args):
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL).strip()


def validate_runtime(runtime):
    for key in ('home', 'hermes_home', 'executable'):
        if not re.fullmatch(r'/[A-Za-z0-9_./ -]+', runtime[key]) or '..' in Path(runtime[key]).parts:
            raise ValueError('invalid runtime path')
    for key in ('user', 'group'):
        if not re.fullmatch(r'[a-z_][a-z0-9_-]*', runtime[key]):
            raise ValueError('invalid runtime account')
    if type(runtime['uid']) is not int or runtime['uid'] < 0:
        raise ValueError('invalid runtime uid')


def render(runtime, platform, launcher, service, bind, port):
    validate_runtime(runtime)
    if not re.fullmatch(r'(127\.0\.0\.1|100\.[0-9]+\.[0-9]+\.[0-9]+|tailnet)', bind):
        raise ValueError('only loopback or explicitly declared tailnet binds are supported')
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError('invalid port')
    if not re.fullmatch(r'/[A-Za-z0-9_./ -]+', launcher):
        raise ValueError('invalid launcher path')
    env = {'HOME': runtime['home'], 'HERMES_HOME': runtime['hermes_home'],
           'HERMES_DASHBOARD_EXECUTABLE': runtime['executable'],
           'HERMES_DASHBOARD_BIND': bind, 'HERMES_DASHBOARD_PORT': str(port),
           'PATH': f"{runtime['home']}/.local/bin:/usr/local/bin:/usr/bin:/bin"}
    if platform == 'macos':
        if service != LABEL:
            raise ValueError('unexpected LaunchAgent label')
        unit = plistlib.dumps({'Label': service, 'ProgramArguments': [launcher],
            'EnvironmentVariables': env, 'WorkingDirectory': runtime['home'],
            'RunAtLoad': True, 'KeepAlive': {'SuccessfulExit': False}, 'ThrottleInterval': 10,
            'StandardOutPath': runtime['hermes_home'] + '/logs/dashboard-server.log',
            'StandardErrorPath': runtime['hermes_home'] + '/logs/dashboard-server.err'}, sort_keys=True)
    else:
        if not re.fullmatch(r'[A-Za-z0-9_-]+\.service', service):
            raise ValueError('unexpected systemd dashboard unit')
        # Percent specifiers must not expand paths. Other metacharacters rejected above.
        lines = ['[Unit]', 'Description=Hermes fleet dashboard (auth required)',
                 'After=network-online.target', 'Wants=network-online.target', '', '[Service]',
                 'Type=simple', f"User={runtime['user']}", f"Group={runtime['group']}",
                 f"WorkingDirectory={runtime['home']}", f'ExecStart="{launcher}"']
        lines += [f'Environment="{key}={value}"' for key, value in env.items()]
        lines += ['Restart=always', 'RestartSec=5', '', '[Install]', 'WantedBy=multi-user.target', '']
        unit = '\n'.join(lines).encode()
    return (REPO / 'scripts/hermes-dashboard-server.sh').read_bytes(), unit


class Supervisor:
    def __init__(self, platform, service, unit, uid, run=command):
        self.platform, self.service, self.unit, self.uid, self.run = platform, service, str(unit), uid, run

    def inspect(self):
        if self.platform == 'macos':
            try:
                out = self.run(['launchctl', 'print', f'gui/{self.uid}/{self.service}'])
            except subprocess.CalledProcessError:
                return {'pid': 0, 'path': self.unit, 'loaded': False}
            path = re.search(r'^\s*path = (.+)$', out, re.M)
            pid = re.search(r'^\s*pid = (\d+)$', out, re.M)
            return {'pid': int(pid[1]) if pid else 0, 'path': path[1] if path else '', 'loaded': True}
        out = self.run(['systemctl', 'show', self.service, '--property=MainPID,FragmentPath,LoadState'])
        values = dict(line.split('=', 1) for line in out.splitlines() if '=' in line)
        return {'pid': int(values.get('MainPID', 0)), 'path': values.get('FragmentPath', ''),
                'loaded': values.get('LoadState') == 'loaded'}

    def check(self, port, expected_path=None):
        state = self.inspect()
        if state['loaded'] and state['path'] != (expected_path or self.unit):
            raise ValueError('supervisor owns a different unit path')
        if self.platform == 'macos':
            try:
                out = self.run(['lsof', '-nP', f'-iTCP:{port}', '-sTCP:LISTEN', '-Fp'])
            except subprocess.CalledProcessError as exc:
                if exc.returncode != 1:
                    raise
                out = ''
            pids = [int(line[1:]) for line in out.splitlines() if line.startswith('p')]
            if not pids:
                # lsof can hide another user's process. netstat still establishes
                # listener presence; an unverifiable owner must never be adopted.
                sockets = self.run(['netstat', '-an', '-p', 'tcp'])
                if any(re.search(rf'[.:]{port}\s', line) and 'LISTEN' in line for line in sockets.splitlines()):
                    raise ValueError('occupied socket owner is unverifiable')
        else:
            out = self.run(['ss', '-H', '-ltnp', f'sport = :{port}'])
            pids = [int(pid) for pid in re.findall(r'pid=(\d+)', out)]
            if out and not pids:
                raise ValueError('occupied socket owner is unverifiable')
        for pid in pids:
            if not state['loaded'] or pid != state['pid']:
                raise ValueError('unmanaged occupied socket; refusing to stop or replace it')
        return state

    def check_runtime(self, state, runtime):
        """Verify a running Linux service without logging argv or environment values."""
        if not state['pid']:
            return
        process = Path('/proc') / str(state['pid'])
        status = (process / 'status').read_text()
        uid = re.search(r'^Uid:\s+(\d+)\s+(\d+)', status, re.M)
        if not uid or int(uid[2]) != runtime['uid']:
            raise ValueError('running dashboard UID mismatch')
        env = dict(item.split(b'=', 1) for item in (process / 'environ').read_bytes().split(b'\0') if b'=' in item)
        for key, value in [('HOME', runtime['home']), ('HERMES_HOME', runtime['hermes_home'])]:
            # Older root units omit HERMES_HOME; its documented default is HOME/.hermes.
            actual = env.get(key.encode())
            if key == 'HERMES_HOME' and actual is None:
                actual = env.get(b'HOME', b'') + b'/.hermes'
            if actual != value.encode():
                raise ValueError('running dashboard home mismatch')
        if any(env.get(key) for key in (b'HERMES_DESKTOP', b'HERMES_DASHBOARD_SESSION_TOKEN')):
            raise ValueError('running dashboard has forbidden auth environment')

    def refresh(self, state, unit_changed):
        if self.platform == 'macos':
            if state['loaded']:
                self.run(['launchctl', 'bootout', f'gui/{self.uid}/{self.service}'])
            self.run(['launchctl', 'bootstrap', f'gui/{self.uid}', self.unit])
        else:
            if unit_changed:
                self.run(['systemctl', 'daemon-reload'])
            if not state['loaded']:
                self.run(['systemctl', 'enable', self.service])
            self.run(['systemctl', 'restart' if state['pid'] else 'start', self.service])


def install(root, runtime, platform, launcher, unit, service, bind, port, supervisor):
    launcher_bytes, unit_bytes = render(runtime, platform, launcher, service, bind, port)
    state = supervisor.check(port)
    launcher_path, unit_path = rooted(root, launcher), rooted(root, unit)
    # All ownership/socket checks occur before any mutation.
    existing(launcher_path)
    existing(unit_path)
    stamp_path = rooted(root, (runtime['hermes_home'] + '/.desktop-dashboard' if platform == 'macos'
                              else '/var/lib/hermes-desktop') + '/dashboard-env.sha256')
    auth_digest = env_digest(rooted(root, runtime['hermes_home'] + '/.env'))
    auth_changed = existing(stamp_path) != auth_digest
    launcher_changed = atomic_write(launcher_path, launcher_bytes, 0o755)
    unit_changed = atomic_write(unit_path, unit_bytes)
    if launcher_changed or unit_changed or auth_changed:
        rooted(root, runtime['hermes_home'] + '/logs').mkdir(parents=True, exist_ok=True)
        supervisor.refresh(state, unit_changed)
        # Only acknowledge credentials after refresh succeeds. Failed refreshes retry.
        atomic_write(stamp_path, auth_digest, 0o600)
    return launcher_changed or unit_changed or auth_changed
