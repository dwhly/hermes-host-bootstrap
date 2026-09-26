"""Secret-free manifest/checklist and read-only native registry comparison."""
from collections import Counter
import json
from pathlib import Path
import re
from urllib.parse import urlsplit, urlunsplit

from .common import digest, load, load_intent, rollout_declared, update_policy, gateway_record

AUTHORITY = 'hermes-config/fleet/hosts.yaml'


def normalized_url(value):
    if not isinstance(value, str):
        raise ValueError('missing URL')
    url = urlsplit(value)
    if (url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password
            or url.query or url.fragment):
        raise ValueError('invalid gateway URL')
    port = url.port
    host = url.hostname.lower()
    if ':' in host:
        host = '[' + host + ']'
    authority = host + (f':{port}' if port and (url.scheme, port) not in [('http', 80), ('https', 443)] else '')
    return urlunsplit((url.scheme, authority, url.path.rstrip('/'), '', ''))


def manifest(registry, client, revision):
    intent = load_intent(registry)
    declared = rollout_declared(intent)
    hosts = intent['hosts']
    if not isinstance(hosts, list) or not hosts:
        raise ValueError('empty/malformed Intent')
    names = [row['hostname'] for row in hosts]
    if len(set(names)) != len(names) or client not in names:
        raise ValueError('duplicate hosts or client missing from Intent')
    rows = []
    complete = intent.get('complete') is True
    for record in hosts:
        gateway = gateway_record(record)
        policy = update_policy(record, legacy=not declared)
        if not gateway or policy is None:
            complete = False
            rows.append({'managed_id': record['hostname'], 'label': record['hostname'],
                         'admission': 'pending-qualification', 'endpoint': None,
                         'runtime': None, 'native_sign_in': None, 'update_policy': policy})
            continue
        row = {key: gateway.get(key) for key in ('label', 'admission', 'runtime', 'endpoint', 'native_sign_in')}
        if isinstance(row['runtime'], dict):
            row['runtime'] = {key: value for key, value in row['runtime'].items() if key in
                ('user', 'uid', 'group', 'home', 'hermes_home', 'executable', 'executable_sha256', 'build', 'build_identity', 'auth_provider')}
        row['managed_id'] = record['hostname']
        row['update_policy'] = policy
        if not row['label'] or row['admission'] not in ('admitted', 'pending-qualification', 'deferred'):
            raise ValueError('invalid desktop declaration')
        if row['admission'] == 'admitted':
            row['endpoint'] = normalized_url(row['endpoint'])
            if not isinstance(row['runtime'], dict) or row['native_sign_in'] not in ('password', 'token', 'oauth'):
                raise ValueError('admitted row lacks runtime/sign-in declaration')
        elif row['endpoint'] is not None:
            row['endpoint'] = normalized_url(row['endpoint'])
        rows.append(row)
    if intent.get('complete') is True and not complete:
        raise ValueError('Intent declares complete but desktop manifest is incomplete')
    labels = [row['label'].strip().lower() for row in rows]
    urls = [row['endpoint'] for row in rows if row['endpoint']]
    if len(set(labels)) != len(labels) or len(set(urls)) != len(urls):
        raise ValueError('conflicting labels or origins; stop enrollment')
    return {'schema_version': 1, 'authority': AUTHORITY, 'registry_revision': revision,
            'registry_sha256': digest(Path(registry).read_bytes()), 'client_host': client,
            'complete': complete, 'rows': sorted(rows, key=lambda row: row['managed_id'])}


def checklist(data):
    lines = [f"Desktop fleet enrollment — {data['client_host']}",
        f"Intent revision: {data['registry_revision']}; complete: {str(data['complete']).lower()}",
        'Enable keychain encryption before sign-in; reject plaintext fallback.',
        'Re-sign-in any admitted row that verification reports as plain (opt-in does not re-encrypt it).',
        'Settings → Advanced: confirm defaults maxBackends=3 / idleMs=600000 ms; no action.',
        'Persist through the UI only a qualified non-default; idleMs must not exceed 604800000 ms.',
        'Confirm fleet-gateways is enabled in Capabilities → Plugins (shell verification cannot observe this).',
        'Stop enrollment on conflicts or indeterminate inventory. Origin changes require approval and fresh login.',
        'Record wake-to-sections gap and guard skips under measured local secondary use; qualify 3-minute retry before raising the cap.',
        'For removal, drain active turns and remove only the approved managed row; preserve This device and unmanaged extras.']
    if not data['complete']:
        lines.append('INDETERMINATE: incomplete Intent; do not enroll or infer removals.')
    for row in data['rows']:
        if row['admission'] == 'admitted' and data['complete']:
            lines.append(f"Add Remote {row['label']} → {row['endpoint']} → Save/Test → native {row['native_sign_in']} sign-in.")
        else:
            lines.append(f"{row['label']}: {row['admission']}; no connection to create.")
    return '\n'.join(lines) + '\n'


