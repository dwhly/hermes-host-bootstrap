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
from desktop_fleet.common import host_record, update_policy, IntentUnavailable, parse
from desktop_fleet import registry
spec = importlib.util.spec_from_file_location('entry', REPO / 'scripts/desktop-dashboard.py')
entry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(entry)


class PolicyTests(unittest.TestCase):
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

    def run_entry(self, record=None, host=None, unavailable=False):
        argv = ['desktop-dashboard', 'install', '--platform', 'linux', '--home', '/fixture',
                '--hermes-home', '/fixture/.hermes', '--executable', '/fixture/hermes', '--user', 'fixture',
                '--registry', '/fixture/intent']
        if host:
            argv += ['--host', host]
        events = []
        read = Mock(return_value=record or {'hostname': 'actual'})
        if unavailable:
            read.side_effect = IntentUnavailable('PyYAML unavailable')
        supervisor = Mock()
        supervisor.check.side_effect = lambda *_: events.append('check')
        with patch.object(sys, 'argv', argv), patch.object(entry.socket, 'gethostname', return_value='actual.example'), \
             patch.object(entry.pwd, 'getpwnam', return_value=SimpleNamespace(pw_gid=123, pw_uid=123, pw_dir='/fixture')), \
             patch.object(entry.grp, 'getgrgid', return_value=SimpleNamespace(gr_name='fixture')), \
             patch.object(entry.os, 'access', return_value=True), \
             patch('desktop_fleet.common.host_record', read), \
             patch.object(entry.dashboard, 'Supervisor', return_value=supervisor), \
             patch.object(entry.marker, 'install', side_effect=lambda *args: events.append(('marker', args[-1]))), \
             patch.object(entry.dashboard, 'install', side_effect=lambda *args: events.append('install')):
            entry.main()
        return events, read.call_args.args[-1]

    def test_entry_legacy_absent_yaml_and_host_resolution(self):
        for unavailable in (False, True):
            events, host = self.run_entry(unavailable=unavailable)
            self.assertEqual(host, 'actual')
            self.assertEqual(events, ['check', 'install'])
        events, host = self.run_entry(host='explicit')
        self.assertEqual(host, 'explicit')

    def test_entry_marker_precedes_service_and_preserved_nodes_refused(self):
        row = {'update_policy': 'protected', 'desktop_gateway': {'dashboard_vehicle': 'module97'}}
        events, _ = self.run_entry(row, 'h-do1')
        self.assertEqual(events, ['check', ('marker', 'h-do1'), 'install'])
        for row in ({'update_policy': 'protected'}, {'desktop_gateway': None},
                    {'update_policy': 'protected', 'desktop_gateway': {'update_policy': 'eligible'}}):
            with self.assertRaises(ValueError):
                self.run_entry(row, 'h-btp')

    def test_optional_verification_skips_legacy_but_refuses_missing_declared_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            intent = Path(tmp) / 'intent.json'
            args = [sys.executable, str(REPO / 'scripts/desktop-fleet.py'), 'verify', '--optional',
                    '--registry', str(intent), '--client', 'mac', '--hermes-home', tmp]
            self.assertEqual(subprocess.run(args, capture_output=True).returncode, 0)
            row = dict(hostname='mac', desktop_gateway=dict(label='mac', admission='admitted',
                       runtime={'uid': 501}, endpoint='https://mac.test', native_sign_in='password'))
            intent.write_text(json.dumps({'complete': True, 'hosts': [row]}))
            self.assertEqual(subprocess.run(args, capture_output=True).returncode, 0)
            row['update_policy'] = 'eligible'
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

    def test_no_pyyaml_explicit_diagnostic_and_venv_fallback(self):
        with patch.dict(sys.modules, {'yaml': None}), patch.dict(os.environ, {'HERMES_FLEET_YAML_RETRY': '1'}):
            with self.assertRaisesRegex(IntentUnavailable, 'PyYAML unavailable'):
                parse('hosts:\n  - hostname: mac\n')
        with patch.dict(sys.modules, {'yaml': None}), patch.dict(os.environ, {'HERMES_FLEET_PYTHON': sys.executable}):
            self.assertEqual(parse('hosts:\n  - hostname: mac\n')['hosts'][0]['hostname'], 'mac')


if __name__ == '__main__':
    unittest.main(verbosity=2)
