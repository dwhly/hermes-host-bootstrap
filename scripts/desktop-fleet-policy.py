#!/usr/bin/env python3
"""Read Intent policy or manage an explicitly selected G3 marker. No credentials."""
import argparse
import sys
import json
from pathlib import Path
from desktop_fleet.common import host_record, optional_host_record, resolve_intent, rooted, update_policy
from desktop_fleet import marker


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['policy', 'verify', 'render', 'install', 'backup', 'suspend', 'restore'])
    parser.add_argument('--registry')
    parser.add_argument('--host', required=True)
    parser.add_argument('--legacy', action='store_true', help='allow absent rollout policy for existing flows only')
    parser.add_argument('--root', default='/')
    parser.add_argument('--backup', default='/var/backups/hermes-desktop/image-provenance.json')
    args = parser.parse_args()
    legacy = args.legacy and args.action in ('policy', 'verify')
    if legacy:
        args.registry = resolve_intent(args.registry)
    record = optional_host_record(args.registry, args.host) if legacy else host_record(args.registry, args.host)
    policy = update_policy(record, legacy=legacy)
    if args.action == 'policy':
        print(policy or 'legacy')
    elif args.action == 'verify':
        if policy != 'protected':
            print('not-applicable (eligible or legacy Intent)')
        else:
            path = rooted(args.root, marker.MARKER)
            data = json.loads(path.read_text())
            if (type(data.get('schema')) is not int or data['schema'] != 1
                    or data.get('deployment_kind') != 'image' or not data.get('manager')
                    or (Path(args.root) == Path('/') and path.stat().st_uid != 0)):
                raise ValueError('invalid/unowned G3 marker')
            print('protected (marker valid; actual-build REST/CLI refusal qualification still required)')
    elif policy != 'protected':
        raise ValueError('marker operations require registry-protected Intent')
    elif args.action == 'render':
        sys.stdout.buffer.write(marker.render(args.host))
    elif args.action == 'install':
        print('changed' if marker.install(args.root, args.registry, args.host) else 'preserved')
    else:
        print('changed' if marker.maintenance(args.root, args.registry, args.host, args.backup, args.action) else 'unchanged')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, ImportError) as exc:
        sys.exit('desktop-fleet-policy: ' + str(exc) + '; operation refused')