def compare(data, native):
    findings = []
    if data.get('authority') != AUTHORITY or data.get('schema_version') != 1 or data.get('complete') is not True or native.get('version') != 2 or native.get('quarantined'):
        return {'status': 'indeterminate', 'findings': ['partial/malformed inventory; no removal advice']}
    rows = native.get('connections')
    if not isinstance(rows, list) or any(not isinstance(row, dict) or not all(isinstance(row.get(k), str) for k in ('id', 'label', 'kind')) for row in rows):
        return {'status': 'indeterminate', 'findings': ['malformed native inventory; no removal advice']}
    if any(row['kind'] not in ('local', 'remote', 'cloud', 'ssh') for row in rows):
        return {'status': 'indeterminate', 'findings': ['unknown native kind; no removal advice']}
    ids = Counter(row['id'] for row in rows)
    labels = Counter(row['label'].strip().lower() for row in rows)
    urls = Counter(normalized_url(row['url']) for row in rows if row['kind'] in ('remote', 'cloud'))
    for count in (ids, labels, urls):
        if any(value > 1 for value in count.values()):
            findings.append({'status': 'duplicate'})
    matched = set()
    desired_labels = {row['label'].strip().lower() for row in data['rows']}
    for desired in data['rows']:
        if desired['admission'] != 'admitted':
            continue
        label, endpoint = desired['label'].strip().lower(), normalized_url(desired['endpoint'])
        candidates = [row for row in rows if row['kind'] != 'local' and
                      (row['label'].strip().lower() == label or
                       (row.get('url') and normalized_url(row['url']) == endpoint))]
        item = {'managed_id': desired['managed_id']}
        matched.update(row['id'] for row in candidates)
        if not candidates:
            item['status'] = 'missing'
        elif len(candidates) > 1:
            item['status'] = 'duplicate'
        else:
            row = candidates[0]
            mode = 'oauth' if desired['native_sign_in'] == 'oauth' else 'token'
            item['status'] = 'matched' if (row['kind'] == 'remote' and row['label'].strip().lower() == label
                and normalized_url(row.get('url')) == endpoint and row.get('authMode', 'token') == mode) else 'mismatched'
            item['native_id'] = row['id']
            token = row.get('token')
            item['token_encoding'] = ('missing' if token is None else
                {'safeStorage': 'keychain', 'plain': 'plain'}.get(token.get('encoding'), 'unknown') if isinstance(token, dict) else 'unknown')
        findings.append(item)
    for row in rows:
        if row['kind'] != 'local' and row['id'] not in matched:
            findings.append({'native_id': row['id'], 'status': 'extra',
                             'ownership': 'managed' if row['label'].strip().lower() in desired_labels else 'unmanaged'})
    conflicts = any(row['status'] not in ('matched', 'extra') for row in findings)
    insecure = any(row.get('token_encoding') != 'keychain' for row in findings if row['status'] == 'matched')
    return {'status': 'conflict' if conflicts else 'attention' if insecure else 'ok', 'findings': findings}


def pool_settings(user_data, log_text, launch_env):
    path = Path(user_data) / 'pool-limits.json'
    if path.exists():
        raw = json.loads(path.read_text())
        values = {}
        for key, default, low, high in [('maxBackends', 3, 1, 64), ('idleMs', 600000, 60000, 604800000)]:
            value = raw.get(key, default)
            if type(value) not in (int, float):
                value = default
            values[key] = min(high, max(low, int(value)))
        return {'source': 'file', 'effective': values, 'status': 'ok'}
    lines = [line for line in log_text.splitlines() if '[pool-limits]' in line]
    latest = lines[-1] if lines else ''
    values = {'maxBackends': 3, 'idleMs': 600000}
    if 'no saved file and no env overrides; using defaults' not in latest:
        match = re.search(r'no saved file; using env-var overrides: maxBackends=(\d+), idleMs=(\d+)', latest)
        if not match:
            return {'source': 'none', 'status': 'indeterminate'}
        values = dict(zip(('maxBackends', 'idleMs'), map(int, match.groups())))
    # launchctl alone cannot prove the app environment. Require corroborating app log.
    for key, env, default, low, high in [('maxBackends', 'HERMES_DESKTOP_POOL_MAX', 3, 1, 64),
                                        ('idleMs', 'HERMES_DESKTOP_POOL_IDLE_MS', 600000, 60000, 604800000)]:
        if env not in launch_env:
            return {'source': 'none', 'status': 'indeterminate'}
        try:
            expected = min(high, max(low, int(launch_env[env] or default) or default))
        except ValueError:
            return {'source': 'none', 'status': 'indeterminate'}
        if values[key] != expected:
            return {'source': 'none', 'status': 'indeterminate'}
    return {'source': 'none', 'effective': values, 'status': 'ok', 'evidence': 'launchctl + app log (operator must confirm current launch)'}


def read_only_report(data, user_data, registry, log_text='', launch_env=None):
    user_data = Path(user_data)
    report = compare(data, load(user_data / 'connections.json'))
    report['allowlist_fresh'] = data.get('registry_sha256') == digest(Path(registry).read_bytes())
    policy_path = user_data / 'secure-token-storage.json'
    report['keychain_opt_in'] = load(policy_path).get('on') is True if policy_path.exists() else False
    report['pool'] = pool_settings(user_data, log_text, launch_env or {})
    report['plugin_enabled'] = 'operator confirmation required in Capabilities → Plugins'
    if not report['allowlist_fresh']:
        report['status'] = 'indeterminate'
    if not report['keychain_opt_in'] or report['pool']['status'] != 'ok':
        if report['status'] not in ('indeterminate', 'conflict'):
            report['status'] = 'indeterminate' if report['pool']['status'] != 'ok' else 'attention'
    return report
