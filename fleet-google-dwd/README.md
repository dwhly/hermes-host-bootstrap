# fleet-google-dwd

One Google Workspace domain-wide-delegation (DWD) connector for every company. Same code everywhere; each company
is a reviewed YAML file (`config/fleet-google-dwd/companies/<company>.yaml`). Installed by
`lib/63-fleet-google-dwd.sh` on hosts whose `config/fleet-google-dwd/hosts/<host>.env` says `ROLLOUT=go`.

- `fleet_google_dwd.py`: the module (ported from AmForge's h-af `dwd.py`, same API). Use
  `import fleet_google_dwd as dwd; dwd.configure("btp")`, or `configure()` for the host's company
  (`/etc/fleet-google-dwd/host-company`).
- `dwd.py`: compatibility shim for AmForge's existing `import dwd` callers (configures `amforge`).
- `bin/fleet-google-dwd-check`: read-only smoke test (counts only). Exit 0 OK, 3 DWD not authorised in Google
  Admin yet, 2 config error, 1 other failure.

Guarantees (tested in `tests/test_fleet_google_dwd.py`): the SA key comes from 1Password per process and is never
written; subjects are exact ASCII matches of the allowlist (no plus-addressing, sub-domains or Unicode
look-alikes); scopes must be the company's configured ones; the token cache is keyed by company, item, subject
and scope set; the audit log and draft ledger are 0600, owned by the running user, and never followed through a
symlink; config files must be root-owned and not group/other-writable; there is no Gmail send code path.

Residual by design (same as AmForge's original): `access_token()` hands the caller a full-scope token, so a caller
that does its own HTTP can do whatever that scope allows. The allowlist is a guard for agent tools, not a
boundary against code already running as the company's user (which can read the 1Password token file itself).
