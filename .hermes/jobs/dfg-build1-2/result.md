# Desktop fleet gateways — build slice 1.2

Branch: `agent/dfg-build1-2`. Base: approved slice 1.1 `dbb6e63`.
Local implementation and fixture validation only; no push, merge or host changes.

## Design

- `desktop_client` is a host-row sibling of `desktop_gateway`. In declared Intent,
  absent means `deferred`; only `enabled` and `deferred` are accepted. Validation
  runs in the existing shared policy validator, including every manifest row.
  Existing rollout-declaration detection, candidate precedence, update policy,
  marker and admission semantics are unchanged.
- Install validates the manifest, resolves its own row with the existing
  `host_record` lookup, and gates before revision/app-pin reads or any artifact
  writer. Both optional and ordinary install return 0 with
  `desktop-fleet: client install deferred for HOST (desktop_client=deferred)`.
  Legacy optional install remains `not-configured`; ordinary legacy install
  retains its existing refusal.
- Identity is the existing `platform.node().split('.')[0]` / explicit `--client`,
  matched exactly to `hosts[].hostname`. This is the short-hostname identity also
  used by module 97 (`socket.gethostname().split('.')[0]`) and policy verification
  (`hostname -s`); no aliases, SSH users or gateway labels participate.
  Unknown/duplicate clients retain the manifest validator's nonzero refusal
  (`duplicate hosts or client missing from Intent`, surfaced by the CLI's existing
  generic indeterminate diagnostic), before writes. No identity STOP was found.
- Deferred verify exits 0 with `deferred (client deferred for HOST; ...)`.
  The existing verifier maps this to `status: deferred`, as for the G3 marker.
  Leftover manifest, checklist, plugin, receipt, tools directory and version shim
  are named without parsing, changing or deleting them. This asserts neither
  app qualification nor that a previously installed plugin has stopped running.
- Version actions retain their ordinary behavior; `--optional` enables the same
  deferred report for bootstrap verification. `verify.sh` uses the repository
  helper and independent compatibility pin even when old installed tools remain.
  Enabled app-pin/digest checks are unchanged. Python cache writing is disabled
  in the client CLI and module-98 invocations.
- Enabled payloads are checked against hashes produced by running `dbb6e63`'s
  actual installer on the same fixture Intent and revision. Manifest, checklist,
  plugin and receipt match byte for byte; the installed file set and modes match.
  Tool files copy the current source bytes, as before (the changed gate code must
  naturally differ from the old tool source). Golden tests need no Git objects
  or network at runtime.

## File:line map

| Location | Purpose |
| --- | --- |
| `scripts/desktop_fleet/common.py:204` | Enum/default and shared validation hook |
| `scripts/desktop-fleet.py:95` | Report-only leftover inventory |
| `scripts/desktop-fleet.py:124` | Deferred verify and optional version reporting |
| `scripts/desktop-fleet.py:151` | Install gate before all artifact writes |
| `lib/98-desktop-fleet-warm.sh:13` | Real module still delegates installation; no bytecode cache writes |
| `verify.sh:143` | Version/app-pin checks use the same desired-state deferral |
| `tests/test_desktop_policy.py:79` | Full HOME file/directory/metadata snapshots for zero-write install |
| `tests/test_desktop_policy.py:94` | Invalid values, other-row invalid declarations and unknown hosts |
| `tests/test_desktop_policy.py:121` | Enabled parity, idempotence, per-client selection and enable-to-defer preservation |
| `tests/test_desktop_policy.py:174` | Deferred verification with absent, malformed or leftover artifacts |
| `tests/test_desktop_policy.py:238` | Real Bash module 98 and desktop enrollment with fixture identity |
| `tests/test_desktop_policy.py:252` | All three shell checks return the existing deferred status |
| `tests/fixtures/desktop-enabled-slice1-1.json:1` | Frozen slice-1.1 payload hashes and installed tool paths |
| `tests/test_desktop_gateways.py:43` | Existing install fixture now explicitly enables its client |
| `docs/desktop-fleet-rollout.md:22` | r1 MINOR 1 reader ordering, extended through slice 1.2 |
| `docs/desktop-fleet-rollout.md:49` | Per-host enablement, reviewed window commit, h-mini2 first, offline return |

