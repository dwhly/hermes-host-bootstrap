# Fleet currency Step 0 / A0 — fix round 1

Step 0 closes the legacy privilege grants and retains the existing authenticated,
six-artifact converger. Success requires active root readers, boss check-ins,
qualified full-wake convergence and supervision on every Mac. **Disabled root jobs
are a failed rollout**, even if containment succeeded. No rollout has been run by
these fixtures. Phases A–D, new package adapters and HMAC retirement remain outside
this change. Gate-2 §8 governs h-af/h-btp: foundation closure applies; their vaults,
credentials, cron, local code/config and owner workloads are preserved.

## Before delivery

Use the authoritative `~/.hermes/hosts/<id>.yaml` for SSH targets. Capture installed
code and launcher hashes, config bytes/modes, policy and unit definitions. Capture
h-air's unmodified-contact/migration-required evidence before changing its oldest
bytes. Merge only after independent review; **this build does not push**. Keep
`origin/main` at the reviewed commit during the two-command legacy bridge.

Build on the manager (set `currency_commit` to the reviewed merged commit):

```sh
git -c tar.umask=022 archive --format=tar "$currency_commit" hermes_converger > currency-step0.tar
sha256sum currency-step0.tar
git show "$currency_commit":scripts/currency-step0-digest.py > currency-step0-digest.py
currency_review=$(mktemp -d)
tar --no-same-permissions -xf currency-step0.tar -C "$currency_review"
python3 currency-step0-digest.py "$currency_review/hermes_converger" > currency-step0.digest
/bin/sh "$currency_review/hermes_converger/step0/close.sh" --plan macos
/bin/sh "$currency_review/hermes_converger/step0/close.sh" --plan linux
```

Preflight each Mac, including **h-air2**, read-only. Run the reviewed `trust.sh`
functions in an unprivileged clean shell; they check ownership without needing root.
Record the output of these commands before starting closure:

```sh
stat -f '%Su:%Sg %Lp %N' /usr/local /usr/local/bin /usr/local/lib \
  /Library /Library/Developer /Library/Developer/CommandLineTools \
  /Library/Developer/CommandLineTools/usr/bin/python3
/Library/Developer/CommandLineTools/usr/bin/python3 -I -S -B -c 'import sys; print(sys.version); sys.exit(sys.version_info < (3,9))'
# After sourcing the reviewed trust.sh in that clean shell:
trusted_python
trusted_path /usr/local/bin
trusted_path /usr/local/lib/hermes-host-bootstrap
```

The daemon's permanent home is `/opt/chief/bin` and
`/opt/chief/lib/hermes-host-bootstrap`, with root-owned parent chains. Apple's
`/usr/bin/python3` is resolved by selecting the **direct CLT binary**, never by
executing xcrun/xcode-select or following a login-owned Xcode.app. Check its whole
framework, including root-owned framework directory aliases. Prefer a trusted
`/opt/chief/python` when provisioned. No Homebrew/venv interpreter is accepted.
If `/usr/local` is user-writable (Intel Homebrew), the old bridge fails trust:
use the clean administrator archive route below, which never installs there.
Do not chown Homebrew or claim containment is successful daemon deployment.

On the Linux replica and **each of h-do1, h-af, h-btp**, run the reviewed trust
functions read-only and record effective unit configuration:

```sh
trusted_python
for unit in chief-node-reconcile.service chief-node-converger.service \
  chief-node-supervisor.service chief-node-supervisor.timer chief-update.service \
  chief-update.timer chief-update-request.service chief-update-request.path; do
  systemctl show "$unit" -p DropInPaths -p FragmentPath
done
systemctl show chief-node.service -p After
```

Per-unit Chief overrides are archived before replacement. Global/type-wide
drop-ins are held rather than edited; resolve incompatible global overrides
before closure. For h-do1, an existing `After=chief-node-reconcile.service` on
**chief-node.service** is retained and recorded as a possible node-start delay
(up to the 1,860s unit timeout during an outage). Core's Docker startup remains
independent. Include that delay in the reboot/Core-outage proof; no owner unit is
rewritten by this closure.

## Reachable Macs with a trusted legacy delivery path

Resolve a target on the manager; repeat per registry host, h-mini2 first:

