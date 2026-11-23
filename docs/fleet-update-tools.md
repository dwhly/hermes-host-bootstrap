# Fleet coding CLI updater

Dan approved this interim tier 2 updater on 2026-11-23. It updates existing Claude
Code and Codex installations to the newest stable, non-deprecated npm release
published at least 24 hours ago. Normal runs never downgrade an already newer
installation or install an absent tool.

Install through `./bootstrap.sh --only=N0-fleet-update-tools`. The module links
`~/.local/bin/fleet-update-tools` to this checkout. `hmut` is supplied by
`dotfiles/aliases.sh`. `--skip=fleet-update-tools` leaves an existing installation
untouched. All bootstrap tiers and macOS roles are supported; Linux requires the
server role and systemd. Module discovery in `bootstrap.sh` is unchanged.

| Platform | Schedule |
| --- | --- |
| macOS | User LaunchAgent `com.hermes.fleet-update-tools`, daily 03:41 calendar, no `RunAtLoad` |
| Linux | `hermes-fleet-update-tools.timer`, `OnCalendar=*-*-* 03:41:00`, `Persistent=true` |

A sleeping Mac catches up on wake. Before replacing a loaded schedule, the module
waits up to 300 seconds for the updater mutex. It polls launchd after bootout and
before bootstrap; unchanged loaded agents are left alone. An unavailable GUI
domain (SSH-only login) saves the plist, warns, and succeeds so it loads at the
next GUI login. `ExitTimeOut=900` gives a stopping job 15 minutes for recovery.
A failed unload fails the module. The module and runner prefer
Homebrew Python on macOS and check `xcode-select -p` before using Apple's
`/usr/bin/python3` stub.

Linux units run as the installing user with that user's HOME. The module waits
for the updater lock before replacing units, reloads systemd, enables **and starts
the timer**, and never starts the service directly. A preexisting persistent
stamp may cause systemd's normal catch-up behavior. The service uses
`TimeoutStartSec=infinity`, `TimeoutStopSec=15min`, and `KillMode=mixed`; stop
signals reach the Python transaction owner first, leaving time for recovery.

Run `fleet-update-tools` or `hmut` for an immediate attempt. Create
`~/.config/fleet-update/pause-tools` to pause; remove it to resume. If either CLI
is running for this user, both defer. `ps -axo uid=,args=` includes headless
processes; Python filters by UID and checks executable/script arguments, including
Node options with separate values. It does not inspect `comm` or arbitrary prompt
text. The idle check runs again immediately before installing. An agent can still
start after that check because its launcher does not share the updater mutex.

`--dry-run` resolves paths and prints an inspection plan. It does not execute CLIs,
npm, or brew, query the registry, create a lock, or write status/logs. Present tools
report `held:dry_run`; versions remain unknown.

| Installation | Action/result |
| --- | --- |
| Native Claude under `~/.local/share/claude/versions/` | `claude install <version>` |
| npm global under a Node prefix | That installation's `bin/npm i -g <package>@<version> --prefix <prefix>` |
| Homebrew formula/cask owns the resolved binary | `held:brew_managed` |
| Homebrew ownership query times out | `held:brew_unknown` |
| Unrecognized installation / missing sibling npm | `held:unknown_install` |
| Known nvm/fnm/native/user-prefix installation exists outside PATH | `held:not_on_path`; add its bin directory to the scheduler PATH or link it into `~/.local/bin` |
| Package, prefix, or bin directory not writable | `held:not_writable` |
| No executable or known off-PATH installation | `skipped:absent` |

For npm, the resolved `lib/node_modules/<package>/...` identifies the prefix,
including through `~/.local/bin` links. The paired Node runs npm and Node-script
health checks even when nvm/fnm is absent from the scheduler PATH. Metadata for
`@anthropic-ai/claude-code` and `@openai/codex` comes directly from the public npm
registry using Python `urllib`, with a 60-second socket timeout. Native Claude
needs no npm. Release metadata supplies timestamps, latest tag, and deprecation
flags. Stable versions are sorted numerically and capped at a stable latest tag.
No eligible release produces `held:no_soaked_version`. Brew list calls allow 60
seconds; installs allow 300; exact `--version` checks allow 30.

Before mutation the updater copies the package tree, prefix bin link, and PATH
entry into `~/.local/state/fleet-update-tools/backup/<tool>/`. Native Claude gets
an independent copy of its old executable and a version marker. The updater
blocks SIGTERM/SIGHUP/SIGINT with `pthread_sigmask` across install, health check,
and recovery. A pending signal forces recovery after the installer finishes; it
is delivered after recovery and exits with `128 + signal` after status is saved.
Timed-out subprocess groups are terminated and reaped before recovery starts.
SIGKILL, power loss, and a filesystem that cannot write status cannot be handled
by this protocol.

