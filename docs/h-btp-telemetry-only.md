# h-btp telemetry-only chief-node.service

Reviewed source unit: `systemd/h-btp/chief-node.service`.

Install it only as the h-btp telemetry unit:

```sh
sudo install -o root -g root -m 0644 systemd/h-btp/chief-node.service /etc/systemd/system/chief-node.service
sudo install -d -o root -g root -m 0755 /etc/chief
sudoedit /etc/chief/node.env
sudo systemctl daemon-reload
```

`/etc/chief/node.env` must provide the approved `CHIEF_CORE_URL`. Before enable/start, verify `/root/hermes-host-bootstrap/verify.sh` is readable and `/root/code/chief/hermes-node/.venv/bin/python` runs the staged current `hermes-node` package.

Focused checks before enable/start:

```sh
systemctl cat chief-node.service
systemctl show chief-node.service -p FragmentPath -p DropInPaths -p After -p Wants -p Requires
systemctl is-enabled chief-node-reconcile.service chief-node-supervisor.timer chief-node-supervisor.service chief-node-converger.service || true
systemctl is-active chief-node-reconcile.service chief-node-supervisor.timer chief-node-supervisor.service chief-node-converger.service || true
```

Expected: no drop-ins, `After=network-online.target`, `Wants=network-online.target`, empty `Requires=`, root/root identity, no reconcile or supervisor coupling, and every convergence writer/reconciler/supervisor remains disabled and inactive.