```sh
currency_host=h-mini2
currency_target=$(python3 - "$currency_host" <<'PY'
import pathlib, sys, yaml
r = yaml.safe_load((pathlib.Path.home()/'.hermes/hosts'/(sys.argv[1]+'.yaml')).read_text())
print(r['ssh_user']+'@'+r['ssh_host'])
PY
)
ssh -o BatchMode=yes -o ConnectTimeout=15 "$currency_target" \
  '/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/empty /usr/bin/sudo -n /usr/local/bin/chief-update'
ssh -o BatchMode=yes -o ConnectTimeout=15 "$currency_target" \
  '/usr/bin/python3 - /usr/local/lib/hermes-host-bootstrap/hermes_converger' \
  < currency-step0-digest.py > currency-installed.digest
cmp currency-step0.digest currency-installed.digest
# STOP on any mismatch; do not invoke an unreviewed payload as root.
ssh -o BatchMode=yes -o ConnectTimeout=15 "$currency_target" \
  '/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/empty /usr/bin/sudo -n /usr/local/bin/hermes-converger'
```

The shim on the last command verifies the legacy payload and copies it to the
fixed `/opt/chief` home. New plists/units reference only that home. No post-closure
operation depends on a retained passwordless grant. Existing schedulers can invoke
the new fixed launcher once it is delivered, so freeze the reviewed `main` before
step 1, compare immediately, and also collect the installed `/opt` digest.

## Plain root, preserved hosts, and unreachable Macs

h-do1 uses plain root. h-af/h-btp receive the **same foundation closure** from a
clean administrator/root session. Do not rerun the broader bootstrap or replace
chief-node/owner services. Validate their existing node.env and allowlist before
closure; existing bytes are never rewritten. If their owner config is missing
or incompatible, resolve the ownership/config contract before rollout, without
using closure to repair owner assets.

For an unreachable Mac, transfer the verified archive plus the reviewed
`install-archive.sh` using verified media. For root Linux targets, transfer the
same files through registry-derived SSH. Compare the archive SHA256 on the target
with the manager's value; transfer the installer from the same reviewed commit.
Use this Mac console shell (no login-user dotfiles):

```sh
sudo /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/root /bin/sh
```

On Linux, enter the equivalent clean shell as plain root, with `HOME=/root`.
Run the reviewed installer with the verified archive, for example:

```sh
/bin/sh /var/tmp/install-archive.sh /var/tmp/currency-step0.tar
```

The tested installer uses `umask 022` and `tar --no-same-permissions` (GNU tar and
macOS bsdtar; never `-p`), validates the extracted tree, installs into `/opt/chief`,
retains any old payload and invokes close.sh. It does not require `/usr/local`
ownership, owner credentials or an existing sudo grant.

## Completion and interruption

Closure installs safe jobs, publishes `prepared`, enables readers, then retires
all three legacy command grants. It validates original, staged and installed
sudoers and checks expanded `sudo -ll -U <runtime-user>` policy for remaining
passwordless wildcard/directory/ALL grants. An unexpected broad rule is a loud
pending-revocation failure requiring policy correction, never a success receipt.
Root itself is exempt from this check because h-do1/h-af/h-btp already use root.

Only after installed-policy validation, effective-policy checks and sync does
closure atomically write `/var/lib/chief/currency-step0/grants-removed`. Until then,
every fixed launcher resumes closure. A root-owned PID lock serializes attempts;
boot clears stale locks, and dead holders are reclaimed. Prepared retries don't
bootout their own reader. Launchd activation skips loaded jobs and retries transient
bootstrap failures. HUP/PIPE cannot abort closure: full output remains in
`/var/log/chief-closure.log`; the caller receives the final receipt when connected.
Post-preparation trust failures refuse that run and retain enabled readers for retry.

Require all of the following per host:

- `closure-status` reports `grants: removed`, `hold: none`, `jobs: enabled`, and the
  separate grants-removed marker exists. Nonsecret status is world-readable.
- Login-user `sudo -n -l` and administrator effective-policy inspection show no
  passwordless access to any legacy or canonical privileged entry point.
- Plist/unit argv points to `/opt/chief/bin`; all root jobs are enabled/loaded.
- Root ownership/trust of the interpreter and installed payload; the `/opt`
  payload digest matches the reviewed source. node.env is present and correct;
  any previously correct file retains its inode, mtime and exact bytes.
- Core receives check-ins and health, and a qualified full-wake plan demonstrably
  converges. Verify login, boot, lid-open/full wake and network return, plus the
  headless mini and GUI-absent cases. Dark/unknown wake emits health/deferred only.

