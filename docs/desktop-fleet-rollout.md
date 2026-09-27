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

   **Reader ordering is an activation gate before the declared Intent merges.**
   Record the deployed SHA for every bootstrap checkout that can read it on
   h-do1, h-mini, h-mini2, h-air and h-air2, including cached/collector copies.
   Every reader must contain slice 1.1 (`55daa05` and its final fix `dbb6e63`)
   and this slice 1.2 client gate. Slice-1 readers ignore marker deferral and
   admission; slice-1.1 readers still install the client on every Mac.
   Offline hosts do not waive this ordering gate. Follow each Mac's Step 0 and
   owner window requirements before advancing its checkout.
2. Before enabling the new protection/enrollment actions, land and review the
   hermes-config change for all seven hosts: one consistent `update_policy`,
   `desktop_gateway` declarations and top-level `complete: true`. Declare
   `desktop_gateway.dashboard_vehicle: module97` only for h-do1 among the protected
   hosts. h-btp and h-af must declare `dashboard_vehicle: preserved-node`.
   Every protected host must explicitly declare `desktop_gateway.g3_marker` as
   `deferred` or `armed`; absent, null or other values are refused. **Step 2 sets
   `g3_marker: deferred` on h-do1, h-btp and h-af** until the software-currency
   reconciliation is built and qualified. The four Macs stay `eligible`, may omit
   `g3_marker` or declare `deferred`, and must never declare `armed` or receive a marker.

   | Host | `update_policy` | `desktop_gateway.admission` | `desktop_gateway.g3_marker` | Vehicle |
   |---|---|---|---|---|
   | h-do1 | protected | deferred (HELD until capacity GO) | deferred | module97 |
   | h-btp | protected | pending-qualification | deferred | preserved-node |
   | h-af | protected | pending-qualification | deferred | preserved-node |
   | h-air2 | eligible | pending-qualification; endpoint null | omitted | module97 |
   | h-mini, h-mini2, h-air | eligible | admitted after their rollout gates | omitted | module97 |

   Client installation is independently enabled per host with the optional
   **host-row** field `desktop_client: enabled` (a sibling of `desktop_gateway`).
   In declared Intent, omission means `desktop_client: deferred`; the only valid
   values are `enabled` and `deferred`. Invalid values refuse the operation.
   Declaration alone never enables a client. Change a host to `enabled` in the
   same reviewed Intent commit as that host's rollout window, **h-mini2 first**,
   after its app/plugin pin, canary prerequisites and owner approvals are met
   (including h-air's custom app approval). Subsequent hosts wait for the canary
   proof. This desired state also applies when an offline host returns; local
   `SKIP_KEYS` changes are not the rollout gate.

   Module 98 and `fleet-enroll-existing --desktop-only` both use the install
   gate: `deferred` exits 0 without creating directories or writing the manifest,
   checklist, live plugin, receipt or tools. The client identity is the short
   hostname (or explicit `--client`), matched exactly to `hosts[].hostname`.
   A missing/duplicate client row still refuses with a nonzero exit and no writes.
   `enabled` retains the existing installation and post-build app-pin checks;
   enabling it does not itself qualify the app. Legacy/undeclared behavior stays
   unchanged, including optional install's `not-configured` result.

   Client verification reports `deferred (client deferred for HOST; ...)`, exit
   0, using the marker's existing `status: deferred` reporting shape for the
   registry, plugin-version and app-pin checks. Any leftover manifest, plugin,
   receipt, checklist or tools are listed as untouched; deferral does not unload
   or uninstall a previously enabled plugin and asserts no qualification.
   Before activation, Chief must render `deferred` neutrally: the existing
   slice-1.1 r1 MINOR 2 consumer fix is still required in Chief, separately from
   this bootstrap change. An enabled client without its manifest still fails
   verification until installation runs.

   `deferred` blocks marker creation, restoration and suspension at every writer;
   any pre-existing marker remains untouched. Explicit backup remains available.
   Module 97 skips the deferred marker step. G3 verification reports
   `deferred (not protected; convergence reconciliation pending)` as a warning
   (`status: deferred` in JSON), with human/JSON reporting still exiting 0. This
   does not claim G3 even if an old marker exists. The ordinary fleet-upgrade
   protected skip remains in force independently of marker state.

   Arming later means changing the three declarations to `g3_marker: armed` only
   after H1 qualifies the currency EDD §6 process-local convergence exemption.
   Building and qualifying that exemption is H1's scope; this slice supplies no
   bypass or marker-removal convergence cycle. `armed` enables the existing marker
   lifecycle and still requires actual-build refusal qualification.

   Confirm a
   Hermes venv with PyYAML (or `HERMES_FLEET_PYTHON`) on each host. This is an
   activation gate; legacy compatibility is not evidence that protection is armed.
   `HERMES_FLEET_PYTHON` is strict: it must be executable and import PyYAML, with no fallback.
   On h-btp and h-af, record which candidates exist; any higher-precedence copy
   must be byte-identical to `/opt/hermes-config-baseline/fleet/hosts.yaml` or removed.
   Every candidate must be readable by the accounts running bootstrap or verify.
3. In declared Intent, **module 97 mutates only `admitted` rows**. `deferred` and
   `pending-qualification` return a successful held status without dashboard file
   writes, refresh, stop/restart or marker changes. An existing legacy dashboard
   stays exactly as it is. h-do1 remains HELD until its capacity GO; h-air2 retains
   its null endpoint and gets no invented listener. Missing/invalid admission is
   refused. Undeclared legacy behavior is unchanged.

   Schedule a one-time dashboard refresh on the first new module 97 apply to each
   admitted host; h-do1 must first clear its hold and admission gates.
   The rendered unit/plist and credential digest are new.
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

   Preserved apply requires the row's `dashboard_vehicle: preserved-node` and
   enforces admission during both preparation and apply. `deferred` always
   refuses, including with `--qualify`. `pending-qualification` refuses by default;
   an explicit `--qualify` permits the scoped service setup needed for the EDD's
   stage-5 checks. Use it for both preview and apply, for example
   `desktop-gateway-apply.py --registry INTENT --plan-file PLAN --qualify --plan`,
   then the same command without `--plan` in the approved host window. It neither
   admits the row nor creates a client connection/endpoint nor overrides marker
   deferral. Module 97 has no qualification exception.

   A deferred-marker plan must omit `/etc/hermes/image-provenance.json` from
   `prior_sha256`. Preparation emits no marker action, and apply refuses a stale
   armed plan or a hand-edited marker change before writing any files. Plans use
   the input schema in `tests/fixtures/desktop-gateway-plan.json` (an **armed test
   example**); printed `changes` are preview output, never accepted plan input.
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

The EDD's app artifact/rollback pin, h-do1 capacity gate, ingress,
authentication/revocation checks and Mac retention canary remain required. The
h-af non-systemd/:8787 adapter is still deferred. No host, credentials or `/opt`
pin changes are included in this build. The Gate-2 amendment already resolves
h-af owner consent; its technical qualification and stage-5 gates remain open.