Rollback restores from local copies first and verifies the old `--version`.
Files and links are staged on the destination filesystem and atomically renamed.
Nonempty package directories use an atomic exchange: Linux `renameat2` with
`RENAME_EXCHANGE`, or macOS `renamex_np` with `RENAME_SWAP`. The updater probes
support on the prefix filesystem before installing; unsupported filesystems
report `held:atomic_restore_unavailable`. See the [Linux rename manual](https://www.man7.org/linux/man-pages/man2/rename.2.html)
and [Apple's declarations](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/stdio.h).
Native Claude first repoints its entry to the saved old executable, verifies it,
then restores the vendor version path and link for subsequent runs. Only if local
recovery fails does npm retry the old version with `--prefer-offline`, or the
saved native executable run `install <old>`. An install that failed but left the
old CLI healthy requires no restore or second installer invocation. Backups are
retained until the next update of that tool.

The runner never reads or writes `~/.codex/auth.json`,
`~/.claude/.credentials.json`, `~/.claude.json`, or the macOS keychain. It never
invokes login or a model request. Vendor install/version commands run with the
user's environment; their behavior must be checked on the canaries below.

Normal runs atomically replace `~/.local/state/fleet-update-tools/status.json`
and keep the last 500 JSON reports in `log`. Reports include host, UTC time,
checkout version, and tool rows with name, resolved path, method, result, previous,
resulting, and target versions. Unknown versions are null. Optional
`install_stderr` retains the last 20 diagnostic lines, dropping lines matching
`token|auth|key|password` (case-insensitive). Results include `current`,
`updated <old>-><new>`, `deferred:in_use`, `paused`, `held:*`, `skipped:absent`,
`rolled_back:install_failed`, `rolled_back:health_check_failed`,
`rolled_back:interrupted`, and `error:rollback_failed`. One tool's error does not
stop the other. Errors exit 1; ordinary holds and recovered failures exit 0.
Invalid arguments exit 2. A concurrent normal run prints `busy` and exits 0
without replacing the active run's report.

## Required pre-rollout canaries

Run on **one Mac and h-do1** as the user who owns the installed tools, with agent
sessions stopped. Use a checkout containing this change, before enabling the
fleet schedule. The native Claude gate requires an existing **native** Claude
installation on each host; npm Claude alone does not exercise it. Run the real-ps
test on both hosts (Python 3, pytest, and a C compiler are required):

```sh
python3 -m pytest -q -p no:cacheprovider tests/test_fleet_update_tools.py -k real_ps
```

`--canary-check TOOL VERSION` copies one existing supported installation into a
fresh temporary HOME and npm prefix, redirects XDG/Claude/npm configuration and
cache locations, and runs a real version-specific vendor install without a TTY.
It verifies the requested target version, deliberately fails acceptance, restores
the old version offline, and verifies it. It bypasses the soak rule for the
explicit version and requires it to differ from the installed version. It never
updates the original prefix. Unsupported layouts fail rather than mutate them.
Its temporary HOME is retained and printed, including backup/status/log evidence.
Only a verified update followed by verified forced rollback prints `Canary PASS`
and exits 0; a hold, install failure, or a version unavailable as a native build
fails the canary. Normal updates are unaffected by the forced-failure mode.

From the checkout on **each host**, select stable, non-deprecated versions that
have soaked for 24 hours and differ from the installed versions. This exact
command block selects the newest eligible different version without npm, then
runs both checks. It can select an older version if the current release is already
the newest; that deliberate version change is confined to the disposable HOME.

```sh
set -eu
if [ -x /opt/homebrew/bin/python3 ]; then canary_python=/opt/homebrew/bin/python3
elif [ -x /usr/local/bin/python3 ]; then canary_python=/usr/local/bin/python3
else canary_python=python3
fi
for canary_tool in claude codex; do
  canary_old="$($canary_tool --version)"
  canary_version="$($canary_python - "$canary_tool" "$canary_old" <<'PY'
import datetime, json, re, sys, urllib.request
package = {'claude': '@anthropic-ai/claude-code', 'codex': '@openai/codex'}[sys.argv[1]]
old = re.search(r'\d+\.\d+\.\d+', sys.argv[2]).group()
with urllib.request.urlopen('https://registry.npmjs.org/' + package.replace('/', '%2f'), timeout=60) as response:
    data = json.load(response)
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=24)
latest = data['dist-tags']['latest']
latest_key = tuple(map(int, latest.split('.'))) if re.fullmatch(r'\d+\.\d+\.\d+', latest) else None
candidates = []
for version, info in data['versions'].items():
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or info.get('deprecated') or version == old:
        continue
    key = tuple(map(int, version.split('.')))
    when = datetime.datetime.fromisoformat(data['time'][version].replace('Z', '+00:00'))
    if when <= cutoff and (latest_key is None or key <= latest_key):
        candidates.append((key, version))
if not candidates:
    raise SystemExit('No eligible different version; choose a canary baseline first')
print(max(candidates)[1])
PY
)"
  printf 'Canary %s: %s -> %s -> original\n' "$canary_tool" "$canary_old" "$canary_version"
  bash scripts/fleet-update-tools --canary-check "$canary_tool" "$canary_version" </dev/null
  test "$($canary_tool --version)" = "$canary_old"
done
```

Save terminal output and each printed `status.json`/`log` on both hosts. Require
`canary_target_verified: true`, `rolled_back:canary_forced_failure`, and identical
`from`/`to` versions. For Claude, require `method: native`. Inspect the disposable
HOME's `.claude.json`, `.claude/`, and `versions/` to record whether the native
installer creates config or prunes old builds. Check that the original auth files
and keychain were unchanged using local metadata/backup tooling; never include
credential contents in the evidence. The runner does not call the keychain, but
HOME isolation does not isolate the macOS keychain from vendor code. A live Mac
and h-do1 run remains a rollout gate; passing fake-installer tests is insufficient.

## Convergence cutover inventory

Retire this interim writer when the master converger takes over coding CLI
versions. Add `com.hermes.fleet-update-tools` and
`hermes-fleet-update-tools.{service,timer}` to the cutover inventory and disable
and unload them before cutover. The external M2 inventory is
`chief/docs/edd/evidence/fleet-self-convergence/m2-config-updater-and-dirty-tree.md`.
This change does not deploy to hosts or change the master converger.
