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

## h-btp interactive Hermes bridge

Reviewed h-btp-only source mappings:

```sh
sudo install -o root -g root -m 0755 scripts/h-btp-hermes-cli.sh /opt/hermes/hermes-cli.sh
sudo install -o root -g root -m 0755 scripts/h-btp-hermes-pane /root/.local/bin/hermes-pane
```

Keep the existing `/usr/local/bin/hermes` shim as `exec /opt/hermes/hermes-cli.sh "$@"`.
`scripts/h-btp-hermes-cli.sh` crosses root invocations to the existing `hermes` account with `/usr/sbin/runuser -u hermes --`, then executes `/home/hermes/.local/bin/hermes` with a clean allowlisted environment. `scripts/h-btp-hermes-pane` crosses to the same account before invoking the unchanged generic resolver at `/opt/hermes-host-bootstrap-baseline/scripts/hermes-pane`, so per-pane session lookup uses `/home/hermes/.hermes` and `PATH` resolves `/home/hermes/.local/bin/hermes`.

These mappings do not edit `scripts/hermes-pane` or `scripts/hermes-workspace`, do not create users or SSH trust, and do not manage Herdr socket ACLs.
