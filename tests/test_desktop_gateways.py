#!/usr/bin/env python3
"""Offline, non-root fixtures. Does not execute bootstrap modules or host services."""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'scripts'))
from desktop_fleet import dashboard, marker, registry
from desktop_fleet.common import digest, json_bytes, rooted
spec = importlib.util.spec_from_file_location('fleet', REPO / 'scripts/desktop-fleet.py')
fleet = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fleet)

spec = importlib.util.spec_from_file_location('apply', REPO / 'scripts/desktop-gateway-apply.py')
apply = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apply)


def load_compatibility():
    return json.loads((REPO / 'desktop-plugins/fleet-gateways/compatibility.json').read_text())


class Fixtures(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.runtime = dict(user='hermes', group='hermes', uid=1000, home='/home/hermes',
                            hermes_home='/home/hermes/.hermes', executable='/home/hermes/.local/bin/hermes')
        self.intent = self.root / 'intent.json'
        self.intent.write_bytes(json_bytes({'complete': True, 'hosts': [self.host('h-btp', 'protected'), self.host('mac', 'eligible')]}))

    def host(self, name, policy):
        return {'hostname': name, 'desktop_gateway': dict(label=name, admission='admitted',
            runtime=self.runtime, endpoint=f'https://{name}.example.test', native_sign_in='password', update_policy=policy)}

    def write(self, name, data, mode=0o644):
        path = rooted(self.root, name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(mode)
        return path

    def snapshot(self):
        return {str(p.relative_to(self.root)): (p.read_bytes(), p.stat().st_mtime_ns, p.stat().st_mode)
                for p in self.root.rglob('*') if p.is_file()}

    def test_module97_render_and_idempotent_install(self):
        supervisor = Mock()
        supervisor.check.return_value = {'pid': 41, 'loaded': True}
        args = (self.root, self.runtime, 'linux', '/usr/local/bin/hermes-dashboard-server',
                '/etc/systemd/system/hermes-dashboard-server.service', 'hermes-dashboard-server.service',
                '127.0.0.1', 9000, supervisor)
        a = dashboard.render(self.runtime, 'linux', args[3], args[5], args[6], args[7])
        self.assertEqual(a, dashboard.render(self.runtime, 'linux', args[3], args[5], args[6], args[7]))
        self.assertTrue(dashboard.install(*args))
        supervisor.refresh.assert_called_once()
        before = self.snapshot()
        supervisor.refresh.reset_mock()
        self.assertFalse(dashboard.install(*args))
        self.assertEqual(before, self.snapshot())
        supervisor.refresh.assert_not_called()
        mac = dashboard.render(self.runtime, 'macos', '/home/hermes/.local/bin/dashboard', dashboard.LABEL, 'tailnet', 9000)
        self.assertIn(b'<key>HOME</key>', mac[1])
        self.assertIn(b'--no-open', a[0])
        self.assertIn(b'/opt/homebrew/bin', a[0])

    def test_unmanaged_socket_refused_before_files(self):
        run = Mock(side_effect=['MainPID=41\nFragmentPath=/etc/systemd/system/hermes-dashboard-server.service\nLoadState=loaded',
                                'LISTEN 0 128 *:9000 *:* users:(("python",pid=99,fd=3))'])
        supervisor = dashboard.Supervisor('linux', 'hermes-dashboard-server.service',
            '/etc/systemd/system/hermes-dashboard-server.service', 0, run)
        before = self.snapshot()
        with self.assertRaisesRegex(ValueError, 'unmanaged'):
            dashboard.install(self.root, self.runtime, 'linux', '/usr/local/bin/hermes-dashboard-server',
                supervisor.unit, supervisor.service, '127.0.0.1', 9000, supervisor)
        self.assertEqual(before, self.snapshot())
        self.assertEqual(run.call_count, 2)

    def test_credential_rotation_refreshes_only_dashboard_inputs(self):
        supervisor = Mock()
        supervisor.check.return_value = {'pid': 41, 'loaded': True}
        args = (self.root, self.runtime, 'linux', '/usr/local/bin/hermes-dashboard-server',
                '/etc/systemd/system/hermes-dashboard-server.service', 'hermes-dashboard-server.service',
                '127.0.0.1', 9000, supervisor)
        env = self.write('/home/hermes/.hermes/.env', b'OTHER=one\nHERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH=old\nHERMES_DASHBOARD_BASIC_AUTH_SECRET=old\n')
        dashboard.install(*args)
        for key in ('PASSWORD_HASH', 'SECRET', 'PASSWORD', 'USERNAME'):
            supervisor.refresh.reset_mock()
            env.write_bytes(env.read_bytes() + f'HERMES_DASHBOARD_BASIC_AUTH_{key}=rotated\n'.encode())
            self.assertTrue(dashboard.install(*args))
            supervisor.refresh.assert_called_once()
            supervisor.refresh.reset_mock()
            self.assertFalse(dashboard.install(*args))
            supervisor.refresh.assert_not_called()
        env.write_bytes(env.read_bytes() + b'OTHER=two\n')
        self.assertFalse(dashboard.install(*args))
        supervisor.refresh.assert_not_called()
        stamp = rooted(self.root, '/var/lib/hermes-desktop/dashboard-env.sha256')
        self.assertEqual(stamp.stat().st_mode & 0o777, 0o600)
        self.assertNotIn(b'rotated', stamp.read_bytes())

    def test_socket_owner_unknown_and_wrong_supervisor(self):
        for show, sockets in [('MainPID=41\nFragmentPath=/other.service\nLoadState=loaded', ''),
                              ('MainPID=41\nFragmentPath=/unit\nLoadState=loaded', 'LISTEN *:9000')]:
            run = Mock(side_effect=[show, sockets])
            supervisor = dashboard.Supervisor('linux', 'test.service', '/unit', 0, run)
            with self.assertRaises(ValueError):
                supervisor.check(9000)

    def test_refresh_preserves_existing_service_enablement(self):
        run = Mock()
        supervisor = dashboard.Supervisor('linux', 'existing-dashboard.service', '/unit', 0, run)
        supervisor.refresh({'loaded': True, 'pid': 41}, unit_changed=True)
        self.assertEqual([call.args[0] for call in run.call_args_list],
                         [['systemctl', 'daemon-reload'], ['systemctl', 'restart', 'existing-dashboard.service']])

    def test_refresh_failure_retries_identical_files_and_healthy_is_noop(self):
        for platform, failing in [('linux', 'daemon-reload'), ('linux', 'restart'), ('macos', 'bootstrap')]:
            with self.subTest(platform=platform, failing=failing):
                unit = '/units/' + failing
                service = dashboard.LABEL if platform == 'macos' else 'fixture.service'
                state = {'loaded': True, 'pid': 41, 'active': True}
                failed = False
                calls = []
                def run(args):
                    nonlocal failed
                    calls.append(args)
                    if args[1] == 'bootout':
                        state['loaded'] = False
                    if args[1] == failing and not failed:
                        failed = True
                        raise subprocess.CalledProcessError(1, args)
                    if args[1] == 'bootstrap':
                        state['loaded'] = True
                supervisor = dashboard.Supervisor(platform, service, unit, 1000, run)
                supervisor.check = Mock(side_effect=lambda _: dict(state))
                args = (self.root, self.runtime, platform, '/bin/' + failing, unit, service, '127.0.0.1', 9000, supervisor)
                with self.assertRaises(subprocess.CalledProcessError):
                    dashboard.install(*args)
                self.assertTrue(rooted(self.root, unit + '.refresh-pending').exists())
                calls.clear()
                self.assertTrue(dashboard.install(*args))
                self.assertFalse(rooted(self.root, unit + '.refresh-pending').exists())
                if platform == 'macos':
                    self.assertEqual([cmd[1] for cmd in calls], ['bootstrap'])
                else:
                    self.assertEqual([cmd[1] for cmd in calls], ['daemon-reload', 'restart'])
                calls.clear()
                self.assertFalse(dashboard.install(*args))
                self.assertEqual(calls, [])
                state['loaded'] = False
                self.assertTrue(dashboard.install(*args))

    def test_linux_stopped_or_stale_loaded_unit_recovers(self):
        supervisor = Mock()
        state = {'loaded': True, 'pid': 41, 'active': True, 'need_reload': False}
        supervisor.check.side_effect = lambda _: dict(state)
        args = (self.root, self.runtime, 'linux', '/bin/dashboard', '/unit', 'test.service', '127.0.0.1', 9000, supervisor)
        dashboard.install(*args)
        for field, value in [('active', False), ('need_reload', True)]:
            state[field] = value
            supervisor.refresh.reset_mock()
            self.assertTrue(dashboard.install(*args))
            supervisor.refresh.assert_called_once()
            state[field] = not value

    def test_macos_refresh_sequence(self):
        run = Mock()
        supervisor = dashboard.Supervisor('macos', dashboard.LABEL, '/fixture.plist', 501, run)
        supervisor.refresh({'loaded': True, 'pid': 41}, True)
        self.assertEqual([call.args[0] for call in run.call_args_list], [
            ['launchctl', 'bootout', 'gui/501/' + dashboard.LABEL],
            ['launchctl', 'bootstrap', 'gui/501', '/fixture.plist']])

    def test_runtime_rejects_all_desktop_and_ssh_credentials(self):
        self.write('/proc/41/status', b'Uid: 1000 1000 1000 1000\n')
        environ = self.write('/proc/41/environ', b'')
        supervisor = dashboard.Supervisor('linux', 'test.service', '/unit', 1000, Mock(), self.root / 'proc')
        base = b'HOME=/home/hermes\0HERMES_HOME=/home/hermes/.hermes\0'
        environ.write_bytes(base)
        supervisor.check_runtime({'pid': 41}, self.runtime)
        for key in ('HERMES_DESKTOP', 'HERMES_DASHBOARD_SESSION_TOKEN', 'HERMES_DESKTOP_OWNER_NONCE',
                    'HERMES_SSH_PASSWORD', 'HERMES_SSH_PRIVATE_KEY'):
            environ.write_bytes(base + key.encode() + b'=fixture-secret\0')
            with self.assertRaisesRegex(ValueError, 'forbidden auth environment'):
                supervisor.check_runtime({'pid': 41}, self.runtime)

    def test_mac_hidden_listener_is_not_adopted(self):
        run = Mock(side_effect=[subprocess.CalledProcessError(113, 'launchctl'),
                               subprocess.CalledProcessError(1, 'lsof'),
                               'tcp4 0 0 100.64.1.2.9000 *.* LISTEN'])
        supervisor = dashboard.Supervisor('macos', dashboard.LABEL, '/Users/mac/Library/LaunchAgents/dashboard.plist', 501, run)
        with self.assertRaisesRegex(ValueError, 'unverifiable'):
            supervisor.check(9000)
        self.assertEqual(run.call_count, 3)

    def test_marker_render_preserve_and_maintenance(self):
        rendered = json.loads(marker.render('h-btp'))
        self.assertEqual((rendered['schema'], rendered['deployment_kind'], rendered['manager']), (1, 'image', 'docker'))
        self.assertTrue(marker.install(self.root, self.intent, 'h-btp'))
        before = self.snapshot()
        self.assertFalse(marker.install(self.root, self.intent, 'h-btp'))
        self.assertEqual(before, self.snapshot())
        marker.maintenance(self.root, self.intent, 'h-btp', '/backup/marker', 'backup')
        marker.maintenance(self.root, self.intent, 'h-btp', '/backup/marker', 'suspend')
        self.assertFalse(rooted(self.root, marker.MARKER).exists())
        marker.maintenance(self.root, self.intent, 'h-btp', '/backup/marker', 'restore')
        self.assertEqual(rooted(self.root, marker.MARKER).read_bytes(), marker.render('h-btp'))
        self.write(marker.MARKER, b'pre-existing provenance\n', 0o600)
        self.assertFalse(marker.install(self.root, self.intent, 'h-btp'))
        self.assertEqual(rooted(self.root, marker.MARKER).read_bytes(), b'pre-existing provenance\n')
        marker.maintenance(self.root, self.intent, 'h-btp', '/backup/original', 'backup')
        with self.assertRaises(ValueError):
            marker.maintenance(self.root, self.intent, 'h-btp', '/backup/original', 'suspend')
        rooted(self.root, marker.MARKER).unlink()
        marker.maintenance(self.root, self.intent, 'h-btp', '/backup/original', 'restore')
        self.assertEqual(rooted(self.root, marker.MARKER).read_bytes(), b'pre-existing provenance\n')
        self.assertEqual(rooted(self.root, marker.MARKER).stat().st_mode & 0o777, 0o600)
        with self.assertRaises(ValueError):
            marker.install(self.root, self.intent, 'mac')

    def apply_fixture(self):
        plan = json.loads((REPO / 'tests/fixtures/desktop-gateway-plan.json').read_text())
        exe = self.write(plan['runtime']['executable'], b'#!/bin/sh\nexit 0\n', 0o755)
        plan['runtime']['executable_sha256'] = digest(exe.read_bytes())
        env = self.write('/home/hermes/.hermes/.env', b'# unrelated\r\nSLACK_BOT_TOKEN=fixture-only\r\nKEEP="a=b"\nHERMES_DASHBOARD_PUBLIC_URL=http://old\n', 0o600)
        plan['prior_sha256']['/home/hermes/.hermes/.env'] = digest(env.read_bytes())
        self.write('/home/hermes/.hermes/config.yaml', b'unknown: preserve\n')
        self.write('/etc/hostname', b'h-btp\n')
        self.write('/etc/passwd', b'hermes:x:1000:1000::/home/hermes:/bin/bash\n')
        self.write('/etc/group', b'hermes:x:1000:\n')
        self.write('/run/desktop-gateway-supervisor.json', json_bytes(dict(service=plan['supervisor']['service'],
                   pid=0, path='/etc/systemd/system/' + plan['supervisor']['service'], loaded=False, listener_pids=[])))
        entry = self.host('h-btp', 'protected')
        entry['desktop_gateway']['runtime'] = plan['runtime']
        self.intent.write_bytes(json_bytes({'hosts': [entry]}))
        plan_path = self.write('/plan.json', json_bytes(plan))
        return plan, plan_path, env

    def run_apply(self, path, *args, ok=True):
        proc = subprocess.run([sys.executable, str(REPO / 'scripts/desktop-gateway-apply.py'),
            '--root', str(self.root), '--registry', str(self.intent), '--plan-file', str(path), *args],
            text=True, capture_output=True, env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
        if ok:
            self.assertEqual(proc.returncode, 0, proc.stderr)
            return json.loads(proc.stdout)
        self.assertNotEqual(proc.returncode, 0)
        return proc

    def test_apply_plan_exact_output_no_mutation_and_noop(self):
        plan, path, env = self.apply_fixture()
        before = self.snapshot()
        dry = self.run_apply(path, '--plan')
        self.assertEqual(before, self.snapshot())
        self.assertEqual([action['action'] for action in dry['changes']],
                         ['create', 'create', 'backup', 'replace', 'create', 'daemon-reload', 'enable', 'start'])
        self.assertNotIn('fixture-only', json.dumps(dry))
        self.assertEqual(self.run_apply(path), dry)
        self.assertTrue(env.read_bytes().startswith(b'# unrelated\r\nSLACK_BOT_TOKEN=fixture-only\r\nKEEP="a=b"\n'))
        self.assertEqual(rooted(self.root, '/home/hermes/.hermes/config.yaml').read_bytes(), b'unknown: preserve\n')
        backup = next(action['to'] for action in dry['changes'] if action['action'] == 'backup')
        self.assertEqual(rooted(self.root, backup).read_bytes(), before['home/hermes/.hermes/.env'][0])
        self.assertEqual(rooted(self.root, backup).stat().st_mode & 0o777, 0o600)
        before = self.snapshot()
        self.assertEqual(self.run_apply(path), {'host': 'h-btp', 'changes': [], 'noop': True})
        self.assertEqual(before, self.snapshot())

    def test_apply_rejects_drift_identity_socket_symlink_and_unowned_projection(self):
        plan, path, env = self.apply_fixture()
        original = env.read_bytes()
        env.write_bytes(b'drift\n')
        before = self.snapshot()
        self.run_apply(path, '--plan', ok=False)
        self.assertEqual(before, self.snapshot())
        env.write_bytes(original)
        hostname = rooted(self.root, '/etc/hostname')
        hostname.write_text('wrong-host\n')
        self.run_apply(path, ok=False)
        hostname.write_text('h-btp\n')
        state = rooted(self.root, '/run/desktop-gateway-supervisor.json')
        observed = json.loads(state.read_text())
        observed['listener_pids'] = [99]
        state.write_bytes(json_bytes(observed))
        self.run_apply(path, ok=False)
        observed['listener_pids'] = []
        state.write_bytes(json_bytes(observed))
        projection = self.write('/projection', b'SLACK_BOT_TOKEN=not-owned\n')
        self.run_apply(path, '--dashboard-env', str(projection), ok=False)
        env.unlink()
        env.symlink_to(self.root / 'plan.json')
        self.run_apply(path, ok=False)

    def test_apply_preserves_env_metadata_and_backs_it_up(self):
        plan, path, env = self.apply_fixture()
        env.chmod(0o640)
        before = apply.metadata(env)
        result = self.run_apply(path)
        self.assertEqual(apply.metadata(env), before)
        backup = next(action['to'] for action in result['changes'] if action['action'] == 'backup')
        saved = json.loads(rooted(self.root, backup + '.metadata.json').read_text())
        self.assertEqual({k: saved[k] for k in before}, before)
        self.assertEqual(saved['sha256'], plan['prior_sha256']['/home/hermes/.hermes/.env'])
        self.assertTrue(self.run_apply(path)['noop'])

    def test_apply_metadata_only_change_requires_prior_hash(self):
        plan, path, env = self.apply_fixture()
        self.run_apply(path)
        launcher = rooted(self.root, '/usr/local/bin/hermes-dashboard-server')
        launcher.chmod(0o700)
        before = self.snapshot()
        self.run_apply(path, ok=False)
        self.assertEqual(self.snapshot(), before)
        plan['prior_sha256']['/usr/local/bin/hermes-dashboard-server'] = digest(launcher.read_bytes())
        path.write_bytes(json_bytes(plan))
        self.run_apply(path)
        self.assertEqual(launcher.stat().st_mode & 0o777, 0o755)

    def test_apply_detects_concurrent_env_write_before_replacement(self):
        plan, path, env = self.apply_fixture()
        real_write = apply.atomic_write
        injected = False
        def write(target, *args, **kwargs):
            nonlocal injected
            result = real_write(target, *args, **kwargs)
            if target.name == 'hermes-dashboard-server' and '/backups/' not in str(target) and not injected:
                injected = True
                env.write_bytes(env.read_bytes() + b'CONCURRENT=preserve\n')
            return result
        argv = ['apply', '--root', str(self.root), '--registry', str(self.intent), '--plan-file', str(path)]
        with patch.object(sys, 'argv', argv), patch.object(apply, 'atomic_write', side_effect=write):
            with self.assertRaisesRegex(ValueError, 'concurrent file change'):
                apply.main()
        self.assertTrue(injected)
        self.assertTrue(env.read_bytes().endswith(b'CONCURRENT=preserve\n'))
        self.assertIn(b'http://old', env.read_bytes())

    def test_launcher_rejects_desktop_exemption_and_preserves_path(self):
        fake = self.write('/fake-hermes', b'#!/bin/sh\nprintf "%s\\n" "$@"\n', 0o755)
        env = {'HOME': str(self.root), 'PATH': '/usr/bin:/bin',
               'HERMES_DASHBOARD_BIND': '127.0.0.1', 'HERMES_DASHBOARD_EXECUTABLE': str(fake)}
        launcher = ['bash', str(REPO / 'scripts/hermes-dashboard-server.sh')]
        for forbidden in ('HERMES_DESKTOP', 'HERMES_DASHBOARD_SESSION_TOKEN'):
            proc = subprocess.run(launcher, env={**env, forbidden: 'fixture-value'}, capture_output=True, text=True)
            self.assertNotEqual(proc.returncode, 0)
            self.assertIn('forbidden', proc.stderr)
            self.assertNotIn('fixture-value', proc.stderr)
        proc = subprocess.run(launcher, env=env, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.splitlines(), ['dashboard', '--host', '127.0.0.1', '--port', '9000', '--no-open'])

    def test_qualified_app_pin_and_manifest_freshness(self):
        data = registry.manifest(self.intent, 'mac', 'revision')
        app = self.write('/Hermes.app/Contents/MacOS/Hermes', b'fixture-app')
        pin = {'version': 'fixture-1', 'source_revision': load_compatibility()['sdk_source_revision'],
               'binary': str(app), 'binary_sha256': digest(app.read_bytes())}
        fleet.install_bundle(self.root, data, pin)
        self.assertIn('fixture-1', fleet.version(self.root, True))
        before = self.snapshot()
        self.assertFalse(fleet.install_bundle(self.root, data))
        self.assertEqual(before, self.snapshot())
        app.write_bytes(b'different-build')
        with self.assertRaisesRegex(ValueError, 'differs'):
            fleet.version(self.root, True)
        data['rows'][0]['admission'] = 'pending-qualification'
        data['rows'][0]['endpoint'] = None
        self.assertNotIn('Add Remote h-btp', registry.checklist(data))
        self.assertNotIn('h-btp', [row.get('managed_id') for row in registry.compare(data, self.native())['findings']])

    def native(self):
        return {'version': 2, 'connections': [dict(id='local', label='This device', kind='local'),
            dict(id='native-btp', label='h-btp', kind='remote', url='https://h-btp.example.test/', authMode='token', token={'encoding': 'safeStorage', 'value': 'DO-NOT-PRINT'}),
            dict(id='native-mac', label='mac', kind='remote', url='https://mac.example.test', token={'encoding': 'plain', 'value': 'DO-NOT-PRINT'})]}

    def test_registry_readonly_comparison_checklist_and_partial(self):
        data = registry.manifest(self.intent, 'mac', 'fixture-revision')
        text = registry.checklist(data)
        for part in ('keychain', 'Re-sign-in', 'no action', 'enabled', 'Save/Test', 'guard skips'):
            self.assertIn(part, text)
        native = self.native()
        report = registry.compare(data, native)
        self.assertNotIn('DO-NOT-PRINT', json.dumps(report))
        self.assertEqual(report['status'], 'attention')
        native['connections'][2]['token']['encoding'] = 'safeStorage'
        native['connections'].append(dict(id='extra', label='unmanaged', kind='ssh'))
        report = registry.compare(data, native)
        self.assertEqual(report['status'], 'ok')
        self.assertEqual(report['findings'][-1]['ownership'], 'unmanaged')
        native['connections'].append(dict(native['connections'][1], id='duplicate'))
        self.assertEqual(registry.compare(data, native)['status'], 'conflict')
        native = self.native()
        native['connections'][1]['url'] = 'https://different.example.test'
        self.assertEqual(registry.compare(data, native)['findings'][0]['status'], 'mismatched')
        native['connections'].pop(1)
        self.assertEqual(registry.compare(data, native)['findings'][0]['status'], 'missing')
        data['complete'] = False
        self.assertEqual(registry.compare(data, native)['status'], 'indeterminate')
        self.assertNotIn('Add Remote', registry.checklist(data))

    def test_pool_sources_and_readonly_report(self):
        user_data = self.root / 'userData'
        user_data.mkdir()
        env = {'HERMES_DESKTOP_POOL_MAX': '', 'HERMES_DESKTOP_POOL_IDLE_MS': ''}
        self.assertEqual(registry.pool_settings(user_data, '', env)['status'], 'indeterminate')
        log = '[pool-limits] no saved file and no env overrides; using defaults'
        self.assertEqual(registry.pool_settings(user_data, log, env)['effective'], {'maxBackends': 3, 'idleMs': 600000})
        env['HERMES_DESKTOP_POOL_MAX'] = '5'
        self.assertEqual(registry.pool_settings(user_data, log, env)['status'], 'indeterminate')
        log = '[pool-limits] no saved file; using env-var overrides: maxBackends=5, idleMs=600000'
        self.assertEqual(registry.pool_settings(user_data, log, env)['effective']['maxBackends'], 5)
        (user_data / 'pool-limits.json').write_text('{"maxBackends":4,"idleMs":700000}')
        (user_data / 'secure-token-storage.json').write_text('{"on":true}')
        (user_data / 'connections.json').write_bytes(json_bytes(self.native()))
        data = registry.manifest(self.intent, 'mac', 'revision')
        before = self.snapshot()
        report = registry.read_only_report(data, user_data, self.intent, log, env)
        self.assertEqual(report['pool']['source'], 'file')
        self.assertEqual(report['pool']['effective']['maxBackends'], 4)
        self.assertEqual(before, self.snapshot())
        self.assertNotIn('DO-NOT-PRINT', json.dumps(report))

    def test_desktop_only_enrollment_bypasses_legacy_flow_and_installs_shim(self):
        home = self.root / 'client-home'
        command = ['bash', str(REPO / 'scripts/fleet-enroll-existing'), '--desktop-only',
            '--registry', str(self.intent), '--client', 'mac', '--revision', 'fixture-ref',
            '--hermes-home', str(home), '--bin-dir', str(self.root / 'bin')]
        env = {'HOME': str(self.root), 'PATH': '/usr/bin:/bin', 'PYTHONDONTWRITEBYTECODE': '1'}
        proc = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        before = self.snapshot()
        proc = subprocess.run(command, env=env, capture_output=True, text=True)
        self.assertEqual(proc.stdout.strip(), 'unchanged')
        self.assertEqual(before, self.snapshot())
        proc = subprocess.run([str(self.root / 'bin/hermes-desktop-fleet-warm'), '--version'],
            env={**env, 'HERMES_HOME': str(home)}, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('1.0.0 sha256:', proc.stdout)
        self.assertFalse((self.root / '.local/state/fleet-enroll').exists())
        self.assertFalse((self.root / 'Library').exists())

    def test_plugin_static_surface_digest_noop_and_pin(self):
        source = (REPO / 'desktop-plugins/fleet-gateways/plugin.js').read_text()
        self.assertEqual(re.findall(r'from [\'"]([^\'"]+)', source), ['@hermes/plugin-sdk'])
        self.assertEqual(set(re.findall(r'host\.(\w+)', source)), {'connections', 'warmAgent'})
        self.assertEqual(set(re.findall(r'ctx\.(\w+)', source)), {'onDispose', 'setInterval', 'setTimeout', 'addEventListener'})
        for forbidden in ('fetch(', 'localStorage', 'hermesDesktop', 'connections.json', 'writeFile', 'activateAgent', 'host.request'):
            self.assertNotIn(forbidden, source)
        self.assertIn("window, 'online'", source)
        self.assertIn("window, 'focus'", source)
        self.assertIn('4 * 60 * 1000', source)
        self.assertIn('30 * 1000', source)
        self.assertIn('60 * 1000', source)
        data = registry.manifest(self.intent, 'mac', 'revision')
        self.assertTrue(fleet.install_bundle(self.root, data))
        before = self.snapshot()
        self.assertFalse(fleet.install_bundle(self.root, data))
        self.assertEqual(before, self.snapshot())
        self.assertIn('sha256:', fleet.version(self.root))
        with self.assertRaisesRegex(ValueError, 'unselected'):
            fleet.version(self.root, app=True)
        plugin = self.root / 'desktop-plugins/fleet-gateways/plugin.js'
        plugin.write_text(plugin.read_text() + '// tampered\n')
        with self.assertRaisesRegex(ValueError, 'digest'):
            fleet.version(self.root)


if __name__ == '__main__':
    unittest.main(verbosity=2)
