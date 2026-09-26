"""G3 compatibility marker. Never overwrite or remove someone else's marker."""
import json
from pathlib import Path

from .common import atomic_write, digest, existing, host_record, json_bytes, rooted, update_policy

MARKER = '/etc/hermes/image-provenance.json'
OWNER = 'hermes-host-bootstrap/desktop-fleet-gateways'


def render(host):
    return json_bytes({'schema': 1, 'deployment_kind': 'image', 'manager': 'docker',
                       'fleet_owner': OWNER, 'fleet_host': host})


def install(root, registry, host):
    if update_policy(host_record(registry, host)) != 'protected':
        raise ValueError('G3 is only installed for registry-protected hosts')
    path = rooted(root, MARKER)
    # Preserve arbitrary existing bytes, including a malformed marker (upstream fails closed).
    if path.exists():
        return False
    return atomic_write(path, render(host), owner=(0, 0) if Path(root) == Path('/') else None)


def maintenance(root, registry, host, backup, action):
    """Explicit maintenance only; suspension/qualification are owner-run gates.

    Back up any existing marker without altering it. Suspend only our exact marker.
    Restore exact saved bytes; an intervening marker is never overwritten.
    """
    if update_policy(host_record(registry, host)) != 'protected':
        raise ValueError('maintenance requires protected Intent')
    path = rooted(root, MARKER)
    backup = rooted(root, backup)
    current = existing(path)
    saved = existing(backup)
    metadata_path = rooted(root, "/" + str(backup.relative_to(root)) + ".metadata.json")
    if action == 'backup':
        if current is None:
            raise ValueError('marker is absent')
        if saved is not None and saved != current:
            raise ValueError('backup already exists with different bytes')
        info = path.stat()
        metadata = json_bytes({'sha256': digest(current), 'mode': info.st_mode & 0o777,
                               'uid': info.st_uid, 'gid': info.st_gid})
        if existing(metadata_path) not in (None, metadata):
            raise ValueError('backup metadata conflict')
        changed = atomic_write(backup, current, 0o600)
        return atomic_write(metadata_path, metadata, 0o600) or changed
    if action == 'suspend':
        if current != render(host) or saved != current:
            raise ValueError('only an exactly backed-up fleet-owned marker may be suspended')
        path.unlink()
        return True
    if action == 'restore':
        if saved is None:
            raise ValueError('marker backup is absent')
        metadata = json.loads(metadata_path.read_text())
        if digest(saved) != metadata['sha256']:
            raise ValueError('marker backup digest mismatch')
        if current is not None:
            if current != saved:
                raise ValueError('refusing to overwrite an intervening marker')
            return False
        return atomic_write(path, saved, metadata['mode'], owner=(metadata['uid'], metadata['gid']))
    raise ValueError('unknown maintenance action')
