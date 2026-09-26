# Fleet currency Step 0 / A0

This is containment and the existing six-artifact converger, not the Phase A
signed updater or the Phases B–D package catalogue. Gate-2 §8 takes precedence:
h-af/h-btp foundation is managed, while their owner workloads, vaults, cron,
local code/config and Hermes runtime layouts are preserved. This installer does
not replace their existing Chief node unit, install Hermes, or touch those owner
assets. Existing plan HMAC/signature, identity, freshness and replay checks stay.
The old HMAC's exposure is **not** repaired by Step 0.

## Delivery and trust

The June-29 `chief-update` installs only `hermes_converger` and two launchers.
Consequently all closure assets travel inside `hermes_converger/step0`. After
independent review and merge to `origin/main`, a reachable Mac needs exactly two
existing privileged invocations (run them with a clean caller environment):

```sh
/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/empty /usr/bin/sudo -n /usr/local/bin/chief-update
/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/var/empty /usr/bin/sudo -n /usr/local/bin/hermes-converger
```

The second invocation stops the old root jobs, installs the fixed entry points,
repairs config, stages the triggers and either activates hardened jobs or records
a hold. Its **last privileged phase** validates original and staged sudoers with
`visudo -c`, retires all three command grants, and validates the installed policy.
There is no later passwordless step. Do not restore old launchers/grants to repair
a failed rollout. Once closed, `chief-update` is administrator-only; it fetches
fixed `main` into a fresh root checkout and repeats this same install contract.

This first remote bridge inherits the old path's TOFU assurance. It does not
prove that a machine was uncompromised before closure. Unsafe ownership anywhere
in the launcher or payload chain invokes the launcher's embedded containment
(stop jobs and revoke grants), without importing the unsafe package or Python.
Standard `/etc/sudoers.d` and macOS `/private/etc/sudoers.d` includes are supported.
Nonstandard includes are a visible hold needing administrator policy review.
Rules containing one of the retired commands are removed as a whole, including
mixed command lists; review that diff if custom rules exist. Referenced command
aliases are retained with `/usr/bin/false` so policy remains valid.

Preview (no root, network, service or filesystem changes):

```sh
/bin/sh hermes_converger/step0/close.sh --plan macos
/bin/sh hermes_converger/step0/close.sh --plan linux
```

For h-do1 and the preserved Linux hosts, use plain root. For an unreachable Mac,
use an administrator console and the same reviewed payload. Build a tar from
the reviewed merged commit on the manager, transfer it using registry-derived
SSH targets or verified media, and compare its SHA-256 before extraction:

```sh
git archive --format=tar <reviewed-main-commit> hermes_converger > currency-step0.tar
sha256sum currency-step0.tar
```

In a clean root shell on the target, with the verified archive at
`/var/tmp/currency-step0.tar` (the Mac root shell may be opened with interactive
`sudo -s`):

```sh
stage=$(/usr/bin/mktemp -d /var/root-currency-step0.XXXXXX)
/bin/chmod 0700 "$stage"
/usr/bin/tar -xf /var/tmp/currency-step0.tar -C "$stage"
. "$stage/hermes_converger/step0/trust.sh"
trusted_tree "$stage/hermes_converger"
trusted_path /usr/local/lib
trusted_path /usr/local/bin
if [ -e /usr/local/lib/hermes-host-bootstrap ]; then
    trusted_path /usr/local/lib/hermes-host-bootstrap
fi
/usr/bin/install -d -o root -m 0755 /usr/local/lib/hermes-host-bootstrap
/bin/rm -rf /usr/local/lib/hermes-host-bootstrap/hermes_converger
/bin/cp -R "$stage/hermes_converger" /usr/local/lib/hermes-host-bootstrap/
/bin/rm -rf "$stage"
exec /bin/sh /usr/local/lib/hermes-host-bootstrap/hermes_converger/step0/close.sh
```

Capture the command's stdout/stderr and exit status. Exit 0 with a hold means
**contained, not converging**. The root-owned receipt is
`/var/lib/chief/currency-step0/closure-status`; successful `visudo` output proves
the subsequent policy phase. A receipt alone does not prove grants were removed.
Inspect `sudo -n -l` as the original login user and the installed policy as an
administrator. Preserve pre-closure identity, code/launcher hashes and policy;
for h-air also capture Core's unmodified-contact/migration-required evidence
before the first command. No live rollout has been performed by this build.

## Execution and configuration

Root entry points reject **all arguments**, clear the complete environment,
change to `/`, check every lexical and symlink parent chain, and use Python
`-I -S -B` with one fixed import root. They do not execute login venvs, load user
site packages, accept environment-selected roots or forward argv. ACLs on Mac
code/import paths are conservatively refused. Root subprocesses use trusted
executables; repository hooks, Git and editable builds in a Mac login checkout
run after dropping uid, gid and supplementary groups to the registry runtime
user. Root repositories and their dependencies are checked before execution.

