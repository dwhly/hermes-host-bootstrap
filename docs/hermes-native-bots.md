# Hermes Native Bots

`lib/98-hermes-native-bots.sh` installs `hermes-native-bots` and applies fleet defaults for:

- the native Hermes Desktop app on macOS client/both hosts
- the default-profile Hermes gateway API server on the host Tailscale IPv4

On macOS client/both hosts, the module verifies a packaged native `Hermes.app` and runs
`hermes desktop --build-only` when no verified package exists. It does not build on Linux/server
hosts, download bundles, expand CORS, create certificates, change OS accounts, or alter power policy.

## Commands

```sh
hermes-native-bots configure-api --host 100.x.y.z --port 8642 [--restart-gateway]
hermes-native-bots apply-api
hermes-native-bots status-api
hermes-native-bots verify-api
hermes-native-bots configure-desktop
hermes-native-bots status-desktop
```

`configure-api` edits only the intended runtime home `.env`, preserves a valid existing
`API_SERVER_KEY` including `export`/quoted dotenv forms, creates a new random key only when absent
from both `.env` and Hermes gateway config, and emits a sanitized JSON receipt. A changed config is
restart-pending by default; run `hermes-native-bots apply-api` or pass `--restart-gateway` to use the
native `hermes gateway restart` path for an existing supervised gateway. The helper does not install
a new service/profile and never uses raw process killing.

`configure-desktop` verifies the native `Hermes.app` bundle id, version, executable, architecture,
and codesign state where available. It exposes the app as `~/Applications/Hermes.app` via symlink,
writes a per-user LaunchAgent using `/usr/bin/open`, `RunAtLoad`, and no `KeepAlive`, bootstraps the
LaunchAgent, verifies it is loaded, and launches the app or returns nonzero.
