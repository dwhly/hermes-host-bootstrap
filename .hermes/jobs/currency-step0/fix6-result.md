# Currency Step 0 / A0 — fix round 6 result

Worktree: `/root/worktrees/hb-currency-fix6`

Branch: `agent/currency-step0-fix6`

Base: `6fa10d3578658d4e610079384050772aeac18769` (r6 approved-to-merge)

Read the complete review at
`/root/code/chief/docs/edd/reviews/EDD-chief-fleet-software-currency.step0-gate3-r6.md`.
All work is local. No push, SSH, host/service changes, or live rollout.

## Findings → fixes → tests → commit

Implementation commit: `257838d9f82379428eb10ce4a54e25100635ac61`

| Finding | Fix | Regression coverage | Commit |
| --- | --- | --- | --- |
| MINOR 2: restart proof disappears at reboot | Both RunAtLoad root readers bypass cadence no-ops when the volatile directory is missing. Their trusted worker provisions it under the existing shared worker lock, before service control. Uses `os.mkdir`, lstat ownership/type checks, no-follow directory descriptors, and verified `fchown`/`fchmod`; final parent is root:chief 0750 and runtime is root:chief 0770. Non-root entries, links, files and FIFOs HOLD. | `test_minor_2_post_reboot_restart_convergence` clears the fixture `/var/run`, exercises each real reader, and runs real `execute_plan` and no-follow proof polling to `applied`. Adversarial, link-swap, metadata repair and idempotence tests cover provisioning. | `257838d9f82379428eb10ce4a54e25100635ac61` |
| MINOR 1: pending lock handoff suppresses prepared readers | On closure exit 75, prepared pulse/supervisor continue; the ambiguous lock/guard is never reclaimed. The updater still exits 75. All other closure results retain their previous exit behavior. | `test_minor_1_pending_handoff_keeps_readers_running_without_reclaim`: reclaim guard, missing PID publication and live holder, across both readers and updater; check-ins/health continue, locks/policy/removed marker stay unchanged. Existing fix5 concurrent reclaim tests remain in the full suite. | `257838d9f82379428eb10ce4a54e25100635ac61` |
| NIT 3: generic preflight bypasses h-mini2 bridge checks | Generic instructions explicitly require bridge hosts, including h-mini2 retries, to use the documented `/usr/local` bridge preflight after the reviewed legacy update. | `test_nit_3_generic_preflight_requires_bridge_gate`; existing bridge/preflight equivalence cases retained. | `257838d9f82379428eb10ce4a54e25100635ac61` |
| NIT 4: policy render includes sudo-ignored filenames | Flattened render skips basenames containing `.` or ending in `~`. | `test_nit_4_policy_render_obeys_sudo_include_names`: invalid ignored files pass read-only preflight; an invalid active include fails. | `257838d9f82379428eb10ce4a54e25100635ac61` |
| NIT 5: boot identity command fails silently | Both Mac and Linux lock-identity command failures call `hold boot_identity_unavailable`. | `test_nit_5_boot_identity_failure_has_hold`. | `257838d9f82379428eb10ce4a54e25100635ac61` |

## Documentation and accepted rationale

`docs/currency-step0.md` now requires post-reboot restart-convergence in both the
completion checklist and Q6 qualification checks. Live reboot proof remains a
rollout gate; fixtures do not substitute for native Mac evidence.

The product owner's accepted rationale is recorded: the runtime-proof data
directory (`root:chief 0770`) is not trust-checked. Its producer is the login-user
node attesting its own restart. A same-group writer gains nothing it could not
already do, since it controls the node process. Code and root state remain
strictly trust-checked. Provisioning ownership/type checks prevent unsafe root
filesystem operations; they do not confer trust on proof contents.

## Validation

- Full suite, required interpreter: `/root/code/chief/chief-core/.venv/bin/python -m pytest -q tests` (with `--junitxml` to compare failure IDs).
  - Untouched `6fa10d3` in `/tmp/hb-currency-fix6-baseline`: **319 passed, 59 failed, 1 skipped; 32 subtests passed**, 472.33s.
  - Final fix6 tree: **345 passed, 59 failed, 1 skipped; 32 subtests passed**, 415.74s.
  - Parsed both JUnit files and compared exact test failure/error IDs: **zero new failures; identical 59-ID sets**. The common set is recorded in [fix6-failure-ids.txt](fix6-failure-ids.txt).
  - Common failures: one `test_desktop_policy.PolicyTests` interpreter-override assertion; 58 `test_hermes_workspace_082.Herdr082Tests` cases fail on the sandbox's `Operation not permitted`. No currency test failed in either baseline or final run.
  - Logs/XML: `/tmp/currency-fix6-base-isolated.{log,xml}` and `/tmp/currency-fix6-final.{log,xml}`. Earlier diagnostic runs are superseded by this final run.
- Focused new regression file: **26 passed**, 96.35s.
- `shellcheck -S warning`: **PASS** on all 8 changed shell files, including all generated launcher copies.
- `bash -n`: **PASS** on the same 8 files.
- Python 3.9 syntax parse of changed/new Python implementation and regression files: **PASS**; this is not a claim of an actual Python 3.9 runtime test.
- `python3 scripts/render-currency-step0.py`: regenerated deterministic launcher copies; generated consistency tests pass in the full suite.
- `git diff --check`: **PASS**.


The local namespace maps only UID/GID 0. The reboot fixture therefore models
producer credentials here; on a runner with non-root UID mappings it drops the
stamp producer to UID 65534. The real directory modes, reader entrypoints,
restart state machine, stamp parser and verification poller run in both cases.
Ownership attack fixtures substitute lstat metadata without changing host users
or groups. Native macOS and actual Python 3.9 CI remain rollout/merge gates as
specified in the runbook. `tests/test_currency_fix6.py` is added to the existing
Python 3.9 CI job.
