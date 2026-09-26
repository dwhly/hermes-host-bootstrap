#!/usr/bin/env python3
"""Apply a reviewed per-file dashboard plan, never bootstrap a preserved node.

Plan schema/example: tests/fixtures/desktop-gateway-plan.json. --root is a fixture
filesystem: it requires recorded identity/supervisor facts and NEVER invokes a
service command. The normal root checks live, read-only supervisor facts first.
--dashboard-env accepts a host-local, already projected file; no credential
resolver runs here and neither its contents nor hashes are printed.
"""
import argparse
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys

from desktop_fleet.common import (atomic_write, digest, existing, host_record, json_bytes,
                                  load, rooted, update_policy)
from desktop_fleet import dashboard, marker

AUTH_KEYS = {'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD', 'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH',
             'HERMES_DASHBOARD_BASIC_AUTH_SECRET', 'HERMES_DASHBOARD_BASIC_AUTH_USERNAME',
             'HERMES_DASHBOARD_PUBLIC_URL'}


def project_env(old, fields):
    """Replace only exact owned assignments. Retain unrelated bytes and line endings."""
    remaining = dict(fields)
    seen = set()
    output = []
    for line in (old or b'').splitlines(keepends=True):
        match = re.match(rb'(?:export[ \t]+)?([A-Z_]+)=', line)
        key = match[1].decode() if match else None
        if key in fields:
            if key in seen:
                raise ValueError('duplicate dashboard assignment')
            seen.add(key)
            ending = b'\r\n' if line.endswith(b'\r\n') else b'\n' if line.endswith(b'\n') else b''
            line = key.encode() + b'=' + remaining.pop(key).encode() + ending
        output.append(line)
    result = b''.join(output)
    if remaining and result and not result.endswith(b'\n'):
        result += b'\n'
    return result + b''.join(k.encode() + b'=' + v.encode() + b'\n' for k, v in sorted(remaining.items()))


def runtime_check(root, plan):
    runtime = plan['runtime']
    dashboard.validate_runtime(runtime)
    fixture = root != Path('/')
    hostname = rooted(root, '/etc/hostname').read_text().strip() if fixture else socket.gethostname().split('.')[0]
    if hostname != plan['host']:
        raise ValueError('host identity mismatch')
    accounts = rooted(root, '/etc/passwd').read_text().splitlines()
    found = [line.split(':') for line in accounts if line.split(':')[0] == runtime['user']]
    groups = [line.split(':') for line in rooted(root, '/etc/group').read_text().splitlines()
              if line.split(':')[0] == runtime['group']]
    if (len(found) != 1 or len(groups) != 1 or int(found[0][2]) != runtime['uid']
            or found[0][5] != runtime['home'] or found[0][3] != groups[0][2]):
        raise ValueError('runtime account, UID, group or HOME mismatch')
    executable = rooted(root, runtime['executable'])
    if digest(executable.read_bytes()) != runtime['executable_sha256'] or not os.access(executable, os.X_OK):
        raise ValueError('runtime executable differs from qualified build')
    if not rooted(root, runtime['hermes_home']).is_dir():
        raise ValueError('existing HERMES_HOME is required')
    return fixture, int(groups[0][2])


