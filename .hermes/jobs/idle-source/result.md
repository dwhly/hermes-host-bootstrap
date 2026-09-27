# Converger idle source — completed locally

Branch: `agent/converger-idle-source`; base: `48eed9ef880bd55fafd3caea08e939f392996d4d`.
Companion node commit: `6310fd2e8ae9edf867b0e7076c7e67dd511eb338`.

Without `--idle-snapshot`, the converger reads `idle.json` from the runtime-proof
root (`/var/run/chief/runtime` on macOS, `/run/chief/runtime` on Linux, or the
existing override). It uses a regular, bounded, parseable, non-symlink file with
`0 <= now - checked_at <= 180 seconds`. Otherwise it checks the selected,
digest/HMAC-verified desired row's `current_fold.idle` using the same freshness
rule, then returns `None` and defers with `coordination_probe_untrusted`.

The adapter maps the node's directive, lease and subprocess evidence. Fresh busy
or unknown reports remain vetoes, including empty-evidence reports; contradictory
nonempty evidence also vetoes an idle status. The aggregate attestation uses its
real observation time and 180-second lifetime. Existing explicit snapshots keep
their legacy per-probe checks. The in-lease admission check re-reads the file and
re-evaluates fallback freshness, reporting `accepted_work_after_idle_check` when
admission is lost. Code/root-state ownership checks, signature checks, wake
qualification, and runtime-proof requirements are retained.

Mac events now identify `launchd`. Every event records the exact pulse trigger
and source in its provenance URI, for example:

`converger://h-mini2/cnv_example/started?trigger=periodic&idle_source=local_file`

The installed Chief Spec v1 rejects extra data fields and only permits four
`data.trigger` categories. To remain ingestible within this two-repository change,
periodic/wake/network use `next_idle`; boot/login/daemon-start use `boot_reconcile`;
request uses `operator`. The exact trigger is retained in `sourceref` on every
event. Deferred events also include `data.idle_snapshot.idle_source`. No schema
validation is bypassed, and no third-repository deployment is required.

Validation:

- `tests/test_converger_idle_source.py` and `tests/test_converger.py`: **113 passed**.
  The new file contributes 73 cases and is included in
  `.github/workflows/currency-step0.yml`.
- The argv-free Step 0 Mac fixture exercises signed-plan admission, lease,
  fetch, checkout, install, launchd restart, runtime-proof reading and watermark
  advancement without `--idle-snapshot`, separately with local and signed-plan
  sources. It also checks the no-source deferral for all five requested triggers.
- Coverage includes freshness boundaries, future dates, bad timestamps and
  JSON, excessive nesting, oversized and nonregular files, symlinked files and
  directories, open races, source priority, busy/unknown, each evidence field,
  signature/digest rejection before idle reads, re-reading and source changes
  inside the lease, and launchd/systemd labels.
- An additional cross-repository check used the actual node writer and converger
  reader: the `0640` idle snapshot admitted; a subsequent held lease vetoed.
- Python 3.9 syntax parsing and isolated stdlib-only payload imports pass (local
  interpreter: Python 3.12). No shell files changed; native macOS CI is not run
  locally.
- `git diff --check` passes.

Full-suite comparison using
`/root/code/chief/chief-core/.venv/bin/python -m pytest -q tests`:

- Clean detached `48eed9e` baseline: **59 failed, 345 passed, 1 skipped,
  32 subtests passed**.
- Final tree: **59 failed, 418 passed, 1 skipped, 32 subtests passed**.
- **Zero new failures.** The sets of failed test names are identical; all 73 new
  cases pass. The full-suite command exits 1 on both trees because of the same
  pre-existing failures below.
- Baseline failures are 58 sandbox-denied Unix socket binds in
  `tests/test_hermes_workspace_082.py` and the existing interpreter-selection
  assertion in `tests/test_desktop_policy.py::PolicyTests::test_module97_resolves_override_before_sudo`.
- Full logs: `/tmp/hb-idle-baseline-48eed9e.pytest.log` and
  `/tmp/hb-idle-final-complete.pytest.log`.

All work is local. No push, SSH, deployment, or host configuration changes.
