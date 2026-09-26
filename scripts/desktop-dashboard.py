#!/usr/bin/env python3
"""Module 97 entry point. Render without side effects, or install scoped dashboard files."""
import argparse
import grp
import os
import pwd
import socket
import sys
from desktop_fleet import dashboard, marker
from desktop_fleet.common import host_record, update_policy


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
    p.add_argument('--registry', required=True)
    p.add_argument('--host', default=socket.gethostname().split('.')[0])
    a = p.parse_args()
    user = pwd.getpwnam(a.user)
    runtime = dict(user=a.user, group=grp.getgrgid(user.pw_gid).gr_name, uid=user.pw_uid,
                   home=a.home, hermes_home=a.hermes_home, executable=a.executable)
    if user.pw_dir != a.home or not os.access(a.executable, os.X_OK):
        raise ValueError('runtime account/home or executable mismatch')
    policy = update_policy(host_record(a.registry, a.host))
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
        marker.install('/', a.registry, a.host)
    changed = dashboard.install('/', runtime, a.platform, launcher, unit, service, a.bind, a.port, supervisor)
    print('dashboard changed; owned service refreshed' if changed else 'dashboard unchanged; no restart')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, ImportError) as exc:
        sys.exit('desktop-dashboard: ' + str(exc))
