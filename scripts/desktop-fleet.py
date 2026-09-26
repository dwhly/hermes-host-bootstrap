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

from desktop_fleet.common import (atomic_write, digest, json_bytes, load, load_rollout_intent,
                                  resolve_intent, rollout_declared, IntentUnavailable, PythonOverrideError)
from desktop_fleet.registry import checklist, manifest, read_only_report

REPO = Path(__file__).resolve().parents[1]
PLUGIN = REPO / 'desktop-plugins/fleet-gateways'


def template_bytes(content):
    # The manifest occupies one generated line. Do not stop at semicolons in URLs.
    source, count = re.subn(rb'(?m)^const FLEET = /\* FLEET_MANIFEST \*/ [^\n]*;$',
                          b'const FLEET = /* FLEET_MANIFEST */ {schema_version: 1, complete: false, rows: []};', content)
    if count != 1:
        raise ValueError('plugin template manifest boundary mismatch')
    return source


def install_bundle(home, data, app_pin=None):
    directory = home / 'desktop-plugins/fleet-gateways'
    compatibility = load(PLUGIN / 'compatibility.json')
    source = (PLUGIN / 'plugin.js').read_text()
    template_sha256 = digest(source.encode())
    if template_sha256 != compatibility['template_sha256']:
        raise ValueError('repo plugin template digest mismatch')
    source = re.sub(r'/\* FLEET_MANIFEST \*/ .*?;',
                    lambda _: '/* FLEET_MANIFEST */ ' + json.dumps(data, sort_keys=True) + ';', source, count=1)
    content = source.encode()
    previous = directory / 'installed.json'
    if app_pin is None and previous.exists():
        app_pin = load(previous).get('app_pin')
    receipt = {'plugin_revision': compatibility['plugin_revision'], 'sha256': digest(content),
               'template_sha256': template_sha256,
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
    changed |= atomic_write(home / 'fleet/tools/desktop_fleet/compatibility.json',
                            (PLUGIN / 'compatibility.json').read_bytes())
    changed |= atomic_write(bin_dir / 'hermes-desktop-fleet-warm',
                            (REPO / 'scripts/hermes-desktop-fleet-warm').read_bytes(), 0o755)
    return changed


def version(home, app=False, compatibility_path=None):
    directory = home / 'desktop-plugins/fleet-gateways'
    receipt = load(directory / 'installed.json')
    content = (directory / 'plugin.js').read_bytes()
    if digest(content) != receipt['sha256']:
        raise ValueError('installed plugin digest mismatch')
    if compatibility_path is None:
        compatibility_path = PLUGIN / 'compatibility.json'
        if not compatibility_path.exists():
            compatibility_path = Path(__file__).resolve().parent / 'desktop_fleet/compatibility.json'
    compatibility = load(compatibility_path)
    if (digest(template_bytes(content)) != compatibility['template_sha256']
            or receipt['template_sha256'] != compatibility['template_sha256']
            or receipt['plugin_revision'] != compatibility['plugin_revision']
            or receipt['compatibility'] != compatibility):
        raise ValueError('installed plugin template digest/compatibility mismatch')
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
    p.add_argument('--registry')
    p.add_argument('--client', default=platform.node().split('.')[0])
    p.add_argument('--revision', help='reviewed Intent revision; also records exact input digest')
    p.add_argument('--hermes-home', type=Path, default=Path(os.environ.get('HERMES_HOME', str(Path.home() / '.hermes'))))
    p.add_argument('--bin-dir', type=Path, default=Path.home() / '.local/bin')
    p.add_argument('--user-data', type=Path, default=Path(os.environ.get('HERMES_DESKTOP_USER_DATA_DIR', str(Path.home() / 'Library/Application Support/Hermes'))))
    p.add_argument('--app-log', type=Path, help='log of the current app launch for effective pool settings')
    p.add_argument('--app-pin', type=Path, help='reviewed app build pin; checked post-build only')
    p.add_argument('--optional', action='store_true', help='bootstrap: skip an unconfigured rollout without writes')
    p.add_argument('--compatibility', type=Path, help='independent reviewed repository compatibility pin')
    a = p.parse_args()
    if a.action not in ('version', 'app-version'):
        a.registry = resolve_intent(a.registry, hermes_home=a.hermes_home)
    generated = a.hermes_home / 'fleet/generated'
    if a.action in ('version', 'app-version'):
        print(version(a.hermes_home, a.action == 'app-version', a.compatibility))
    elif a.action in ('render', 'install'):
        try:
            data = manifest(a.registry, a.client, a.revision, hermes_home=a.hermes_home)
        except IntentUnavailable as exc:
            if not a.optional:
                raise
            print(f'not-configured ({exc}); desktop rollout disabled')
            return 0
        if a.action == 'install' and not data['complete']:
            if a.optional:
                print('not-configured (complete desktop Intent required); desktop rollout disabled')
                return 0
            raise ValueError('complete desktop Intent is required for installation')
        if not a.revision:
            raise ValueError('explicit registry revision is required')
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
        try:
            intent = load_rollout_intent(a.registry, hermes_home=a.hermes_home)
        except IntentUnavailable:
            if not a.optional:
                raise
            intent = None
        try:
            data = load(generated / 'desktop-gateways.json')
        except IntentUnavailable:
            if not a.optional:
                raise
            try:
                declared = (manifest(a.registry, a.client, a.revision, hermes_home=a.hermes_home)
                            if intent is not None and rollout_declared(intent)
                            else {'complete': False})
            except IntentUnavailable:
                declared = {'complete': False}
            if declared['complete']:
                raise ValueError('desktop rollout declared but installed manifest is missing')
            print('not-configured (desktop rollout pending; no protection/qualification asserted)')
            return 0
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
            report['plugin_version'] = version(a.hermes_home, compatibility_path=a.compatibility)
            report['app_pin'] = version(a.hermes_home, True, a.compatibility)
        except PythonOverrideError:
            raise
        except (OSError, ValueError, KeyError):
            report['sdk_compatibility'] = 'indeterminate: app pin unselected, unqualified or mismatched'
            report['status'] = 'indeterminate'
        print(json.dumps(report, sort_keys=True))
        return 0 if report['status'] == 'ok' else 1
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except IntentUnavailable as exc:
        sys.exit('desktop-fleet: ' + str(exc) + '; enrollment disabled')
    except PythonOverrideError as exc:
        sys.exit('desktop-fleet: ' + str(exc))
    except (OSError, ValueError, KeyError, TypeError, ImportError, subprocess.SubprocessError):
        sys.exit('desktop-fleet: indeterminate inventory, settings, or artifact pin; stop enrollment; no removal advice')
