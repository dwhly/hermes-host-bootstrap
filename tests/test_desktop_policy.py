#!/usr/bin/env python3
"""Legacy and explicit policy fixtures; no live services or credentials."""
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch, Mock

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'scripts'))
from desktop_fleet.common import host_record, optional_host_record, resolve_intent, update_policy, IntentUnavailable, parse
from desktop_fleet import common
from desktop_fleet import registry
spec = importlib.util.spec_from_file_location('entry', REPO / 'scripts/desktop-dashboard.py')
entry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(entry)
spec = importlib.util.spec_from_file_location('policy', REPO / 'scripts/desktop-fleet-policy.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        env = patch.dict(os.environ, {'HOME': str(self.root), 'HERMES_HOME': str(self.root / '.hermes'),
                                      'HERMES_FLEET_INTENT': ''})
        env.start()
        self.addCleanup(env.stop)
        baseline = patch.object(common, 'BASELINE_INTENT', self.root / 'opt/hermes-config-baseline/fleet/hosts.yaml')
        baseline.start()
        self.addCleanup(baseline.stop)

    def test_real_yaml_shape_is_legacy_and_cannot_enroll(self):
        path = REPO / 'tests/fixtures/desktop-legacy-hosts.yaml'
        row = host_record(path, 'h-btp')
        self.assertEqual(row['management']['runtime_user'], 'hermes')
        self.assertIsNone(update_policy(row, legacy=True))
        with self.assertRaises(ValueError):
            update_policy(row)
        data = registry.manifest(path, 'h-mini', 'fixture')
        self.assertFalse(data['complete'])
        self.assertEqual(len(data['rows']), 7)
        self.assertTrue(all(row['endpoint'] is None for row in data['rows']))
        with tempfile.TemporaryDirectory() as tmp:
            args = [sys.executable, str(REPO / 'scripts/desktop-fleet.py'), 'install', '--registry', str(path),
                    '--client', 'h-mini', '--revision', 'fixture', '--hermes-home', tmp]
            self.assertNotEqual(subprocess.run(args, capture_output=True).returncode, 0)
            self.assertEqual(subprocess.run(args + ['--optional'], capture_output=True).returncode, 0)
            self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_conflicting_and_null_policy_fail_closed(self):
        for row in ({'update_policy': 'protected', 'desktop_gateway': {'update_policy': 'eligible'}},
                    {'update_policy': 'protected', 'desktop_gateway': None}):
            with self.assertRaises(ValueError):
                update_policy(row, legacy=True)
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / 'intent.json'
                path.write_text(json.dumps({'hosts': [dict(row, hostname='mac')]}))
                with self.assertRaises(ValueError):
                    registry.manifest(path, 'mac', 'fixture')

    def run_entry(self, record=None, host=None, unavailable=False, intent=None, marker_present=False):
        path = self.root / 'entry-intent.json'
        if intent is None and not unavailable:
            path.write_text(json.dumps({'hosts': [record or {'hostname': 'actual'}]}))
        elif path.exists():
            path.unlink()
        path = intent or path
        argv = ['desktop-dashboard', 'install', '--platform', 'linux', '--home', '/fixture',
                '--hermes-home', '/fixture/.hermes', '--executable', '/fixture/hermes', '--user', 'fixture',
                '--registry', str(path)]
        if host:
            argv += ['--host', host]
        events = []
        read = Mock(wraps=entry.optional_host_record)
        supervisor = Mock()
        supervisor.check.side_effect = lambda *_: events.append('check')
        with patch.object(sys, 'argv', argv), patch.object(entry.socket, 'gethostname', return_value='actual.example'), \
             patch.object(entry.pwd, 'getpwnam', return_value=SimpleNamespace(pw_gid=123, pw_uid=123, pw_dir='/fixture')), \
             patch.object(entry.grp, 'getgrgid', return_value=SimpleNamespace(gr_name='fixture')), \
             patch.object(entry.os, 'access', return_value=True), \
             patch.object(entry, 'optional_host_record', read), \
             patch.object(entry, 'Path', return_value=SimpleNamespace(exists=lambda: marker_present, is_symlink=lambda: False)), \
             patch.object(entry.dashboard, 'Supervisor', return_value=supervisor), \
             patch.object(entry.marker, 'install', side_effect=lambda *args: events.append(('marker', args[-1]))), \
             patch.object(entry.dashboard, 'install', side_effect=lambda *args: events.append('install')):
            try:
                entry.main()
            except ValueError:
                self.assertEqual(events, [])
                raise
        return events, read.call_args.args[-1]

    def test_entry_legacy_absent_yaml_and_host_resolution(self):
        for unavailable in (False, True):
            events, host = self.run_entry(unavailable=unavailable)
            self.assertEqual(host, 'actual')
            self.assertEqual(events, ['check', 'install'])
        events, host = self.run_entry(host='explicit')
        self.assertEqual(host, 'explicit')

    def test_entry_marker_precedes_service_and_preserved_nodes_refused(self):
        row = {'hostname': 'h-do1', 'update_policy': 'protected', 'desktop_gateway': {'dashboard_vehicle': 'module97'}}
        events, _ = self.run_entry(row, 'h-do1')
        self.assertEqual(events, ['check', ('marker', 'h-do1'), 'install'])
        for row in ({'update_policy': 'protected'}, {'desktop_gateway': None},
                    {'update_policy': 'protected', 'desktop_gateway': {'update_policy': 'eligible'}}):
            with self.assertRaises(ValueError):
                self.run_entry(dict(row, hostname='h-btp'), 'h-btp')

    def test_optional_verification_skips_legacy_but_refuses_missing_declared_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            intent = Path(tmp) / 'intent.json'
            args = [sys.executable, str(REPO / 'scripts/desktop-fleet.py'), 'verify', '--optional',
                    '--registry', str(intent), '--client', 'mac', '--hermes-home', tmp]
            self.assertEqual(subprocess.run(args, capture_output=True).returncode, 0)
            row = dict(hostname='mac', desktop_gateway=dict(label='mac', admission='admitted',
                       runtime={'uid': 501}, endpoint='https://mac.test', native_sign_in='password'))
            intent.write_text(json.dumps({'complete': True, 'hosts': [row]}))
            self.assertNotEqual(subprocess.run(args, capture_output=True).returncode, 0)
            row['update_policy'] = 'eligible'
            intent.write_text(json.dumps({'complete': True, 'hosts': [row]}))
            self.assertNotEqual(subprocess.run(args, capture_output=True).returncode, 0)
            row.pop('desktop_gateway')
            intent.write_text(json.dumps({'complete': True, 'hosts': [row]}))
            self.assertNotEqual(subprocess.run(args, capture_output=True).returncode, 0)
            self.assertEqual(list(Path(tmp).iterdir()), [intent])

    def test_marker_failure_never_reaches_service_install(self):
        record = {'update_policy': 'protected', 'desktop_gateway': {'dashboard_vehicle': 'module97'}}
        argv = ['entry', 'install', '--platform', 'linux', '--home', '/fixture', '--hermes-home', '/fixture/.hermes',
                '--executable', '/fixture/hermes', '--user', 'fixture', '--registry', '/fixture/intent', '--host', 'h-do1']
        with patch.object(sys, 'argv', argv), patch.object(entry, 'optional_host_record', return_value=record), \
             patch.object(entry.pwd, 'getpwnam', return_value=SimpleNamespace(pw_gid=123, pw_uid=123, pw_dir='/fixture')), \
             patch.object(entry.grp, 'getgrgid', return_value=SimpleNamespace(gr_name='fixture')), \
             patch.object(entry.os, 'access', return_value=True), patch.object(entry.dashboard, 'Supervisor'), \
             patch.object(entry.marker, 'install', side_effect=ValueError('marker refused')), \
             patch.object(entry.dashboard, 'install') as install:
            with self.assertRaisesRegex(ValueError, 'marker refused'):
                entry.main()
            install.assert_not_called()

    def test_partially_declared_intent_refused_by_policy_module97_and_verify(self):
        fixture = REPO / 'tests/fixtures/desktop-partial-hosts.yaml'
        with self.assertRaisesRegex(ValueError, 'policy is missing'):
            optional_host_record(fixture, 'h-af')
        with self.assertRaisesRegex(ValueError, 'policy is missing'):
            self.run_entry(host='h-af', intent=fixture)
        result = subprocess.run([sys.executable, str(REPO / 'scripts/desktop-fleet.py'), 'verify', '--optional',
                                 '--registry', str(fixture), '--client', 'mac', '--hermes-home', str(self.root)],
                                capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_missing_host_is_legacy_only_in_undeclared_intent(self):
        fixture = REPO / 'tests/fixtures/desktop-missing-hosts.yaml'
        self.assertEqual(optional_host_record(fixture, 'new-mac'), {})
        events, host = self.run_entry(host='new-mac', intent=fixture)
        self.assertEqual(host, 'new-mac')
        self.assertEqual(events, ['check', 'install'])
        intent = parse(fixture.read_text())
        path = self.root / 'declared.json'
        for declaration in ({'complete': False}, {'hosts': [dict(intent['hosts'][0], update_policy='eligible')]}):
            path.write_text(json.dumps({**intent, **declaration}))
            with self.assertRaisesRegex(ValueError, 'exactly one host record'):
                optional_host_record(path, 'new-mac')
            with self.assertRaisesRegex(ValueError, 'exactly one host record'):
                self.run_entry(host='new-mac', intent=path)

    def test_marker_requires_explicit_module97_protected_authorization(self):
        for record in ({'hostname': 'actual'}, {'hostname': 'actual', 'update_policy': 'eligible'},
                       {'hostname': 'actual', 'update_policy': 'protected'}):
            with self.assertRaisesRegex(ValueError, 'G3 marker present'):
                self.run_entry(record, marker_present=True)
        with self.assertRaisesRegex(ValueError, 'G3 marker present'):
            self.run_entry(unavailable=True, marker_present=True)
        events, _ = self.run_entry({'hostname': 'actual', 'update_policy': 'protected',
                                   'desktop_gateway': {'dashboard_vehicle': 'module97'}}, marker_present=True)
        self.assertEqual(events, ['check', ('marker', 'actual'), 'install'])

    def test_candidate_paths_include_opt_and_preserve_precedence(self):
        baseline = common.BASELINE_INTENT
        baseline.parent.mkdir(parents=True)
        baseline.write_text('hosts:\n  - hostname: h-af\n    update_policy: protected\n')
        self.assertEqual(resolve_intent(self.root / 'missing'), baseline)
        self.assertEqual(update_policy(optional_host_record(resolve_intent(), 'h-af')), 'protected')
        with self.assertRaisesRegex(ValueError, 'preserved-node'):
            self.run_entry(host='h-af', unavailable=True)
        argv = ['policy', 'verify', '--legacy', '--host', 'h-af', '--root', str(self.root)]
        with patch.object(sys, 'argv', argv):
            with self.assertRaises(FileNotFoundError):
                policy.main()  # /opt policy requires the missing fixture marker.
            marker = self.root / 'etc/hermes/image-provenance.json'
            marker.parent.mkdir(parents=True)
            marker.write_text('{"schema":1,"deployment_kind":"image","manager":"docker"}')
            with patch.object(sys, 'stdout', new_callable=io.StringIO) as output:
                policy.main()
            self.assertIn('protected (marker valid', output.getvalue())
        for path in (self.root / '.hermes/fleet/hosts.yaml', self.root / 'custom/fleet/hosts.yaml', self.root / 'override'):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('hosts: []\n')
        with patch.dict(os.environ, {'HERMES_HOME': str(self.root / 'custom')}):
            self.assertEqual(resolve_intent(), self.root / 'custom/fleet/hosts.yaml')
            with patch.dict(os.environ, {'HERMES_FLEET_INTENT': str(self.root / 'override')}):
                self.assertEqual(resolve_intent(), self.root / 'override')
                with patch.object(Path, 'read_text', side_effect=PermissionError('unreadable')):
                    with self.assertRaises(PermissionError):
                        optional_host_record(resolve_intent(), 'h-af')
        self.assertEqual(resolve_intent(), self.root / '.hermes/fleet/hosts.yaml')

    def test_no_pyyaml_only_undeclared_raw_intent_is_legacy(self):
        path = self.root / 'no-yaml.yaml'
        with patch.dict(sys.modules, {'yaml': None}), patch.dict(os.environ, {'HERMES_FLEET_YAML_RETRY': '1'}):
            path.write_text((REPO / 'tests/fixtures/desktop-legacy-hosts.yaml').read_text())
            self.assertEqual(optional_host_record(path, 'h-af'), {})
            for text in ('hosts: []\ncomplete: false\n', 'hosts:\n  - hostname: h-af\n    update_policy: protected\n',
                         'hosts:\n  - hostname: h-af\n    desktop_gateway: {}\n'):
                path.write_text(text)
                with self.assertRaisesRegex(ValueError, 'PyYAML unavailable') as raised:
                    optional_host_record(path, 'h-af')
                self.assertNotIsInstance(raised.exception, IntentUnavailable)
        path.write_text('hosts: [\n')
        with self.assertRaisesRegex(ValueError, 'malformed YAML'):
            optional_host_record(path, 'h-af')

    def test_module97_resolves_override_before_sudo(self):
        # Execute only interpreter selection and a recording sudo stub, never the module.
        source = (REPO / 'lib/97-dashboard-server.sh').read_text()
        selection = source[source.index('py="'):source.index('args=(install')]
        invocation = next(line.strip() for line in source.splitlines() if line.strip().startswith('sudo '))
        script = ('set -eu\nhermes_executable="$1"\nREPO_ROOT="$2"\nargs=(fixture-only)\n'
                  'sudo() { printf "%s\\n" "$@"; }\n' + selection + invocation)
        override = self.root / 'runtime-python'
        override.symlink_to(sys.executable)
        result = subprocess.run(['bash', '-c', script, '_', '/fixture/hermes', str(REPO)],
                                env={**os.environ, 'HERMES_FLEET_PYTHON': str(override)},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         [str(override), str(REPO / 'scripts/desktop-dashboard.py'), 'fixture-only'])

    def test_no_pyyaml_explicit_diagnostic_and_venv_fallback(self):
        with patch.dict(sys.modules, {'yaml': None}), patch.dict(os.environ, {'HERMES_FLEET_YAML_RETRY': '1'}):
            with self.assertRaisesRegex(IntentUnavailable, 'PyYAML unavailable'):
                parse('hosts:\n  - hostname: mac\n')
        with patch.dict(sys.modules, {'yaml': None}), patch.dict(os.environ, {'HERMES_FLEET_PYTHON': sys.executable}):
            self.assertEqual(parse('hosts:\n  - hostname: mac\n')['hosts'][0]['hostname'], 'mac')


if __name__ == '__main__':
    unittest.main(verbosity=2)
