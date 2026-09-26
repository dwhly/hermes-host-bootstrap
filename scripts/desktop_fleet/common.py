"""Small, shared file/Intent primitives. JSON is also accepted as YAML input."""
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile


def load(path):
    text = Path(path).read_text()
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
        import yaml  # Existing fleet YAML dependency; fixture JSON needs only stdlib.
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


def update_policy(record):
    policy = record.get('desktop_gateway', {}).get('update_policy', record.get('update_policy'))
    if policy not in ('protected', 'eligible'):
        raise ValueError('Intent update policy is missing or invalid; refusing update')
    return policy


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
