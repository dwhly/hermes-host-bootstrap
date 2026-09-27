#!/usr/bin/env python3
"""Module 97 entry point. Render without side effects, or install scoped dashboard files."""
import argparse
import grp
import os
import pwd
from pathlib import Path
import socket
import sys
from desktop_fleet import dashboard, marker
from desktop_fleet.common import admission, optional_host_record, resolve_intent, update_policy, gateway_record


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['render', 'install'])
    p.add_argument('--platform', choices=['linux', 'macos'], required=True)
    p.add_argument('--home', required=True)
    p.add_argument('--hermes-home', required=True)
    p.add_argument('--executable', required=True)
    p.add_argument('--user', required=True)
    p.add_argument('--bind', default='tailnet')
    p.add_argument('--port', type=int, default=9000)
    p.add_argument('--registry')
    p.add_argument('--host', default=socket.gethostname().split('.')[0])
    a = p.parse_args()
    a.registry = resolve_intent(a.registry, home=a.home, hermes_home=a.hermes_home)
    record = optional_host_record(a.registry, a.host, home=a.home, hermes_home=a.hermes_home)
    policy = update_policy(record, legacy=True)
    if a.action == 'install' and record and admission(record) != 'admitted':
        print(f'dashboard held: admission {admission(record)}; no dashboard or marker mutation')
        return
    user = pwd.getpwnam(a.user)
    runtime = dict(user=a.user, group=grp.getgrgid(user.pw_gid).gr_name, uid=user.pw_uid,
                   home=a.home, hermes_home=a.hermes_home, executable=a.executable)
    if user.pw_dir != a.home or not os.access(a.executable, os.X_OK):
        raise ValueError('runtime account/home or executable mismatch')
    authorized = policy == 'protected' and gateway_record(record).get('dashboard_vehicle') == 'module97'
    marker_path = Path(marker.MARKER)
    if a.action == 'install' and (marker_path.exists() or marker_path.is_symlink()) and not authorized:
        raise ValueError('G3 marker present; module97 requires protected policy and dashboard_vehicle: module97')
    if policy == 'protected' and not authorized:
        raise ValueError('protected host requires the preserved-node apply vehicle; module97 not authorized in Intent')
    mac = a.platform == 'macos'
    launcher = a.home + '/.local/bin/hermes-dashboard-server' if mac else '/usr/local/bin/hermes-dashboard-server'
    service = dashboard.LABEL if mac else 'hermes-dashboard-server.service'
    unit = a.home + '/Library/LaunchAgents/' + service + '.plist' if mac else '/etc/systemd/system/' + service
    if a.action == 'render':
        sys.stdout.buffer.write(dashboard.render(runtime, a.platform, launcher, service, a.bind, a.port)[1])
        return
    supervisor = dashboard.Supervisor(a.platform, service, unit, user.pw_uid)
    # Protect before service changes; existing markers are never rewritten.
    supervisor.check(a.port)
    if policy == 'protected':
        if marker.deferred(record):
            print('G3 marker deferred; marker step skipped; convergence reconciliation pending')
        else:
            marker.install('/', a.registry, a.host)
    changed = dashboard.install('/', runtime, a.platform, launcher, unit, service, a.bind, a.port, supervisor)
    print('dashboard changed; owned service refreshed' if changed else 'dashboard unchanged; no restart')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, ImportError) as exc:
        sys.exit('desktop-dashboard: ' + str(exc))
