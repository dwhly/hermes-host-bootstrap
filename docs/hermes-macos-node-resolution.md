# Hermes macOS service Node resolution

For unattended Hermes updates/builds, verify both node and npm under the exact
noninteractive service PATH. A valid modern interactive shell is not proof:
h-mini retained `/usr/local/bin/node` v0.8.5 and npm 1.1.48, while nvm/fnm held
modern installations. Its dashboard launcher prefixes ~/.local/bin and then
Homebrew/system paths, so setting launchd PATH alone may still lose precedence.

During the September 19 catch-up, the existing and empty user-local names were
linked to the already-installed compatible pair (no packages removed):

- `/Users/dan_1/.local/bin/node` → `/Users/dan_1/.nvm/versions/node/v22.22.0/bin/node`
- `/Users/dan_1/.local/bin/npm` → `/Users/dan_1/.nvm/versions/node/v22.22.0/bin/npm`
- `/Users/dan_1/.local/bin/npx` → `/Users/dan_1/.nvm/versions/node/v22.22.0/bin/npx`

The selected versions were Node 22.22.0 and npm 10.9.4. Node 24.16.0 was also
installed, but its npm 11.13.0 was explicitly excluded by the checkout's engine
range. Do not bypass engine checks or assume newest-looking Node means compatible
npm. Read the live package.json engines; verify pair before linking.

For recovery, preserve any existing user-owned executables/symlinks instead of
replacing them blindly. This host's three ~/.local/bin names were absent before
creation. Resolve the real home (h-mini user danz has home /Users/dan_1), then
verify the service resolves that same pair. These links are host-specific desired
state, not a fleet-wide pin to this version. Future runtime replacement must
update them before retiring the target installation.

Install only the native updater's ui-tui + web + root workspace closure, including
dev dependencies needed to build; do not pull Desktop just to repair terminal
assets. Rebuild TUI and web, verify the web content stamp, restart the existing
dashboard service, and prove the unauthenticated login route and status auth gate.
A diagnostic npm-debug.log left by a failed old-runtime build is preserved outside
the source tree; never discard unidentified source changes.

Canonical rollout/evidence: automation wiki
`operations/hermes-fleet-upgrade-2026-09.md`, config repository
`fleet/rollouts/hermes-2026-09-18.json`.
