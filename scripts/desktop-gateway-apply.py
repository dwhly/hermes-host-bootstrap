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
import stat
import subprocess
import sys

from desktop_fleet.common import (admission, atomic_write, digest, existing, gateway_record, host_record,
                                  json_bytes, load, rooted, update_policy)
from desktop_fleet import dashboard, marker

AUTH_KEYS = {'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD', 'HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH',
             'HERMES_DASHBOARD_BASIC_AUTH_SECRET', 'HERMES_DASHBOARD_BASIC_AUTH_USERNAME',
             'HERMES_DASHBOARD_PUBLIC_URL'}


def metadata(path):
    info = path.stat()
    return {'mode': stat.S_IMODE(info.st_mode), 'uid': info.st_uid, 'gid': info.st_gid}


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


def verify_projected_env(path, fields):
    """Catch stale writers after replacement/refresh without exposing assignments."""
    observed = {key: [] for key in fields}
    for line in path.read_bytes().splitlines():
        match = re.fullmatch(rb'(?:export[ \t]+)?([A-Z_]+)=(.*)', line)
        if match and match[1].decode() in observed:
            observed[match[1].decode()].append(match[2])
    if any(observed[key] != [value.encode()] for key, value in fields.items()):
        raise ValueError('post-apply dashboard assignments missing, duplicated, or changed')


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
    # Declare the resolved executable in BOTH plan and Intent. An entry-point
    # script alone does not identify its installed package, so pin RECORD too.
    build = runtime['build_identity']
    if build['kind'] != 'dist-info-record' or not re.search(r'\.dist-info/RECORD$', build['path']):
        raise ValueError('qualified installed-package RECORD is required')
    if digest(rooted(root, build['path']).read_bytes()) != build['sha256']:
        raise ValueError('runtime installed build identity mismatch')
    if not rooted(root, runtime['hermes_home']).is_dir():
        raise ValueError('existing HERMES_HOME is required')
    return fixture, int(groups[0][2])


class ApplyHeld(ValueError):
    """Safe-to-report admission/vehicle refusal, without projected values."""


def authorize(plan, registry, qualify=False):
    record = host_record(registry, plan['host'])
    if update_policy(record) != 'protected':
        raise ValueError('preserved-node vehicle requires protected Intent')
    if gateway_record(record).get('dashboard_vehicle') != 'preserved-node':
        raise ApplyHeld('dashboard_vehicle must be preserved-node; refusing apply')
    state = admission(record)
    if state == 'deferred' or (state == 'pending-qualification' and not qualify):
        raise ApplyHeld('dashboard held: admission ' + state +
                        ('; explicit --qualify required' if state == 'pending-qualification' else '; no apply allowed'))
    # prior_sha256 is the reviewed set of possible file replacements. A deferred
    # plan must omit the marker, including stale plans prepared while armed.
    if marker.deferred(record) and marker.MARKER in plan['prior_sha256']:
        marker.guard(record, 'planned marker change')
    if gateway_record(record).get('runtime') != plan['runtime']:
        raise ValueError('runtime differs from registry Intent')
    return record


