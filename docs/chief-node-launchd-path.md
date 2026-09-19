# Existing macOS Chief telemetry: executable PATH

The `com.chief.node` LaunchAgent must resolve the installed Hermes executable.
A default launchd PATH (`/usr/bin:/bin:/usr/sbin:/sbin`) cannot find
`$HOME/.local/bin/hermes`. Restarting the same plist leaves version telemetry
unknown/stale even when a manual SSH probe succeeds.

For an existing node, preserve the plist and merge only this environment key:

```xml
<key>EnvironmentVariables</key>
<dict>
  <key>PATH</key>
  <string>__HOME__/.local/bin:__HOME__/.hermes/node/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
</dict>
```

Replace `__HOME__` with the account's actual home from its host registry and live
login; launchd does not expand shell `$HOME` syntax. Preserve any existing
EnvironmentVariables entries, executable, args, labels, logs and other fields.
Do not pin `HERMES_VERSION` to a literal: the collector should read the installed
binary on each heartbeat. This is an existing-service repair, not authority to
provision a new node or change its role.

Validate with `plutil -lint`. Reload the exact `com.chief.node` user LaunchAgent
using its GUI UID. After bootout, wait for the old job to disappear before
bootstrap; an immediate bootstrap can transiently return error 5. Read back
`launchctl print gui/<uid>/com.chief.node` and verify running state, new PID and
explicit PATH. Do not leave a stopped service after a failed bootstrap.

Verify the collector under the service environment and observe the Chief node
version over more than one full heartbeat. A single manual `daemon state` emission
is insufficient: the standing daemon can overwrite it on its next cycle. Keep
code upgrades and telemetry refresh separate; this environment fix does not need
a new Chief application build or `deploy-node` code sync.

Applied to existing h-mini2 and h-air2 telemetry services during the September
18 upgrade, then h-mini and h-air during their verified September 19 catch-up.
The latter two use GUI UID 502; resolve the actual UID rather than copying 501.
Full rollout and state source: Hermes automation wiki
`operations/hermes-fleet-upgrade-2026-09.md`, config repo
`fleet/rollouts/hermes-2026-09-18.json`.