A no-interpreter/config/override hold still removes unsafe grants, but exits
nonzero and leaves a visible failed rollout. Fix it through remaining administrator
access; never restore legacy grants. It does **not** meet the product-owner goal.

## Remote wake qualification and cadence

Use review option (b), a `wake_qualified` boolean **inside the HMAC-bound plan**.
No per-Mac root marker or post-closure console visit is needed. The minimal producer
change is shipped as `patches/chief-core-step0-wake-qualified.patch`; apply/review
it in Core's normal release checkout before rollout:

```sh
git -C "$chief_core_checkout" apply --check "$bootstrap_checkout/patches/chief-core-step0-wake-qualified.patch"
git -C "$chief_core_checkout" apply "$bootstrap_checkout/patches/chief-core-step0-wake-qualified.patch"
```

Deploy it through the existing Core release process. The default field is false.
After Q6 passes for a host, add that ID to the Core service's administrator-owned
`CHIEF_WAKE_QUALIFIED_NODES` comma-separated environment setting and deploy/restart
Core through that same process. For example, `h-mini2,h-air2` admits only those two
hosts; remove an ID to withdraw qualification. This changes no node secret, target,
watermark or sudo policy. Confirm a freshly fetched plan contains the boolean and
passes the unchanged signature/digest/freshness checks. No manually edited or
re-signed cached plan is an activation method. This companion patch is an explicit
rollout dependency, not a claim that Core is already deployed.

The classifier candidate reads IOPMrootDomain `SystemPowerStateCapabilities` CPU
and graphics bits, rather than physical display power. It can admit a headless Mac.
Unknown output, unqualified policy and dark wake defer mutation while health and
check-ins continue. Mutations recheck the wake epoch, signed-plan freshness and
power capability; a wake change during a run requires the next pulse to reauthorize.
Qualify on headless h-mini2, h-air2 and h-mini: the paired Q6 runs, full/dark wakes,
network returns, sleep races, latency, CPU/RSS and battery gates are still mandatory.
The fixture is not live Apple Silicon or battery evidence.

Supervisor cadence is 60 seconds. Between five-minute health reports, shell checks
all resolved targets with launchctl/systemctl/Docker; healthy no-ops start no Python.
Dark/unknown/unqualified runs still emit per-entry health and never restart,
quarantine or disable. Per-entry errors report unknown and cannot abort later
entries. Health uses the existing `/v1/observations` transport and the process-health
schema, including supervisor provenance; it no longer posts to `/v1/fleet/events`.
Exact legacy Linux-default Mac allowlists become `["chief-node"]`, with an
audit log; custom allowlists and preserved-host owner allowlists retain their bytes.

Full trust scans run at closure, boot or a root-managed identity change. The
root-only cache compares boot, selected interpreter, device/inode/owner/mode/size/
mtime/ctime for the interpreter and import-tree roots, plus entry chains. Cache
contents are never evaluated. Root-only trees cannot be modified by the login
account after verification; administrator in-place runtime changes must remove
`/var/lib/chief/currency-step0/trust-cache` first. Whole-tree replacement naturally
invalidates it. Minute no-ops do not traverse trees or start Python. Measure cost
on the actual Macs before declaring Q6 passed.

One shell writer owns node.env creation. Correct existing configs are validated
without replacement; unexpected/ambiguous content holds unchanged. Python only
loads/validates. Runtime user comes from the single reviewed host-contracts.json;
hosts/*.env and embedded revocation-user lists are deterministic generated views.
Secret paths are fixed. Stale-cache fallback retains the fetch error and all
signature/freshness checks. Runtime stamps use bounded, nonblocking, no-follow
regular-file reads. Runs have a 1,800s internal deadline (50s for supervisor), with
1,860s systemd convergence timeout; long legacy work defers/fails visibly rather
than holding the shared lock forever.

## Validation boundary

Regenerate with `python3 scripts/render-currency-step0.py`; the no-diff test checks
all copies and registry projections. Python 3.9 focused CI is defined in
`.github/workflows/currency-step0.yml` (the optional Chief SDK requires 3.11 and its
one schema test skips when unavailable). The local fix report records actual test
results and sandbox limitations. No live host, service, sudoers, deployment, Q6 or
Core-policy mutation was performed in this worktree.
