# Desktop fleet gateways — build 1 rollout addendum

This supplements EDD-chief-desktop-fleet-gateways §6, especially step 2. The
build and review perform only fixture checks; they do not authorize host changes.

1. The bootstrap code can merge before the extended Intent. Legacy behavior applies
   only when Intent is absent at every candidate path or has no rollout declarations
   anywhere. Candidates are `$HERMES_FLEET_INTENT`, `$HERMES_HOME/fleet/hosts.yaml`,
   `~/.hermes/fleet/hosts.yaml`, and `/opt/hermes-config-baseline/fleet/hosts.yaml`.
   An explicit `--registry` is considered first. A nonempty `$HERMES_FLEET_INTENT`
   must exist. A declared selected copy keeps precedence; if it is undeclared
   (including missing PyYAML without raw declaration tokens), every other existing
   candidate must also be undeclared. A declared, unreadable or malformed alternate
   refuses legacy behavior. Declared but unreadable/incomplete policy is refused,
   including missing PyYAML when raw text contains rollout keys.
   A present marker blocks updates and requires
   protected policy plus `dashboard_vehicle: module97` for module 97. New enrollment, marker installation
   and preserved-node apply require their explicit declarations and fail closed.
   Verification reports an unconfigured desktop rollout without failing existing
   hosts. It does not claim G3 or desktop qualification.
2. Before enabling the new protection/enrollment actions, land and review the
   hermes-config change for all seven hosts: one consistent `update_policy`,
   `desktop_gateway` declarations and top-level `complete: true`. Declare
   `desktop_gateway.dashboard_vehicle: module97` only for h-do1 among the protected
   hosts. h-btp and h-af must use the reviewed preserved-node vehicle. Confirm a
   Hermes venv with PyYAML (or `HERMES_FLEET_PYTHON`) on each host. This is an
   activation gate; legacy compatibility is not evidence that protection is armed.
   On h-btp and h-af, record which candidates exist; any higher-precedence copy
   must be byte-identical to `/opt/hermes-config-baseline/fleet/hosts.yaml` or removed.
3. Schedule a one-time dashboard refresh on the first new module 97 apply to h-do1
   and the Phase-A Macs. The rendered unit/plist and credential digest are new.
   Subsequent healthy, identical applies do nothing; owned credential/public-URL
   changes refresh the service, and failed refreshes retry on the next apply.
   Credential digests are stored mode 0600 (root-owned on Linux, user-owned on Mac).
   On a Mac bootstrapped over SSH without a GUI session, module 97 may fail at launchd bootstrap; log in and reapply to retry the pending refresh.
4. The Mac launcher moves from `/usr/local/bin` to `~/.local/bin`; the old copy is
   left unused and may be removed only after checking for other references. Linux
   retains tailscaled ordering, startup limits and `/root/.local/bin` PATH coverage.
   It explicitly runs as the verified invocation runtime account, rather than a
   hardcoded root account. Confirm that account/HOME tuple before rollout. The
   renderer in `scripts/desktop_fleet/dashboard.py` replaces both retired templates.
5. Before bumping the preserved-node `/opt` pin, qualify the actual h-btp layout.
   Plan and Intent must contain the **resolved regular executable path**, its
   digest, and a `build_identity` with `kind: dist-info-record`, the installed
   package's `.dist-info/RECORD` path and SHA-256. A `.local/bin/hermes` symlink may
   exist but must not be the declared executable. Confirm that RECORD identifies
   the installed package (not an editable source checkout); otherwise a separately
   reviewed build-identity adapter is required. No real host layout or build has
   been qualified by these fixtures.
6. Backups contain original file bytes plus mode/uid/gid/digest metadata. An
   existing `.env` retains ownership/mode. Apply rechecks bytes and metadata before
   each replacement and refuses detected concurrent writes. Per-file replacement
   is atomic, not a transaction across files; inspect backups after any partial
   failure. Quiesce the `.env` writers during the approved apply window: the running
   Hermes gateway and web UI (`config_env` writes), `hermes config set`, and bootstrap
   modules 35/92 (`op inject`). After replacement and refresh, apply rereads `.env`
   and requires each projected assignment to be present exactly once with its
   projected value; a stale writer causes apply to fail and leaves refresh pending.
   Rebuild the plan from current `.env` bytes (fresh `prior_sha256`), then re-apply;
   the retained stamp forces the refresh.

The EDD's app artifact/rollback pin, h-do1 capacity gate, owner consents, ingress,
authentication/revocation checks and Mac retention canary remain required. The
h-af non-systemd/:8787 adapter is still deferred. No host, credentials or `/opt`
pin changes are included in this build.
