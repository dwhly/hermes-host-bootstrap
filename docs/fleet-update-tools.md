# Fleet coding CLI updater

Dan approved this interim tier 2 updater on 2026-11-23. It updates existing Claude
Code and Codex installations, using the newest stable npm version published at
least 24 hours ago. It never installs an absent tool or downgrades an already-newer
installation to satisfy the soak window.

Install through `./bootstrap.sh --only=N0-fleet-update-tools`. The module links
`~/.local/bin/fleet-update-tools` to this checkout. `hmut` is supplied by
`dotfiles/aliases.sh` (installed by the shell module). `--skip=fleet-update-tools`
leaves any existing installation untouched. All bootstrap tiers are supported;
macOS supports every role, and Linux requires the server role and systemd.

| Platform | Schedule |
| --- | --- |
| macOS | `com.hermes.fleet-update-tools`, `StartCalendarInterval` daily at 03:41, no `RunAtLoad` |
| Linux | `hermes-fleet-update-tools.service` and `.timer`, `OnCalendar=*-*-* 03:41:00`, `Persistent=true` |

A sleeping Mac catches up on wake. The installer waits up to 300 seconds for the
updater mutex before changing a loaded schedule, then uses launchd bootout,
polls until unloaded, and bootstraps the new definition. Unchanged loaded agents
are left alone. A failed unload fails the module. Linux units run as the installing
user with that user's HOME, and also wait for the updater lock before replacing
unit definitions and reloading systemd. The timer is **enabled only**, never
started or restarted by the installer; it activates at the next boot. An already
active timer remains active. No update runs as part of bootstrap.

Run `fleet-update-tools` or `hmut` for an immediate attempt. Create
`~/.config/fleet-update/pause-tools` to pause and remove it to resume. If either
CLI is running for this user, both tools defer. The process check recognizes native
executables and Node wrappers and is repeated immediately before each update.
There is still a small race if an agent starts after the check; agent launchers do
not share this mutex.

`--dry-run` only resolves installed paths and prints the inspection plan. It does
not execute CLIs, npm, or brew, query the registry, create a lock, or write status
or logs. This avoids cache and self-update writes from nominally read-only tool
commands. Its present-tool result is `held:dry_run`; versions remain unknown.

| Installation | Action |
| --- | --- |
| Claude native, resolving under `~/.local/share/claude/versions/` | `claude install <version>` |
| npm global under Homebrew Node, nvm, fnm, or another Node prefix | That installation's `bin/npm i -g <package>@<version> --prefix <prefix>` |
| Homebrew formula/cask owning the resolved binary | `held:brew_managed` |
| Other path, or npm package without its own npm | `held:unknown_install` |
| Missing tool | `skipped:absent` |

Packages are `@anthropic-ai/claude-code` and `@openai/codex`. For npm installations,
the resolved `lib/node_modules/<package>/...` path identifies the prefix, even
through `~/.local/bin` symlinks. A sibling Node runs npm's `npm-cli.js` when present,
so an unrelated Node on PATH cannot select the runtime. The prefix is explicit to
avoid an npm configuration redirecting the update to another installation.
Node-script CLI health checks also use that prefix's Node, including when a
scheduled shell has not loaded nvm or fnm.
Native Claude uses npm on PATH for metadata; without npm it reports
`held:npm_missing`. Homebrew ownership uses `brew list --formula/--cask <package>`
and compares actual listed paths, so a Homebrew Node installation alone does not
make its global npm packages brew-managed. See the [Homebrew list documentation](https://docs.brew.sh/Manpage#list-ls-options-installed_formulainstalled_cask-).

Each `npm view <package> version` and `npm view <package> time --json` has a
60-second limit. Stable semantic versions are sorted numerically, capped at the
stable latest tag, with prereleases excluded. No sufficiently old release gives
`held:no_soaked_version`. Each installation attempt has a 300-second limit.
`<tool> --version` must exit zero within 30 seconds and report the exact target.
A failed install or health check reinstalls the previous version by the same
method and verifies it, giving `rolled_back:install_failed` or
`rolled_back:health_check_failed`. Failed rollback gives `error:rollback_failed`.
Native rollback uses the preserved old executable to repair a broken new symlink
or executable. Timed-out command process groups are terminated before rollback.

The runner never reads or writes `~/.codex/auth.json`, `~/.config/claude`, or
keychain files. It never invokes login or an authenticated model request. Normal
vendor install/version commands run with the user's existing environment.

Each normal run atomically replaces `~/.local/state/fleet-update-tools/status.json`
and keeps the last 500 JSON lines in `log`. The report contains `host`, UTC `ran_at`,
bootstrap checkout `version`, and two `tools` rows with `name`, resolved `path`,
`method`, `result`, `from`, `to`, and `target`. Unknown values are null; a failed
rollback has null `to`. Results include `current`, `updated <old>-><new>`,
`deferred:in_use`, `paused`, `held:*`, `skipped:absent`, `rolled_back:*`, and `error:*`.
One tool's error does not stop the other. Errors exit 1; all other run results
exit 0. Invalid command-line arguments exit 2. A concurrent invocation prints
`busy` and exits 0 without replacing the active run's status.

## Convergence cutover inventory

This approved interim writer must be retired when the master converger takes over
coding CLI versions. Add `com.hermes.fleet-update-tools` and
`hermes-fleet-update-tools.{service,timer}` to the cutover's updater inventory and
disable/unload them before cutover. The external M2 inventory is
`chief/docs/edd/evidence/fleet-self-convergence/m2-config-updater-and-dirty-tree.md`;
this document supplies its entry. This change builds the updater without deploying
it to hosts or changing the master converger.
