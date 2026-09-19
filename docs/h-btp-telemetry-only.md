# h-btp telemetry-only chief-node.service

Reviewed source unit: `systemd/h-btp/chief-node.service`.

“Telemetry-only” describes Chief's fleet-control daemon, not a ban on BTP development.
The Hermes runtime may own BTP repositories, builds/tests and authorized system integrations;
h-btp is not the default shared fleet heavy-build machine or a second fleet boss.

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

## Approved older-Mac direct-access catch-up

`scripts/h-btp-client-apply.py` is a manually invoked operator procedure, not an updater or
scheduled consumer. Its host/home guards accept only h-mini (`danz`, `/Users/dan_1`) and
h-air (`danz`, `/Users/danz`). It reuses h-mini's explicitly approved
`~/.ssh/macadm_archive_ed25519` fingerprint and may create the approved dedicated
`~/.ssh/id_ed25519_hbtp` on h-air only if both key files are absent. It never transfers a
private key or creates an OS account. A lost/replaced key requires fresh fingerprint review;
do not silently recreate h-mini's key or keep adding unreviewed public identities.

Prepare a private staging directory on the client containing this script plus:

- the committed `hermes-workspace`, `hermes-host-resolve`, `hermes-terminal-reset` scripts;
- `payload.json`: `master_full` (canonical `fleet/hosts.yaml`), `master_block` (only its
  h-btp list entry), `snapshot` (`hosts/h-btp.yaml`), `known_hosts` (the verified public
  `fleet/access/h-btp.known_hosts` line), and `helpers` (exact filename → SHA-256 map).

These are public/non-secret fleet configuration, never credentials. Build the payload from
the committed sources, verify its transfer checksum, and invoke Python in isolated mode so
ambient `PYTHONOPTIMIZE` cannot disable the guards. The key step is mandatory immediately
before every apply, including reruns:

```sh
/usr/bin/python3 -I scripts/h-btp-client-apply.py h-mini key /path/to/stage
# Review/copy ONLY the .pub file; record its approved fingerprint in the rollout record.
# Commit the public key to fleet/access/h-btp.authorized_keys, refresh the target source,
# then use existing lib/05-ssh-access.sh with HERMES_AUTHORIZED_KEYS_FILE set to that file.
/usr/bin/python3 -I scripts/h-btp-client-apply.py h-mini key /path/to/stage
/usr/bin/python3 -I scripts/h-btp-client-apply.py h-mini apply /path/to/stage
```

Use `h-air` on that host. Apply changes only the h-btp registry entry/snapshot, a bounded
SSH Host stanza and pinned host key, and those reviewed helpers. Original files or symlink
targets are recorded under `~/.hermes-backups/hbtp-direct-*/manifest.json`; the runtime
`config.yaml` must remain byte-identical. The SSH stanza disables proxying and agent
forwarding only for h-btp, selects the local key explicitly, and requires strict host checking.

Verify explicit `root@100.127.149.96` resolution, key-only direct SSH, HMW counts 1/2/2,
exact H1 focus, and an actual interactive connection from that Mac. Disconnect only the
diagnostic transport; verify target panes, terminal identities and BTP service PIDs persist.
Persist non-secret evidence and pending hosts in `fleet/rollouts/h-btp-baseline-access-20260919.json`.
The initial operator script received independent SAFE-TO-APPLY review; review new changes
before running it. h-air2 and h-mini2 use their existing key paths and are outside this helper.
