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
until unloaded, then bootstrap; a failed unload is reported as an error. Before
reloading or loading, M9 takes the updater lock, waiting up to 300 seconds for an
active run. If it remains busy, M9 warns and skips the reload. LaunchAgent stdout
and stderr go to `launchd.stdout.log` and `launchd.stderr.log` in the state directory.
Linux enables and starts only the timer, restarting it only when the unit files
change. M9 never starts or restarts the oneshot service.

Run `hmu` (or `fleet-update-easy`) for an immediate update. `--dry-run` prints
the fetch/merge plan, reads cached `rev-list --count` counts, and previews snippet
refreshes against the current **pre-merge** checkout and its local history.
The output explicitly identifies this preview; a real run may fast-forward to
different source bytes before refreshing. It does not fetch
objects, change refs, acquire/create the state lock, or write any files. Cached
counts can lag the remote; a missing cached remote HEAD reports `unknown_default`.
Fetches in normal runs have a 120-second cap, followed by SIGTERM and up to 10
seconds for Git to clean up its locks before a forced kill.

Each normal run writes `~/.local/state/fleet-update-easy/status.json` atomically
and appends a JSON line to `log`, retaining its last 500 lines. `version` records
the bootstrap HEAD at the start of the run. `from` and `to` are full commit IDs;
`behind_after` is the upstream distance, or null when unavailable. A missing repo
or upstream is `skipped:absent`; detached or nondefault branches are held. An
existing upstream branch can be ahead of the remote and still be held as diverged.
Local edits block when Git refuses the fast-forward; unrelated dirty files
are preserved. Blocking paths appear in `files`. Untracked and ignored-file
collisions also hold, preserving the local bytes. For `~/.hermes` only, any path
changed between HEAD and upstream with a modification time in the last five
minutes causes `held:recently_written`. This reduces the chance of overwriting
an active Hermes writer; it cannot eliminate writes racing after that check.
Repositories with `filter.lfs.required` set are held as `held:lfs` before merging.
Checkouts owned by another user are `held:not_owner`, with no Git invocation or
writes in that tree. Macs without Command Line Tools report `skipped:no_git`
without invoking Git or triggering an install dialog.
Git hooks, auto-stash, recursive submodule updates, and automatic maintenance are
disabled for these operations. SSH defaults to `BatchMode=yes` only when neither
`core.sshCommand` nor `GIT_SSH_COMMAND` is set. A concurrent invocation prints
`busy` and exits 0.

After the three repository rows, `repos` contains one `shell-snippets` row. It
looks up `hermes-host-bootstrap` by name and uses that row's path for every source
read and snippet Git command. That path must resolve to the running script's
checkout; otherwise the snippets report `skipped:checkout_mismatch`. Using the
checkout's Git HEAD after its fast-forward (never worktree bytes), tier 1 refreshes
these existing copies installed verbatim (plain `cp`, without templating) by
`30-shell`:

| Repository source | Installed copy |
| --- | --- |
| `dotfiles/aliases.sh` | `~/.hermes-host-bootstrap.aliases.sh` |
| `dotfiles/zshrc-snippet.sh` | `~/.hermes-host-bootstrap.zshrc` |
| `dotfiles/zshenv-snippet.sh` | `~/.hermes-host-bootstrap.zshenv.sh` |
| `dotfiles/tmux-autoattach.sh` | `~/.hermes-host-bootstrap.tmux-autoattach.sh` |
| `dotfiles/hssh.sh` | `~/.hermes-host-bootstrap.hssh.sh` |
| `dotfiles/mouse-heal.sh` | `~/.hermes-host-bootstrap.mouse-heal.sh` |
| `dotfiles/tmux-workspace-colors.conf` | `~/.hermes-host-bootstrap.tmux-workspace-colors.conf` |

Before inspecting copies, the runner parses the snippet `cp` mapping from Git
HEAD's `lib/30-shell.sh`. Any added, removed, or renamed pair holds the entire set with
`held:mapping_changed` and exits 0. This also guards against new snippets that
existing ones source. A missing bootstrap row reports `skipped:no_bootstrap_row`.

