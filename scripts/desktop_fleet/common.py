"""Small, shared file/Intent primitives. JSON is also accepted as YAML input."""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import shutil
import tempfile


class IntentUnavailable(ValueError):
    """Optional rollout input/dependency is absent, not malformed."""


BASELINE_INTENT = Path('/opt/hermes-config-baseline/fleet/hosts.yaml')


def intent_candidates(registry=None, *, home=None, hermes_home=None):
    home = Path(home) if home is not None else Path.home()
    hermes_home = Path(hermes_home or os.environ.get('HERMES_HOME', home / '.hermes'))
    override = os.environ.get('HERMES_FLEET_INTENT')
    if override:
        try:
            Path(override).lstat()
        except FileNotFoundError as exc:
            raise ValueError('HERMES_FLEET_INTENT file does not exist') from exc
    candidates = [registry, override,
                  hermes_home / 'fleet/hosts.yaml', home / '.hermes/fleet/hosts.yaml', BASELINE_INTENT]
    return list(dict.fromkeys(Path(path) for path in candidates if path))


def resolve_intent(registry=None, *, home=None, hermes_home=None):
    """Use the native-bots candidate order; unreadable inputs must not be skipped."""
    for path in intent_candidates(registry, home=home, hermes_home=hermes_home):
        try:
            path.lstat()
        except FileNotFoundError:
            continue
        return path
    return None


def rollout_declared(intent):
    if (not isinstance(intent, dict) or not isinstance(intent.get('hosts'), list)
            or any(not isinstance(row, dict) for row in intent['hosts'])):
        raise ValueError('malformed Intent host inventory')
    return 'complete' in intent or any('update_policy' in row or 'desktop_gateway' in row
                                     for row in intent['hosts'])


def load_intent(registry):
    if registry is None:
        raise IntentUnavailable('Intent file is absent at all candidate paths')
    # A selected path that disappears or cannot be read is indeterminate, not legacy.
    text = Path(registry).read_text()
    try:
        return parse(text)
    except IntentUnavailable as exc:
        if ('update_policy' in text or 'desktop_gateway' in text
                or re.search(r'''(?m)^(?:complete|"complete"|'complete')\s*:''', text)):
            raise ValueError(str(exc)) from exc
        raise


def load_rollout_intent(registry, *, home=None, hermes_home=None):
    """A declared selection wins; legacy requires every candidate to be undeclared."""
    unavailable = None
    try:
        intent = load_intent(registry)
        if rollout_declared(intent):
            return intent
    except IntentUnavailable as exc:
        unavailable = exc
    try:
        for path in intent_candidates(registry, home=home, hermes_home=hermes_home):
            if registry is not None and path == Path(registry):
                continue
            try:
                path.lstat()
            except FileNotFoundError:
                continue
            try:
                other = load_intent(path)
            except IntentUnavailable:
                continue  # load_intent already refuses raw declaration tokens.
            if rollout_declared(other):
                raise ValueError('declared alternative Intent')
    except (OSError, ValueError) as exc:
        raise ValueError('Intent copies disagree on desktop rollout declaration') from exc
    if unavailable is not None:
        raise unavailable
    return intent


def yaml_load(text):
    """Prefer the Hermes interpreter when the system Python lacks PyYAML."""
    candidates = [os.environ.get('HERMES_FLEET_PYTHON', ''),
                  str(Path.home() / 'hermes-agent/venv/bin/python3'),
                  str(Path.home() / 'hermes-agent/.venv/bin/python3')]
    hermes = shutil.which('hermes')
    if hermes:
        candidates.append(str(Path(hermes).resolve().parent / 'python3'))
    candidates.append('/usr/local/lib/hermes-agent/venv/bin/python3')
    if not os.environ.get('HERMES_FLEET_YAML_RETRY'):
        for candidate in dict.fromkeys(candidates):
            if not candidate or not os.access(candidate, os.X_OK):
                continue
            code = ('import sys,json; sys.path.insert(0,sys.argv[1]); '
                    'from desktop_fleet.common import parse; print(json.dumps(parse(sys.stdin.read())))')
            proc = subprocess.run([candidate, '-c', code, str(Path(__file__).resolve().parents[1])],
                                  input=text, text=True, capture_output=True,
                                  env={**os.environ, 'HERMES_FLEET_YAML_RETRY': '1'})
            if proc.returncode == 0:
                return json.loads(proc.stdout)
            if 'IntentUnavailable' not in proc.stderr:
                raise ValueError('malformed YAML input')
    raise IntentUnavailable('PyYAML unavailable; install it in the Hermes venv or set HERMES_FLEET_PYTHON')