## Writers checked

| Path | Finding |
| --- | --- |
| `desktop-fleet.py install` | Sole client install action; gate precedes manifest/checklist `atomic_write`, `install_bundle` and `install_tools` |
| `install_bundle` / `install_tools` | Internal writers for plugin/receipt and tools/shim; sole production caller is the gated install branch |
| `lib/98-desktop-fleet-warm.sh` | Delegates to gated `install --optional`; real shell fixture proves no writes |
| `scripts/fleet-enroll-existing --desktop-only` | Delegates to gated ordinary install; real shell fixture proves no writes |
| `scripts/hermes-desktop-fleet-warm` | Version/app-version only; no client artifact writer |
| `desktop-fleet.py render`, `verify`, `version`, `app-version` | Stdout/read-only; no artifact mutations |
| `desktop-plugins/fleet-gateways/plugin.js` | SDK connection reads and `warmAgent` calls; no filesystem installer, refresh, renew or uninstall |
| `desktop-dashboard.py`, `desktop_fleet/dashboard.py` | Module-97 dashboard files, credential stamp and supervisor refresh only; no client artifacts |
| `desktop-gateway-apply.py` | Preserved-node launcher, unit, environment, backup/stamp and authorized marker writes only |
| `desktop-fleet-policy.py`, `desktop_fleet/marker.py` | Marker lifecycle only; existing gates unchanged |
| `fleet-upgrade.sh`, `scripts/hermes-fleet`, `lib/99-register-host.sh` | Runtime/service/telemetry refresh and inventory/version reporting; no client installer |

Repository searches found no separate client refresh, renew or uninstall writer.

## Validation

All tests are local fixtures; neither fleet hosts nor host services were invoked.

| Command | Result |
| --- | --- |
| `python3 tests/test_desktop_gateways.py` | PASS, 37 tests |
| `python3 tests/test_desktop_policy.py` | PASS, 42 tests |
| `/root/code/chief/chief-core/.venv/bin/python -m pytest -q tests/test_desktop_gateways.py tests/test_desktop_policy.py` | PASS, 79 tests + 57 subtests |
| `bash tests/test_desktop_fleet_upgrade.sh` | PASS |
| `node tests/test_desktop_plugin.cjs` | PASS |
| `bash tests/test_mac_desktop_power_scope.sh` | PASS |
| `python3 -m py_compile scripts/desktop-fleet.py scripts/desktop-fleet-policy.py scripts/desktop-dashboard.py scripts/desktop-gateway-apply.py scripts/desktop_fleet/*.py tests/test_desktop_gateways.py tests/test_desktop_policy.py` | PASS |
| `bash -n` on the shellcheck file set below | PASS |
| `git diff --check` | PASS |

`shellcheck -S warning` passes on `lib/97-dashboard-server.sh`,
`lib/98-desktop-fleet-warm.sh`, `scripts/hermes-desktop-fleet-warm`,
`scripts/fleet-enroll-existing`, `verify.sh`, `fleet-upgrade.sh` and
`tests/test_desktop_fleet_upgrade.sh`. Unfiltered shellcheck exits 1 with seven
existing informational diagnostics (SC1091, SC2015, SC2016, SC2317). A JSON
comparison against files extracted from `dbb6e63` confirms exactly the same
file/code/severity/message findings, with no new diagnostics.

## STOP / remaining activation prerequisite

Neither requested implementation STOP condition occurred: identity is consistent,
and the gate requires no change to slice-1.1 marker/admission/update semantics.

**Chief's neutral rendering requirement remains external to this branch.** The
local Chief checkout still excludes `deferred` from `ProvisioningCheck.status`
(`chief-console/lib/types.ts:115`) and renders it with `!` / `check-error`
(`chief-console/app/nodes/[id]/NodeDetailView.tsx:26`). This is the existing
slice-1.1 r1 MINOR 2 finding. Bootstrap now emits the requested existing deferred
shape with exit 0 for all three client checks, but that alone cannot make this
Chief frontend neutral. Its consumer fix is required before activation; no Chief
files or deployed hosts were changed in this bootstrap-only task.