def prepare(root, plan, registry, fields, qualify=False):
    if plan['schema'] != 1 or set(plan) - {'schema', 'host', 'runtime', 'supervisor', 'bind', 'port',
                                         'dashboard_fields', 'prior_sha256'}:
        raise ValueError('unsupported apply schema or fields')
    record = authorize(plan, registry, qualify)
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
        env_path = rooted(root, env)
        old_env = existing(env_path)
        targets[env] = (project_env(old_env, fields), metadata(env_path)['mode'] if old_env is not None else 0o600)
    # Preserve any existing marker, byte for byte. Only install a missing marker.
    if not marker.deferred(record) and not rooted(root, marker.MARKER).exists():
        marker.guard(record, 'create')
        targets[marker.MARKER] = (marker.render(plan['host']), 0o644)
    changes = []
    for name, (data, mode) in targets.items():
        path = rooted(root, name)
        old = existing(path)
        info = metadata(path) if old is not None else None
        owner = None if fixture or (name == env and old is not None) else (
            (runtime['uid'], gid) if name == env else (0, 0))
        metadata_change = info is not None and (info['mode'] != mode or
                          (owner is not None and (info['uid'], info['gid']) != owner))
        # No-op replay takes precedence over the *original* prior hash.
        if old != data or metadata_change:
            if name not in prior or (digest(old) if old is not None else None) != prior[name]:
                raise ValueError('prior file hash mismatch: ' + name)
            changes.append((name, old, data, mode, owner, info))
    return changes, supervisor, state, fixture, gid


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--plan-file', required=True)
    p.add_argument('--registry', required=True)
    p.add_argument('--dashboard-env', help='host-local projected dashboard assignments; never printed')
    p.add_argument('--plan', action='store_true', help='read-only: print exact file and service actions')
    p.add_argument('--qualify', action='store_true',
                   help='explicitly allow pending-qualification service setup for stage-5 checks; never deferred admission')
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
    changes, supervisor, state, fixture, gid = prepare(root, plan, a.registry, fields, a.qualify)
    backup_dir = '/var/backups/hermes-desktop/' + digest(Path(a.plan_file).read_bytes())[:16]
    pending_path = rooted(root, '/var/lib/hermes-desktop/' + supervisor.service + '.refresh-pending')
    pending = existing(pending_path) is not None
    unit_changed = (any(name == supervisor.unit for name, *_ in changes)
                    or pending or state.get('need_reload', False))
    unhealthy = (not state['loaded'] or not state.get('active', bool(state['pid']))
                 or state.get('need_reload', False))
    service_changed = any(name != marker.MARKER for name, *_ in changes) or pending or unhealthy
    actions = []
    for name, old, *_ in changes:
        if old is not None:
            actions.append({'action': 'backup', 'path': name, 'to': backup_dir + name})
        actions.append({'action': 'replace' if old is not None else 'create', 'path': name})
    if service_changed:
        if unit_changed:
            actions.append({'action': 'daemon-reload', 'service': supervisor.service})
        if not state['loaded']:
            actions.append({'action': 'enable', 'service': supervisor.service})
        actions.append({'action': 'restart' if state['pid'] else 'start', 'service': supervisor.service})
    # Preflight all backup conflicts before any file writes. Never replace a prior backup.
    for name, old, _, _, _, info in changes:
        backup = rooted(root, backup_dir + name)
        if old is not None and existing(backup) not in (None, old):
            raise ValueError('backup conflict; select a fresh reviewed plan')
        if old is not None:
            saved_metadata = json_bytes(dict(info, sha256=digest(old)))
            if existing(rooted(root, backup_dir + name + '.metadata.json')) not in (None, saved_metadata):
                raise ValueError('backup metadata conflict; select a fresh reviewed plan')
    print(json.dumps({'host': plan['host'], 'changes': actions, 'noop': not actions}, sort_keys=True))
    if a.plan or not actions:
        return
    # Re-read authorization at the mutation boundary. Never trust a saved change
    # set to carry permission to write a marker (or to mutate a newly held row).
    record = authorize(plan, a.registry, a.qualify)
    if any(name == marker.MARKER for name, *_ in changes):
        marker.guard(record, 'apply marker change')
    # Catch writes since prepare before starting, and again at each replacement.
    for name, old, _, _, _, info in changes:
        path = rooted(root, name)
        if existing(path) != old or (old is not None and metadata(path) != info):
            raise ValueError('concurrent file change; refusing apply')
    if service_changed:
        atomic_write(pending_path, b'refresh required\n', 0o600)
    for name, old, _, _, _, info in changes:
        if old is not None:
            backup = rooted(root, backup_dir + name)
            atomic_write(backup, old, 0o600)
            atomic_write(rooted(root, backup_dir + name + '.metadata.json'),
                         json_bytes(dict(info, sha256=digest(old))), 0o600)
    for name, old, data, mode, owner, info in changes:
        if name == marker.MARKER:
            marker.guard(host_record(a.registry, plan['host']), 'create')
        path = rooted(root, name)
        if existing(path) != old or (old is not None and metadata(path) != info):
            raise ValueError('concurrent file change; refusing replacement')
        atomic_write(path, data, mode, owner=owner)
    # Per-file atomicity, not a filesystem transaction. Backups survive a refresh failure.
    if service_changed and not fixture:
        supervisor.refresh(state, unit_changed)
    if fields:
        verify_projected_env(rooted(root, plan['runtime']['hermes_home'] + '/.env'), fields)
    if service_changed:
        pending_path.unlink()


if __name__ == '__main__':
    try:
        main()
    except (ApplyHeld, marker.MarkerDeferred) as exc:
        sys.exit('desktop-gateway-apply: ' + str(exc))
    except (OSError, ValueError, KeyError, TypeError, ImportError, subprocess.SubprocessError):
        sys.exit('desktop-gateway-apply: preflight/apply failed; files may need recovery if apply began; no secret values logged')