def load(path):
    try:
        return parse(Path(path).read_text())
    except FileNotFoundError as exc:
        raise IntentUnavailable('Intent/input file is absent') from exc


def parse(text):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate mapping key')
            result[key] = value
        return result
    try:
        return json.loads(text, object_pairs_hook=unique)
    except json.JSONDecodeError:
        try:
            import yaml
        except ImportError:
            return yaml_load(text)
        class UniqueLoader(yaml.SafeLoader):
            pass
        def mapping(loader, node):
            return unique((loader.construct_object(key), loader.construct_object(value)) for key, value in node.value)
        UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
        try:
            return yaml.load(text, Loader=UniqueLoader)
        except yaml.YAMLError as exc:
            raise ValueError('malformed YAML input') from exc


def host_record(registry, host):
    data = load(registry)
    rows = data['hosts']
    matches = [row for row in rows if row.get('hostname') == host]
    if len(matches) != 1:
        raise ValueError('Intent must contain exactly one host record')
    return matches[0]


def gateway_record(record):
    gateway = record.get('desktop_gateway', {})
    if not isinstance(gateway, dict):
        raise ValueError('desktop_gateway must be a mapping')
    return gateway


def update_policy(record, *, legacy=False):
    gateway = gateway_record(record)
    policies = [row['update_policy'] for row in (record, gateway) if 'update_policy' in row]
    if not policies and legacy:
        return None
    if not policies or any(policy not in ('protected', 'eligible') for policy in policies):
        raise ValueError('Intent update policy is missing or invalid; refusing update')
    if len(set(policies)) != 1:
        raise ValueError('conflicting Intent update policies; refusing operation')
    return policies[0]


def optional_host_record(registry, host, *, home=None, hermes_home=None):
    try:
        intent = load_rollout_intent(registry, home=home, hermes_home=hermes_home)
    except IntentUnavailable as exc:
        print(f'desktop-fleet: {exc}; legacy behavior only, new rollout actions disabled', file=sys.stderr)
        return {}
    if not rollout_declared(intent):
        return {}
    matches = [row for row in intent['hosts'] if row.get('hostname') == host]
    if len(matches) != 1:
        raise ValueError('declared Intent must contain exactly one host record')
    update_policy(matches[0])  # A declared rollout never permits a row without policy.
    return matches[0]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(data):
    return (json.dumps(data, indent=2, sort_keys=True) + '\n').encode()


def rooted(root, path):
    """No symlink traversal or relative paths, including under fixture roots."""
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('expected an absolute path without traversal')
    target = Path(root) / str(path).lstrip('/')
    for component in (target, *target.parents):
        if component.is_symlink():
            raise ValueError('symlinks are not allowed in owned paths')
    return target


def existing(path):
    if path.exists():
        if not stat.S_ISREG(path.lstat().st_mode):
            raise ValueError('owned path is not a regular file')
        return path.read_bytes()
    return None


def atomic_write(path, data, mode=0o644, owner=None):
    """Compare before touching metadata; preserve existing ownership by default."""
    old = existing(path)
    if old == data and stat.S_IMODE(path.stat().st_mode) == mode:
        if owner is None or (path.stat().st_uid, path.stat().st_gid) == owner:
            return False
    previous = path.stat() if old is not None else None
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), mode)
            uid_gid = owner or ((previous.st_uid, previous.st_gid) if previous else None)
            created = os.fstat(stream.fileno())
            if uid_gid is not None and uid_gid != (created.st_uid, created.st_gid):
                os.fchown(stream.fileno(), *uid_gid)
        os.replace(temp, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)
    return True