Linux can use the OS `/usr/bin/python3` and checked system stdlib. Macs require
a separately reviewed standalone CPython >=3.9 at `/opt/chief/python`; its
entire runtime must be root-owned, not group/world writable and without directory
symlinks or ACLs. A verified publisher/OS artifact must supply those bytes; copying
or chowning a login user's venv is not provisioning trusted code. macOS's
`/usr/bin/python3` xcrun shim and user Homebrew are deliberately not fallback
interpreters. If no trusted runtime is present, closure still repairs config and
removes grants, leaving the jobs disabled with `trusted_python_unavailable`.

The non-secret `host-contracts.json` is a 2026-09-26 projection of the authoritative
`~/.hermes/hosts/*.yaml` registry (IDs, FQDN aliases and runtime accounts), with
Core's verified tailnet URL from H2's finding. Generated `hosts/*.env` permit
config repair without Python. Existing trusted `node.env` can retain a deliberately
configured Core URL; wrong identity, missing fields or remote loopback fails
loudly. Missing config is seeded from the registry. Root-only code fixes key/token
paths and runtime user; caller values cannot override them. Installation is
atomic `root:chief 0640`. Keys, tokens and watermarks are not regenerated or reset.
Fetch failures print endpoint, original error, cache source and unchanged cache
verification policy before a stale-cache error. An administrator's Python
plan-only invocation is now filesystem-write-free, including reconcile's lock.

## Triggers and qualification

All root convergence invocations share one nonblocking lock with supervisor
control. A contending caller consumes no hints or wake/boot stamps. There are
four precreated hint slots under a root-owned, non-writable directory; the chief
group can write only the slots. Readers use `O_NOFOLLOW`, regular-file checks,
a 257-byte maximum read and a fixed enum. Oversized/unknown content is logged
and discarded; caller bytes never become commands, paths or Python arguments.
The independent minute pulse handles missed/coalesced filesystem notifications.

Mac sources are RunAtLoad, a global login LaunchAgent, minute calendar pulse,
`kern.boottime`/`kern.waketime`, and a one-second Core connectivity probe. Linux
sources are the independent boot-reconcile unit (including h-do1), a systemd user
oneshot wanted by `default.target`, a post-sleep hook, network-online ordering,
connectivity-return detection, `.path`, and the minute timer. Linger means
user-manager start at boot, not every SSH login. Normal checks are five minutes;
hints and connectivity/wake changes are rate-limited to one minute. No-op pulses
start no Python; logs distinguish no-op from check and record wake admission.

A0 uses a small shell pulse so the old code-only delivery seam can carry closure
without a compiler or a new binary distribution path. **This is a candidate for
the Q6 measurements, not a claim to have passed the Go pulse cost gate.** Phase
A's Go runtime is not implemented here. The manager/reviewer must qualify this
choice or replace the pulse before Mac mutation cutover. There is no forced wake,
IOKit listener, power assertion or power-setting change.

Mac default is report-only, even at full wake. Only after the two paired 24h runs
on h-mini2/h-air2 and then h-mini pass §6 (20 full wakes, 10 dark wakes, 10 network
returns, latency, CPU/RSS and battery gates) may an administrator create
root-owned `/etc/chief/wake-qualified`. A display-on IODisplayWrangler state is
then required before convergence and each mutation boundary. Dark, unknown and
unqualified wake never authorize package actions or supervisor restart/quarantine.
A sleeping process resumption/race and the classifier must be tested on real Macs
before creating that marker. No classifier/cost evidence was fabricated here.

Root systemd units have fixed argv and no caller environment file. Per-unit
overrides are moved into the root-only state directory for audit; effective
global/type-wide overrides cause a hold, without editing owner/global policy.
Existing owner/node workload units are preserved. Core startup does not depend
on successful reconciliation. Mac supervision resolves `chief-node` to its
configured `gui/<uid>/com.chief.node`, watchdog to `system/com.chief.loop-watchdog`,
and Core to Docker. Missing GUI defers restarts. Legacy Linux IDs still work;
Mac restart counters have a new backend/domain/target key, preserving the five
restarts per ten minutes ceiling without transferring the old wrong-target count.

## Review and validation boundary

`render-currency-step0.py` regenerates the standalone launchers and payload copies
from the reviewed source files; run it after changing trust, containment, units,
plists, scripts or registry projection. The repeated guard is required by the old
updater's two-file copy seam, not a second independent implementation.

Fixture tests exercise both closure OS paths with Python absent, config repair,
policy validation failure, argv/environment/import/interpreter attacks, parent
and symlink checks, stale-cache reporting, target mapping, no-GUI, coalescing,
hint limits and zero-Python no-op pulses. No tests need root or external network.

The r7 immediate-restore MINOR is applied to existing legacy exception handling:
the one restore runs before its lease is released. The remaining r7 findings
concern Phase B compiled deadline ceilings/per-target stop rules, the product
owner's acceptance-1 choice, resumable Phase A bundles, or the EDD comparison and
future worker-state glossary. Those have no implementing worker/protocol here
and remain explicit later-phase work. The optional v0 acceptor, enrollment/key
retirement, A/B recovery, packages, Hermes/CLI currency and live acceptance 4–5
are not claimed by these fixtures.
