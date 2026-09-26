#!/usr/bin/env python3
"""Desktop-only enrollment/render/verify. No SSH keys, native writes, or auto-commit."""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys

from desktop_fleet.common import atomic_write, digest, json_bytes, load
from desktop_fleet.registry import checklist, manifest, read_only_report

REPO = Path(__file__).resolve().parents[1]
PLUGIN = REPO / 'desktop-plugins/fleet-gateways'


def install_bundle(home, data, app_pin=None):
    directory = home / 'desktop-plugins/fleet-gateways'
    compatibility = load(PLUGIN / 'compatibility.json')
    source = (PLUGIN / 'plugin.js').read_text()
    source = re.sub(r'/\* FLEET_MANIFEST \*/ .*?;',
                    lambda _: '/* FLEET_MANIFEST */ ' + json.dumps(data, sort_keys=True) + ';', source, count=1)
    content = source.encode()
    previous = directory / 'installed.json'
    if app_pin is None and previous.exists():
        app_pin = load(previous).get('app_pin')
    receipt = {'plugin_revision': compatibility['plugin_revision'], 'sha256': digest(content),
               'manifest_sha256': digest(json_bytes(data)), 'compatibility': compatibility,
               'app_pin': app_pin}
    changed = atomic_write(directory / 'plugin.js', content)
    changed |= atomic_write(directory / 'installed.json', json_bytes(receipt))
    return changed


def install_tools(home, bin_dir):
    changed = False
    for source in [REPO / 'scripts/desktop-fleet.py', *(REPO / 'scripts/desktop_fleet').glob('*.py')]:
        relative = source.relative_to(REPO / 'scripts')
        changed |= atomic_write(home / 'fleet/tools' / relative, source.read_bytes())
    changed |= atomic_write(bin_dir / 'hermes-desktop-fleet-warm',
                            (REPO / 'scripts/hermes-desktop-fleet-warm').read_bytes(), 0o755)
    return changed


def version(home, app=False):
    directory = home / 'desktop-plugins/fleet-gateways'
    receipt = load(directory / 'installed.json')
    if digest((directory / 'plugin.js').read_bytes()) != receipt['sha256']:
        raise ValueError('installed plugin digest mismatch')
    if not app:
        return receipt['plugin_revision'] + ' sha256:' + receipt['sha256']
    pin = receipt['app_pin']
    if not pin:
        raise ValueError('app pin unselected; qualification pending')
    if pin['source_revision'] != receipt['compatibility']['sdk_source_revision']:
        raise ValueError('app source does not match reviewed SDK pin')
    if digest(Path(pin['binary']).read_bytes()) != pin['binary_sha256']:
        raise ValueError('app binary differs from qualified pin')
    return pin['version'] + ' source:' + pin['source_revision'] + ' sha256:' + pin['binary_sha256']


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['render', 'install', 'verify', 'version', 'app-version'])
    p.add_argument('--registry', default=os.environ.get('HERMES_FLEET_INTENT', str(Path.home() / '.hermes/fleet/hosts.yaml')))
    p.add_argument('--client', default=platform.node().split('.')[0])
    p.add_argument('--revision', help='reviewed Intent revision; also records exact input digest')
    p.add_argument('--hermes-home', type=Path, default=Path(os.environ.get('HERMES_HOME', str(Path.home() / '.hermes'))))
    p.add_argument('--bin-dir', type=Path, default=Path.home() / '.local/bin')
    p.add_argument('--user-data', type=Path, default=Path(os.environ.get('HERMES_DESKTOP_USER_DATA_DIR', str(Path.home() / 'Library/Application Support/Hermes'))))
    p.add_argument('--app-log', type=Path, help='log of the current app launch for effective pool settings')
    p.add_argument('--app-pin', type=Path, help='reviewed app build pin; checked post-build only')
    a = p.parse_args()
    generated = a.hermes_home / 'fleet/generated'
    if a.action in ('version', 'app-version'):
        print(version(a.hermes_home, a.action == 'app-version'))
    elif a.action in ('render', 'install'):
        if not a.revision:
            raise ValueError('explicit registry revision is required')
        data = manifest(a.registry, a.client, a.revision)
        if a.action == 'render':
            print(json.dumps({'manifest': data, 'checklist': checklist(data)}, sort_keys=True))
            return
        # Generated artifacts only. Native userData is never mutated.
        changed = atomic_write(generated / 'desktop-gateways.json', json_bytes(data))
        changed |= atomic_write(generated / 'desktop-gateways-checklist.txt', checklist(data).encode())
        changed |= install_bundle(a.hermes_home, data, load(a.app_pin) if a.app_pin else None)
        changed |= install_tools(a.hermes_home, a.bin_dir)
        print('changed' if changed else 'unchanged')
    else:
        data = load(generated / 'desktop-gateways.json')
        env = {}
        if platform.system() == 'Darwin':
            for key in ('HERMES_DESKTOP_POOL_MAX', 'HERMES_DESKTOP_POOL_IDLE_MS'):
                try:
                    env[key] = subprocess.check_output(['launchctl', 'getenv', key], text=True, stderr=subprocess.DEVNULL).strip()
                except subprocess.CalledProcessError as exc:
                    if exc.returncode == 1:
                        env[key] = ''  # launchctl uses 1 for unset, which is the default path.
        app_log = a.app_log or a.hermes_home / 'logs/desktop.log'
        report = read_only_report(data, a.user_data, a.registry,
                                  app_log.read_text() if app_log.exists() else '', env)
        try:
            receipt = load(a.hermes_home / 'desktop-plugins/fleet-gateways/installed.json')
            if receipt['manifest_sha256'] != digest(json_bytes(data)):
                raise ValueError('installed allowlist differs from generated manifest')
            report['plugin_version'] = version(a.hermes_home)
            report['app_pin'] = version(a.hermes_home, True)
        except (OSError, ValueError, KeyError):
            report['sdk_compatibility'] = 'indeterminate: app pin unselected, unqualified or mismatched'
            report['status'] = 'indeterminate'
        print(json.dumps(report, sort_keys=True))
        return 0 if report['status'] == 'ok' else 1
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, ImportError, subprocess.SubprocessError):
        sys.exit('desktop-fleet: indeterminate inventory, settings, or artifact pin; stop enrollment; no removal advice')