def prepare(root, plan, registry, fields):
    if plan['schema'] != 1:
        raise ValueError('unsupported apply schema')
    record = host_record(registry, plan['host'])
    if update_policy(record) != 'protected':
        raise ValueError('preserved-node vehicle requires protected Intent')
    if record.get('desktop_gateway', {}).get('runtime') != plan['runtime']:
        raise ValueError('runtime differs from registry Intent')
    fixture, gid = runtime_check(root, plan)
    runtime = plan['runtime']
    service = plan['supervisor']['service']
    unit = '/etc/systemd/system/' + service
    if plan['supervisor']['kind'] != 'systemd':
        raise ValueError('unqualified supervisor: a reviewed adapter is required')
    launcher = '/usr/local/bin/hermes-dashboard-server'
    if plan['bind'] != '127.0.0.1':
        raise ValueError('preserved-node gateway requires declared loopback ingress')
    launcher_data, unit_data = dashboard.render(runtime, 'linux', launcher, service, plan['bind'], plan['port'])
    supervisor = dashboard.Supervisor('linux', service, unit, runtime['uid'])
    if fixture:
        state = load(rooted(root, '/run/desktop-gateway-supervisor.json'))
        if state['service'] != service or (state['loaded'] and state['path'] != unit):
            raise ValueError('supervisor ownership mismatch')
        if state['pid'] and state.get('runtime') != runtime:
            raise ValueError('observed runtime mismatch')
        if any(pid != state['pid'] or not state['loaded'] for pid in state['listener_pids']):
            raise ValueError('unmanaged occupied socket')
    else:
        state = supervisor.check(plan['port'])
        supervisor.check_runtime(state, runtime)
    env = runtime['hermes_home'] + '/.env'
    prior = plan['prior_sha256']
    targets = {launcher: (launcher_data, 0o755), unit: (unit_data, 0o644)}
    if fields:
        targets[env] = (project_env(existing(rooted(root, env)), fields), 0o600)
    # Preserve any existing marker, byte for byte. Only install a missing marker.
    if not rooted(root, marker.MARKER).exists():
        targets[marker.MARKER] = (marker.render(plan['host']), 0o644)
    changes = []
    for name, (data, mode) in targets.items():
        path = rooted(root, name)
        old = existing(path)
        # No-op replay takes precedence over the *original* prior hash.
        if old != data and (name not in prior or (digest(old) if old is not None else None) != prior[name]):
            raise ValueError('prior file hash mismatch: ' + name)
        metadata_change = old is not None and path.stat().st_mode & 0o777 != mode
        if old != data or metadata_change:
            changes.append((name, old, data, mode))
    return changes, supervisor, state, fixture, gid


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--plan-file', required=True)
    p.add_argument('--registry', required=True)
    p.add_argument('--dashboard-env', help='host-local projected dashboard assignments; never printed')
    p.add_argument('--plan', action='store_true', help='read-only: print exact file and service actions')
    p.add_argument('--root', default='/', help='fixture root; service calls disabled when not /')
    a = p.parse_args()
    root = Path(a.root).absolute()
    plan = load(a.plan_file)
    fields = plan.get('dashboard_fields', {})
    if set(fields) - {'HERMES_DASHBOARD_PUBLIC_URL'}:
        raise ValueError('only public URL belongs in the reviewed plan')
    if a.dashboard_env:
        for line in Path(a.dashboard_env).read_text().splitlines():
            if not line or line.startswith('#'):
                continue
            key, value = line.split('=', 1)
            if key not in AUTH_KEYS:
                raise ValueError('projection contains an unowned variable')
            fields[key] = value
    if any(not isinstance(v, str) or any(c in v for c in '\r\n\0') for v in fields.values()):
        raise ValueError('dashboard values must be single-line strings')
    changes, supervisor, state, fixture, gid = prepare(root, plan, a.registry, fields)
    backup_dir = '/var/backups/hermes-desktop/' + digest(Path(a.plan_file).read_bytes())[:16]
    service_changed = any(name != marker.MARKER for name, *_ in changes)
    actions = []
    for name, old, _, _ in changes:
        if old is not None:
            actions.append({'action': 'backup', 'path': name, 'to': backup_dir + name})
        actions.append({'action': 'replace' if old is not None else 'create', 'path': name})
    if service_changed:
        if any(name == supervisor.unit for name, *_ in changes):
            actions.append({'action': 'daemon-reload', 'service': supervisor.service})
        actions += [{'action': 'enable', 'service': supervisor.service},
                    {'action': 'restart' if state['pid'] else 'start', 'service': supervisor.service}]
    # Preflight all backup conflicts before any file writes. Never replace a prior backup.
    for name, old, _, _ in changes:
        backup = rooted(root, backup_dir + name)
        if old is not None and existing(backup) not in (None, old):
            raise ValueError('backup conflict; select a fresh reviewed plan')
    print(json.dumps({'host': plan['host'], 'changes': actions, 'noop': not changes}, sort_keys=True))
    if a.plan or not changes:
        return
    for name, old, _, _ in changes:
        if old is not None:
            backup = rooted(root, backup_dir + name)
            atomic_write(backup, old, 0o600)
    for name, _, data, mode in changes:
        owner = None if fixture else ((plan['runtime']['uid'], gid) if name.endswith('/.env') else (0, 0))
        atomic_write(rooted(root, name), data, mode, owner=owner)
    # Per-file atomicity, not a filesystem transaction. Backups survive a refresh failure.
    if service_changed and not fixture:
        supervisor.refresh(state, any(name == supervisor.unit for name, *_ in changes))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, ImportError, subprocess.SubprocessError):
        sys.exit('desktop-gateway-apply: preflight/apply failed; files may need recovery if apply began; no secret values logged')