Once the mapping matches, its `files` list contains `source`, installed `path`,
and `result` for each pair.
Absent copies are `skipped:absent`, never created, and do not block the other
copies: `30-shell` installs some conditionally (tmux workspace colours only when
tmux is present), so absence is normal. There is no present-versus-absent
"incomplete" rule; the mapping guard above protects against new files.
Identical bytes are `current` without hashing or Git history lookups.
When any copy differs, one `git log` over all seven source paths collects
historical blob IDs, kept separate by source path with rename detection disabled.
A differing copy is eligible only if its bytes match a historical blob of its
exact source path.

The refresh decision is all-or-nothing: every present copy is inspected before
any replacement. If any copy is held or inspection fails, **none are refreshed**.
The row reports `held:<first reason>` in the table's order, with each file's own
reason preserved; otherwise eligible copies report `skipped:set_held`. Current
copies remain `current`. The possible per-file holds are:

- `held:local_edits`: differing bytes are not in that source's history, or a copy
  changed during the run.
- `held:source_absent`: the source was deleted or renamed at HEAD.
  This is a normal hold, not an error.
- `held:unreadable`: access to the copy or source raises `PermissionError`.
- `held:not_regular`: a copy is a symlink (including a dangling link), FIFO,
  directory, or another nonregular file.
- `held:foreign_owner`: the copy's owner differs from the updater's effective UID.
- `held:foreign_group`: the copy's group differs from the updater's effective GID.
- `held:hardlinked`: the copy has more than one hard link.
- `held:no_history`: the checkout is shallow and the installed bytes have no
  match in its available history. Missing history cannot establish whether those
  bytes are an older copy or local edits. The updater does not deepen clones;
  the owner must restore sufficient history or resolve the copy manually.

Installed copies are opened with `O_RDONLY | O_NOFOLLOW | O_NONBLOCK`, checked
with `fstat`, and read from that same descriptor. Links are never followed and
FIFOs cannot block the updater. All replacements are prepared in temporary files
in the same directory, flushed and fsynced, preserving installed modes. Refreshed
copies take the runner's group and lose extended attributes (xattrs) and ACLs.
Copies with a different group are held instead. The whole
present set is checked again after preparation, and each destination is checked
again immediately before its atomic rename. Preparation failures also block the
whole set. The renames are individual filesystem operations, not a transaction
across seven paths: an interruption or a new failure during the rename phase
stops further replacements. Running shells are not locked by the updater.

The row result is `current` when nothing needs refreshing (including absent
copies), `refreshed N`, or the first hold reason. Unexpected per-file failures
report `error` with a sanitized exception type; the row is `held:error` if that
is the first blocker. Any per-file error exits 1 after reporting, even if an
earlier hold supplies the row reason. Ordinary holds and absent copies exit 0.
If the bootstrap row is held, skipped, or errored, all snippets are skipped with
that reason, such as `skipped:held:local_edits`, `skipped:absent`, or
`skipped:error`. Dry runs apply the same set-wide decision and print
`would refresh` and per-file `would_refresh` only for an eligible set, without
writing. The snippet row's commit and distance fields are null. Current sets
omit per-file JSON from stdout; the status and log retain all seven outcomes.

Tier 1 never touches user-owned `~/.tmux.conf`, `~/.inputrc`, or
`~/.config/ghostty/config`. Shells pick up refreshed snippets on their next start;
the updater does not reload running shells.

No stash, reset, checkout, rebase, or commit is performed. Holds and fetch failures
exit 0; fetch failures have a null `behind_after`. An unexpected repository error
records `result: error` and a short `message`, then processing continues with the
other repositories. Status and log are written before exiting 1 if any repository
errored. Human intervention is needed to resolve a hold; the updater does not
reconcile or discard local work.

## Convergence cutover inventory

This is an interim writer to retire when the master converger takes ownership of
these components. Include both schedule names above in its updater inventory and
disable/unload them before cutover. This implementation does not deploy to hosts
or change the master converger. The external M2 inventory is
`chief/docs/edd/evidence/fleet-self-convergence/m2-config-updater-and-dirty-tree.md`;
this note supplies the new entry for that owner.

## Preserved hosts

On owner-managed hosts (h-af, h-btp) the host's own skills, memory and config are
protected. Create `~/.config/fleet-update/preserve-hermes-config` and `~/.hermes`
reports `skipped:preserved` and is never fetched or touched; the bootstrap scripts
(including `hmw`) and the wiki still update.
