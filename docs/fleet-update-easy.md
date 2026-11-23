# Fleet easy repo updater

Dan approved this interim tier 1 updater on 2026-11-21. It fast-forwards the
`~/.hermes`, bootstrap, and `~/code/hermes-automation-wiki` checkouts when they
have an upstream and are on its default branch. The bootstrap checkout is
resolved from the script's real path, including when invoked through its symlink.

Install with `./bootstrap.sh --only=M9-fleet-update-easy` on any bootstrap tier.
M9 installs `~/.local/bin/fleet-update-easy` as a symlink to the checkout
and installs the schedule. The shell alias `hmu` is supplied by `dotfiles/aliases.sh`
(installed by the shell module). `--skip=fleet-update-easy` leaves any existing
installation untouched.

| Platform | Schedule | Scope |
| --- | --- | --- |
| macOS | `com.hermes.fleet-update-easy` LaunchAgent, every even hour at :17, plus RunAtLoad | All Macs, all roles |
| Linux | `hermes-fleet-update-easy.service` and `.timer`, `OnCalendar=*-*-* 00/2:17:00`, `Persistent=true` | h-do1, server role, root service |

Calendar runs missed while a Mac sleeps coalesce into one run on wake. Reinstalling
an unchanged LaunchAgent does not reload it. Changed definitions boot out, wait
until unloaded, then bootstrap; a failed unload is reported as an error. Linux
reruns restart the oneshot and timer, reasserting the installed behavior.

Run `hmu` (or `fleet-update-easy`) for an immediate update. `--dry-run` only prints
the fetch/merge plan and reads cached `rev-list --count` counts; it does not fetch
objects, change refs, acquire/create the state lock, or write status files. Cached
counts can lag the remote. Fetches in normal runs have a 120-second cap.

Each normal run writes `~/.local/state/fleet-update-easy/status.json` atomically
and appends a JSON line to `log`, retaining its last 500 lines. `version` records
the bootstrap HEAD at the start of the run. `from` and `to` are full commit IDs;
`behind_after` is the upstream distance, or null when unavailable. A missing repo
or upstream is `skipped:absent`; detached or nondefault branches are held. An
existing upstream branch can be ahead of the remote and still be held as diverged.
Local edits only block when Git refuses the fast-forward; unrelated dirty files
are preserved. Blocking paths appear in `files`. Untracked collisions also hold.
Git hooks, auto-stash, recursive submodule updates, and automatic maintenance are
disabled for these operations. A concurrent invocation prints `busy` and exits 0.

No stash, reset, checkout, rebase, or commit is performed. Holds and fetch failures
exit 0; unexpected runtime errors exit nonzero. Human intervention is needed to
resolve a hold; the updater does not reconcile or discard local work.

## Convergence cutover inventory

This is an interim writer to retire when the master converger takes ownership of
these components. Include both schedule names above in its updater inventory and
disable/unload them before cutover. This implementation does not deploy to hosts
or change the master converger. The external M2 inventory is
`chief/docs/edd/evidence/fleet-self-convergence/m2-config-updater-and-dirty-tree.md`;
this note supplies the new entry for that owner.
