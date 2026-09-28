# Fleet currency Step 0 / A0 — fix round 6

Step 0 closes the legacy privilege grants and retains the existing authenticated,
six-artifact converger. Success requires active root readers, boss check-ins,
qualified full-wake convergence and supervision on every Mac. **Disabled root jobs
are a failed rollout**, even if containment succeeded. No rollout has been run by
these fixtures. Phases A–D, new package adapters and HMAC retirement remain outside
this change. Gate-2 §8 governs h-af/h-btp: foundation closure applies; their vaults,
credentials, cron, local code/config and owner workloads are preserved.

## Mandatory first step on every host

Before any live closure, bridge, archive installation or administrator update, run
`close.sh --preflight` from a **reviewed root-owned payload** in a clean root
shell. This applies to every Mac and Linux host, including preserved h-af/h-btp.
**Bridge hosts, including h-mini2 retries, must use the `/usr/local/.../close.sh
--preflight` command under [Reachable Macs](#reachable-macs-with-a-trusted-legacy-delivery-path), after the reviewed
legacy update.** A private-directory PASS does not gate that bridge's launcher
or source tree. For the archive route, use an absolute path to the reviewed
script; preflight can run from a private extracted review directory before `/opt/chief` exists. Its
path must be symlink-free; on macOS use `/private/var/root/...`, not `/var/root/...`:

```sh
# currency_review is the administrator's verified, root-owned extracted payload.
/bin/sh "$currency_review/hermes_converger/step0/close.sh" --preflight
```

Require exit 0 and retain the complete output before proceeding. This mode
collects trust/path, isolated interpreter/import, hostname/host-contracts,
config/allowlist, original and rendered sudo policy, effective grants, lock and
job-definition holds. It checks prospective destinations against their existing
parent chains. It never writes files, takes a lock, populates the trust cache,
rotates logs, installs/stops jobs or revokes grants. Rendered policy goes through
`visudo -c -f -` on stdin. Missing required tools or unavailable dependent checks
hold. Before sourcing a helper, the script checks its uid, write permissions,
file type and every lexical parent inline; macOS ACLs and symlinks hold too.
The legacy-path preflight also checks the bridge launcher and full source tree
before preparation. A private archive preflight checks its own source and `/opt`
destinations; that route does not execute the legacy bridge. Resolve **all** printed reasons, then repeat preflight. A pass describes
the current files and policy; closure still repeats its checks and can fail if
state changes or an activation command fails.

For an already installed reviewed build, the command is:
`/bin/sh /opt/chief/lib/hermes-host-bootstrap/hermes_converger/step0/close.sh --preflight`.
Do not use the older canary's installed script for this gate. Extract the new
reviewed build first. The fixed public launchers still accept no arguments.

## Before delivery

Use the authoritative `~/.hermes/hosts/<id>.yaml` for SSH targets. Capture installed
code and launcher hashes, config bytes/modes, policy and unit definitions. Capture
h-air's unmodified-contact/migration-required evidence before changing its oldest
bytes. Merge only after independent review and the green Python 3.9 CI gate below; **this build does not push**. Keep
`origin/main` at the reviewed commit during the two-command legacy bridge.

Build on the manager (set `currency_commit` to the reviewed merged commit):

```sh
git -c tar.umask=022 archive --format=tar "$currency_commit" hermes_converger > currency-step0.tar
git show "$currency_commit":hermes_converger/step0/install-archive.sh > install-archive.sh
sha256sum currency-step0.tar install-archive.sh
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
/bin/hostname
# Set runtime_user from this host's reviewed registry record (dano or danz).
# Administrator read-only policy inspection, including the no-rules exit status:
sudo -ll -U "$runtime_user"; echo "sudo-list-status=$?"
/Library/Developer/CommandLineTools/usr/bin/python3 -I -S -B -c 'import sys; sys.path.append("<review dir>"); import hermes_converger.core, hermes_converger.runtime, hermes_converger.supervisor'
/usr/sbin/ioreg -r -n IOPMrootDomain -d 1
/usr/sbin/sysctl -n kern.bootsessionuuid
# After sourcing the reviewed trust.sh in that clean shell:
trusted_python
trusted_path /usr/local/bin
trusted_path /usr/local/lib/hermes-host-bootstrap
```

Replace `<review dir>` with the extracted reviewed payload's parent. Record the
real CLT import result, not just its version. `/bin/hostname` must resolve through
`host-contracts.json`, especially on h-mini2 before node.env exists. Confirm ioreg
prints a parseable `"System Capabilities"` bitmask (legacy
`"SystemPowerStateCapabilities"` is an absence-only fallback), including headless minis.
Inspect expanded sudo policy: stop closure if any remaining passwordless `ALL`,
wildcard or directory rule reaches a Chief root entry. Qualify `sudo -ll -U` on
the host's sudo version, including a known no-rules user: a nonzero result holds
revocation and must be resolved before rollout, not treated as empty policy.

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
before closure. Record `chief-node.service`'s `After` on **h-do1 and h-af** as
well as h-btp. Boot reconcile is `Type=exec`, with no network-online ordering,
`Before=` or `Requires=` coupling. An existing owner `After=reconcile` waits only
for exec, never for reconciliation or its restarts. `RuntimeMaxSec=1860` bounds
the worker independently of its 10s exec-start limit and 1,800s internal deadline.
Prove node and Core startup proceed during a slow reconcile/Core outage and a
restart-required plan. No owner unit is rewritten.

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
# STOP on drift. This login-user/xcrun result is NOT adversarial integrity proof.
```

After `chief-update` and the digest comparison, run this command **on the Mac as
the login user**, from the root-owned install path. It needs **administrator sudo**
(interactive password where required), not the retiring command grants. Never
run the preflight script from a login-user checkout. Require exit 0 before the
final bridge invocation:

```sh
sudo /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/empty LANG=C \
  /bin/sh /usr/local/lib/hermes-host-bootstrap/hermes_converger/step0/close.sh --preflight
# Only after PASS, as the login user on that same Mac:
sudo -n /usr/local/bin/hermes-converger
```

The shim on the last command verifies the legacy payload and copies it to the
fixed `/opt/chief` home. An explicit legacy invocation before `prepared` exists
refreshes a previously copied payload, including h-mini2 after the `/var/run`
hold; fixed installed readers never select a legacy copy. After preparation,
repeat invocations resume the existing closure/readers. New plists/units reference
only that home. No post-closure operation depends on a retained passwordless grant. Legacy schedulers that pass
arguments are refused until closure installs the new argv-free definitions.
Freeze reviewed `main` before step 1 and compare immediately. The login-user
xcrun digest detects drift only; the trusted-root `/opt` digest in the completion
proof is the integrity evidence. An interrupted bridge copy stays in a private
sibling staging directory; only a complete verified copy is renamed into place.

## Plain root, preserved hosts, and unreachable Macs

h-do1 uses plain root. h-af/h-btp receive the **same foundation closure** from a
clean administrator/root session. Do not rerun the broader bootstrap or replace
chief-node/owner services. Validate their existing node.env and allowlist before
closure; existing bytes are never rewritten. If their owner config is missing
or incompatible, resolve the ownership/config contract before rollout, without
using closure to repair owner assets.

h-do1's reviewed host record sets `CHIEF_CODE_ROOT=/opt/chief/deploy`, as required
by the product-owner amendment of 2026-09-27 in the fleet software currency EDD.
Its converger uses a separate deployment checkout; it must never fetch into,
check out or restart from the development tree `/root/code/chief/*`.
Only trusted `/etc/chief/node.env` supplies this override; caller environment is
discarded. The key accepts only `/opt/chief/deploy`, on Linux with runtime user
`root`. Before git/build operations, the deployment root, its `hermes-node`
directory and their parents must be root-owned directories, without symlinks or
group/world write access. Existing node.env files stay byte-identical, including
files without this optional key. For rollout, add the matching key to h-do1's
trusted config and cut `chief-node.service` over to the deployment checkout;
closure does not perform that service cutover.

For an unreachable Mac, transfer the verified archive plus the reviewed
`install-archive.sh` using verified media. For root Linux targets, transfer the
same files through registry-derived SSH. Record **both** SHA256 values on the
manager through the trusted review channel; a digest file on the same untrusted
media is not authority. Use this Mac console shell (no login-user dotfiles):

```sh
sudo /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/root /bin/sh
```

On Linux, enter the equivalent clean shell as plain root, with `HOME=/root`.
Copy both transferred files into a fresh private root directory **before** any
verification or execution. In that clean root shell, set both expected values
from the manager's trusted record, never from transfer-account-controlled files:

```sh
umask 077
currency_private=$(/usr/bin/mktemp -d "$HOME/currency-delivery.XXXXXX")
/bin/chmod 0700 "$currency_private"
/bin/cp /var/tmp/install-archive.sh "$currency_private/install-archive.sh"
/bin/cp /var/tmp/currency-step0.tar "$currency_private/currency-step0.tar"
currency_installer_sha='<manager installer SHA256>'
currency_archive_sha='<manager archive SHA256>'
# macOS (on Linux use /usr/bin/sha256sum instead of shasum -a 256):
currency_actual=$(/usr/bin/shasum -a 256 "$currency_private/install-archive.sh")
[ "${currency_actual%% *}" = "$currency_installer_sha" ] || exit 1
currency_actual=$(/usr/bin/shasum -a 256 "$currency_private/currency-step0.tar")
[ "${currency_actual%% *}" = "$currency_archive_sha" ] || exit 1
/bin/sh "$currency_private/install-archive.sh" \
  "$currency_private/currency-step0.tar" "$currency_archive_sha"
/bin/rm -rf "$currency_private"
```

The installer takes the expected archive digest, makes another private root-owned
copy, verifies **that copy**, and only then extracts/sources/installs its bytes.
Replacing or modifying either original transfer file after copying has no effect.
Never execute the installer directly from `/var/tmp`, media or a login checkout.

The tested installer uses `umask 022` and `tar --no-same-permissions` (GNU tar and
macOS bsdtar; never `-p`), validates the extracted tree, installs into `/opt/chief`,
invokes close.sh after publishing a complete replacement. It removes the previous
payload only after publication, or restores it when the destination is absent.
A failed partial copy leaves the previous payload at the printed recovery path. It does not require `/usr/local`
ownership, owner credentials or an existing sudo grant.

Subsequent administrator Git updates require an explicit reviewed 40-hex commit:
`/bin/sh /opt/chief/lib/hermes-host-bootstrap/hermes_converger/step0/update.sh "$currency_commit"`
from the clean root shell above. The argv-free `chief-update` launcher cannot select
a commit and returns usage; use the direct administrator script or pinned archive.

## Completion and interruption

Closure installs safe jobs, publishes `prepared`, enables readers, then retires
all three legacy command grants. It validates original, staged and installed
sudoers and checks expanded `sudo -ll -U <runtime-user>` policy for remaining
passwordless wildcard/directory/ALL grants. An unexpected broad rule is a loud
pending-revocation failure requiring policy correction, never a success receipt.
Root itself is exempt from this check because h-do1/h-af/h-btp already use root.

Only after installed-policy validation, effective-policy checks and sync does
closure atomically write `/var/lib/chief/currency-step0/grants-removed`. Until then,
a fixed launcher resumes closure. Interrupted attempts retry immediately; a
completed revocation failure records its exact reason and retries at most once
per 15 minutes. During that interval, and when closure returns 75 for a busy or
interrupted lock handoff, the prepared pulse and supervisor continue check-ins
and health. The updater still exits on 75 without replacing the payload.
After administrator policy repair, clearing the root-owned
`revocation-retry` stamp permits an immediate retry. A root-owned PID lock serializes attempts;
Linux: boot clears the lock; macOS: boot UUID selects a new lock name.
Dead holders on the current boot are reclaimed under an atomic reclaim guard. A live holder returns
nonzero (75), with revocation pending; this is not installation success. Prepared
retries and re-closure with matching reviewed job definitions don't stop their own
reader. Administrator updates publish a preparing receipt and stop jobs before
replacing any payload or removing markers. Launchd activation skips loaded jobs and retries transient
bootstrap failures. The bridge, both installers and closure ignore HUP/PIPE.
Installer cleanup restores or retains the previous payload if publication fails;
even a failed restore never deletes the only remaining copy. All closure output remains in
`/var/log/chief-closure.log`; the caller receives the final receipt when connected.
Post-preparation trust failures refuse that run and retain enabled readers for retry.
Preparation publishes `hold: preparing` before stopping unsafe jobs. Every trigger
is disabled before any service is stopped, so even termination of a legacy caller
leaves a visible hold without a repeating Linux timer. Failure publishes `hold: contained:<reason>`, with
`jobs: disabled` and `grants: removed|pending`; old success receipts cannot survive.
A stopped/contained host requires an administrator re-run of the reviewed closure.
A prepared activation failure says `jobs: activation_pending` until all daemon
activation commands succeed; it does not claim enabled readers.

Require all of the following per host:

- `closure-status` reports `grants: removed`, `hold: none`, `jobs: enabled`, and the
  separate grants-removed marker exists. Nonsecret status is world-readable.
- Login-user `sudo -n -l` and administrator effective-policy inspection show no
  passwordless access to any legacy or canonical privileged entry point.
- Plist/unit argv points to `/opt/chief/bin`; all root jobs are enabled/loaded.
- Root ownership/trust of the interpreter and installed payload; the `/opt`
  payload digest matches the reviewed source. node.env is present and correct;
  any previously correct file retains its inode, mtime and exact bytes.
- Lens/Core shows a fresh **converger** check-in (`step0_check`/reconcile evidence),
  not merely hermes-node heartbeats. Check this after every macOS major upgrade:
  removal/replacement of CLT otherwise leaves a running node but stale convergence.
  Alert on missed converger checks after 300 awake/online seconds plus the measured
  run duration; investigate runtime holds in root logs. Phase A's root-owned
  `/opt/chief/python` runtime is the durable fix for this CLT dependency.
- Core receives check-ins and health, and a qualified full-wake plan demonstrably
  converges. Verify login, boot, lid-open/full wake and network return, plus the
  headless mini and GUI-absent cases. Dark/unknown wake emits health/deferred only.
- After a Mac reboot clears `/var/run`, verify that a RunAtLoad root reader
  recreates `/var/run/chief/runtime` as `root:chief 0770` without administrator
  repair. Require a fresh converger check-in and a restart-required plan reaching
  `applied` with a new login-user runtime stamp, not `runtime_ack_timeout` or
  `rollback_unverified`. Record this post-reboot restart-convergence proof.

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

The classifier reads IOPMrootDomain `"System Capabilities"` as a decimal bitmask:
CPU=1, Graphics=2, Audio=4, Network=8. CPU **and** Graphics must be present
(`caps & 3 == 3`); Audio/Network alone never admit a wake. These are system
capabilities, independent of physical display power, so the classifier can
recognize a headless mini.
Only absence of the primary key permits `SystemPowerStateCapabilities` fallback;
malformed primary values remain report-only. The real 26.5.2, 26.3.1 and 15.6.1
captures in `tests/fixtures/macos-paths-ioreg.txt` all contain 15 and no legacy key.
`IOPMUserTriggeredFullWake`, `Wake Type`, `Wake Reason` and `SleepWakeUUID` are
not admission signals: this snapshot does not prove they describe current
capabilities rather than wake history. Both shell and Python use the same rule.
Unknown output, unqualified policy and dark wake defer mutation while health and
check-ins continue. Mutations recheck the wake epoch, signed-plan freshness and
power capability; a wake change during a run requires the next pulse to reauthorize.
Qualify on headless h-mini2, h-air2 and h-mini: the paired Q6 runs, full/dark wakes,
network returns, sleep races, post-reboot restart-convergence, latency, CPU/RSS
and battery gates are still mandatory. Q6 must include a reboot that clears
`/var/run`, automatic directory recreation by either root reader, a fresh check-in,
and a restart-required plan verified by a new login-user runtime stamp.
The fixture is not live Apple Silicon or battery evidence.

macOS `/var/run` (`/private/var/run`) is `root:daemon 0775` on all three measured
OS versions. Trust still rejects every group-writable directory; there is no
`daemon` exception. The closure lock now lives at
`/var/lib/chief/chief-currency-closure.<bootsessionuuid>.lock`, reconciliation at
`/var/lib/chief/reconcile.lock`, and leases at `/var/lib/chief/convergence`.
These locks use trusted root-writable parent chains. Runtime stamps are the only
macOS `/var/run` use: producer and consumer both use `/var/run/chief/runtime`.
That directory is login-user-written data (`root:chief 0770`); it is not
trust-checked. The product owner's accepted rationale is that the producer is
the login-user node attesting its own restart. A same-group writer gains nothing
it could not already do, since it controls the node process. Code and root state
stay strictly trust-checked. Preflight accepts the documented producer setup in
[the runtime-directory repair](chief-node-source-reconciliation.md#missing-macos-runtime-directory).
The reader still requires bounded, no-follow regular files. Both RunAtLoad root
readers now provision the volatile directory before service control, under the
existing shared worker lock. Missing proof directories bypass cadence no-ops.
The provisioner uses `mkdir` (`os.mkdir`, never `install -d`), then lstat-checks
each entry as a root-owned directory, rejecting links and non-root entries with
a loud HOLD. It checks group/mode before any correction and pins the verified
directory with a no-follow descriptor for `fchown`/`fchmod`; final metadata must
be `root:chief 0750` for `chief` and `root:chief 0770` for `runtime`. These are
provisioning checks, not an assertion that runtime-proof data is trusted.
Closure does not rewrite owner jobs. Live reboot proof remains a rollout gate.
Linux uses `/run` for locks and `/run/chief/runtime` for runtime stamps.

The audit also covers the shared worker/supervisor `run.lock`, trust cache, pulse
boot/wake/online/check stamps and supervisor targets under
`/var/lib/chief/currency-step0`; journals/restart limits under
`/var/lib/chief/converger`; request slots under `/var/lib/chief/requests`; and
update staging under `/opt/chief/lib`. Only runtime-proof directory provisioning
uses `/var/run` as a root writer. Closure, preflight, pulse and trust cache use `kern.bootsessionuuid`,
which identifies the boot independently of timezone, wall-clock and wake changes.
Preflight requires that sysctl to succeed on the target; capture its output on
both macOS 15 and 26 before rollout. Native version availability has not been
verified in this Linux fixture environment (the public-source lookup was blocked
by sandbox DNS), so those captures remain a rollout gate.

Old-boot directories never collide with the current UUID name and may be removed
by an administrator after preflight. A live PID retains the current-boot lock.
Dead-PID reclaim has one writer, elected by atomic `mkdir` of `<lock>.reclaim`,
and rechecks liveness under that guard. If killed during PID publication or
reclaim, the next attempt and preflight report `closure_pid_publication_pending`
or `closure_reclaim_pending`. After verifying no closure is running, an
administrator may remove that UUID's incomplete lock/guard and repeat preflight;
a reboot also selects a fresh name. Prepared readers continue check-ins and
health on exit 75 while leaving the ambiguous lock/guard untouched. Neither path blindly reclaims a live or
unpublished holder. Python's flock locks are released by the kernel on exit/reboot
even though their files persist; pulse and trust cache invalidate old observations.

Supervisor cadence is 60 seconds. Between five-minute health reports, shell checks
all resolved targets with launchctl/systemctl/Docker. Python records the observed
state of each target; unchanged healthy, dead, GUI-absent and quarantined targets
start no Python between reports. A transition reports immediately. An admitted
failed restart may retry at 60s while its limiter allows; Python rechecks admission
and wake before each action. Stable report-only targets report once per 300s.
Dark/unknown/unqualified runs still emit per-entry health and never restart,
quarantine or disable. Per-entry errors report unknown and cannot abort later
entries. Health uses the existing `/v1/observations` transport and the process-health
schema, including supervisor provenance; it no longer posts to `/v1/fleet/events`.
Exact legacy Linux-default Mac allowlists become `["chief-node"]`, with an
audit log; custom allowlists and preserved-host owner allowlists retain their bytes.

Full trust scans run at closure, boot or a root-managed identity change. The
root-only cache compares boot, selected interpreter, device/inode/owner/mode/size/
mtime/ctime for the interpreter and import-tree roots, plus `trust.sh`, `pulse.sh` and `supervise.sh` identities. Cache
contents are never evaluated. Every pulse validates all fixed entry/state/config
parent chains with one batched stat and one Mac ACL listing before sourcing code.
Data under the verified root-written state directory uses shell builtin reads.
The fixture ceiling is ten child processes (including subshells)
per no-op; the Mac Bash fixture uses seven for the pulse and five for supervision.
The Mac pulse uses one sysctl, one ioreg and one bounded network probe. In the
already-clean shell, Bash's own EUID/OSTYPE avoid id/uname startup; other shells
use the portable commands. No caller environment reaches that choice.
The Core probe allows three seconds and retries once on failure. Offline periodic
no-ops start no Python for at most 30 minutes since the last check; the next due
periodic check runs even if both probes still fail. Explicit triggers remain due.
Root-only trees cannot be modified by the login
account after verification; administrator in-place runtime changes must remove
`/var/lib/chief/currency-step0/trust-cache` first. Whole-tree replacement naturally
invalidates it. Minute no-ops do not traverse trees or start Python. Measure cost
on the actual Macs before declaring Q6 passed. First record a no-op on h-mini2
with `/usr/bin/time -l /opt/chief/bin/hermes-converger` from the administrator
shell. Then collect 1,440 no-op samples (full checks measured separately), including
the independent supervisor cost, and enforce §6: p95 CPU ≤50ms, total ≤72 CPU-s,
RSS ≤20MiB, zero no-op Python and ≤1 percentage-point/day battery increase.
Record Core `/health` probe latency and retry frequency on h-mini2/h-air2, including
cold and relayed Tailscale paths; the probe can take up to six seconds on failure.
The Mac entry trust/ACL batch also checks the six daemon stdout/stderr logs.
At each entry, any log at or above 1 MiB is truncated in place before new output;
open launchd append descriptors remain valid. This bounds minute-log accumulation
to the threshold plus output between entries without a new per-minute process.

One shell writer owns node.env creation. Correct existing configs are validated
without replacement; unexpected/ambiguous content holds unchanged. Python only
loads/validates. Runtime user comes from the single reviewed host-contracts.json;
hosts/*.env and embedded revocation-user lists are deterministic generated views.
Secret paths are fixed. Stale-cache fallback retains the fetch error and all
signature/freshness checks. Runtime stamps use bounded, nonblocking, no-follow
regular-file reads. Runs have a 1,800s internal deadline (50s for supervisor), with
1,860s systemd convergence timeout; long legacy work defers/fails visibly rather
than holding the shared lock forever.

## Merge and rollout conditions (not proven by code review)

- **Before merge:** independent review closes the code findings, all fixture and
  static checks pass, and `.github/workflows/currency-step0.yml` is green under
  real Python **3.9** for the reviewed commit. A local newer-Python run is not that gate.
- **Before each closure:** all Mac/Linux preflight above passes, including the real
  CLT isolated imports, hostname mapping, expanded sudo policy/no-rules exit status,
  ioreg property, effective unit ordering/overrides, and preserved-owner inventory.
  Capture the oldest h-air bytes and Core migration response first.
- **Before Mac mutation:** review/deploy the companion Core patch; inspect each
  Mac's live authenticated plan. Step 0 admission currently assumes **exactly one
  desired row with its matching auth row**. Zero or multiple rows fail closed;
  resolve that shape before qualification, without editing/signing cached plans.
  Run Q6 paired 24h baseline/enabled tests on h-mini2/h-air2 then h-mini, covering
  AC/battery, closed-lid sleep, ≥20 full wakes, ≥10 dark wakes and ≥10 network
  returns, sleep races, post-reboot restart-convergence, headless and GUI-absent
  cases. Zero observed dark wakes
  leaves qualification pending. Require zero dark-wake mutations, check-in ≤300s
  on full wake/return, and all CPU/RSS/battery caps above. Only then enable each
  node in `CHIEF_WAKE_QUALIFIED_NODES` and verify a fresh signed boolean.
- **Before completion:** require the per-host proof above, qualified convergence
  and supervision, independent node/Core boot under outage/restart, root digest
  equality, revoked grants and active readers. Include converger staleness after
  CLT replacement/OS upgrade. Disabled or report-only Macs are not rollout completion.

## Validation boundary

Regenerate with `python3 scripts/render-currency-step0.py`; the no-diff test checks
all copies and registry projections. Python 3.9 focused CI is defined in
`.github/workflows/currency-step0.yml` (the optional Chief SDK requires 3.11 and its
one schema test skips when unavailable). The local fix report records actual test
results and sandbox limitations. No live host, service, sudoers, deployment, Q6 or
Core-policy mutation was performed in this worktree.
