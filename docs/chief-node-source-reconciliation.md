# Chief node source reconciliation and proof

Chief is distinct from Hermes Agent and from the third-party macOS meeting app
`Chief.app` (`bot.chief.app`). Scope a Chief update to the shared Core/console
and the explicitly registered Chief node/spec deployments, not name matches.

## Already-current services

Fetch canonical source refs before deciding to rebuild. Verify Core's live
`/v1/system/runtime`, running console image revision/docs labels, packaged SDK
bytes, and HTTP health. If those already match upstream, do not recreate the
control plane just to describe it as updated.

## Historical rsync versus Git metadata

Older node deployments copied reviewed files while excluding `.git`. As a result,
`git status` can show changes and an old HEAD even though every file exactly
matches the new upstream tree. Never assume these are disposable local edits.

For this specific state:

1. Pin each canonical repo commit; build an exact tracked-file SHA-256 manifest.
2. Inspect all dirty and untracked paths. Require every target-tracked byte to
   match the pinned target and every untracked path to belong to that target.
3. Import authenticated source objects through Git fetch or a verified bundle;
   require the old HEAD to be an ancestor of the target.
4. Archive source, `.git` including index/history, and service plist. Exclude
   regenerable environments/caches, keep secrets private, read the full archive
   to verify its integrity. Do not call this a tested restoration.
5. Recheck bytes, then `git reset --mixed <pin>` aligns HEAD/index WITHOUT
   replacing working files. Require clean status afterwards. Never use
   `reset --hard`, `git clean`, or `rsync --delete` on unknown local work.
6. Reinstall editable node/spec packages as the login user and restart only
   the existing node daemon. Preserve the service environment and Core endpoint.
7. Verify exact source/import paths, PID/start time, valid daemon self-stamp,
   and healthy advancing heartbeats over a full cadence.

Unknown edits or a non-ancestor target are a blocker, not permission to force.
The one-time guarded script and manifests for the September 2026 reconciliation
are tracked in hermes-config at `fleet/rollouts/assets/chief-2026-09-19/`.

## Missing macOS runtime directory

`/var/run` is volatile. A user LaunchAgent can continue sending heartbeats after
reboot while its pinned `/var/run/chief/runtime` directory is absent. The node
silently cannot self-stamp, so healthy heartbeat does NOT prove loaded revision.

The existing narrow sudo grants (`hermes-converger`, `chief-node-supervisor`,
`chief-update`) do not create the required root:chief directory. Do not bypass
those grants or relocate only one side of the runtime-proof contract.

Operator-local repair, using the EXISTING chief group, no new authority:

```bash
sudo install -d -o root -g chief -m 0750 /var/run/chief && sudo install -d -o root -g chief -m 0770 /var/run/chief/runtime && launchctl kickstart -k "gui/$(id -u)/com.chief.node"
```

Verify the daemon's newly written stamp and Core's running ref afterwards. This
repairs the current boot ONLY. A reviewed root-owned boot-time directory
provisioner is still needed for durable reboot recovery; no such fix is claimed.

## Test isolation

Two hermes-node collector tests scan `/run/chief/runtime` even when their
per-test override points elsewhere. On a live control host they can pick up the
real production stamp. In a private Linux mount namespace, bind an empty tmpfs
at that fallback directory and run the suite; never remove the production stamp.
The isolated run distinguishes a test-isolation gap from a runtime fault.
