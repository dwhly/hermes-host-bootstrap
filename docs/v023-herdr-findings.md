# Hermes v0.23 + herdr 0.9.5: what breaks tab/session restore, and the fixes

Tested 2026-11-22 on h-mini (live install upgraded, guinea pig) and side-by-side on h-mini2 (`~/hermes-trial`).
Evidence on h-mini: `~/hermes-backups/` (pre-upgrade backup `pre-v023-home/`, `state.db.pre-v023`,
`upgrade.log`, `herdr-update.log`, `crash-121727/`).

## Breaks (with v0.23 as installed)

| # | What breaks | Why |
|---|---|---|
| 1 | herdr never detects Hermes (`agent start` times out at 90 s, no status dot) | v0.23 launcher runs `python3 -I -c <inline>`; herdr matches `…/bin/hermes` in argv |
| 2 | herdr never learns a tab's session id | v0.23 runs every chat inside ONE shared gateway; herdr's plugin reads `HERDR_PANE_ID` from the gateway's own env, which never has it |
| 2b | after a resume in another tab the plugin names the OLD tab | v0.23 freezes a chat's client env at creation (`agent/session_client_env.py`), so per-turn reports name the creating tab; v0.21-era chats carry no client env at all |
| 3 | hmw restore + ledger lose track of sessions | they map tab→session via `runtime/active_sessions.json` leases held by per-tab `tui_gateway.entry`; v0.23 has neither. Session ids also change shape: `local-<64 hex>` (ledger `SID_RE` only accepts `YYYYMMDD_HHMMSS_xxxxxx`) |
| 4 | `hermes-pane` label lookup finds nothing | sessions are stored with source `tui`/`local`, never `pane:<LABEL>` — already true on v0.21 TUI Macs (pre-upgrade backup shows `tui`), so this was silently relying on `HMW_RESUME_ID` |
| 5 | installer leaves old gateway/dashboard running old code | run `hermes gateway start && hermes gateway restart`, kickstart `com.hermes.dashboard-server` |

## Fixes (prototyped on h-mini; `contrib/v023/v023-herdr-live-fixes.sh`, reversible with `revert`)

1. **Launcher** — `~/.local/bin/hermes` regenerated as a python FILE named `hermes` with the official launcher's
   body, so herdr recognises it. The same file reports `--resume <id>` to herdr (`herdr pane report-agent-session`)
   because only the resuming tab knows its own pane. Must be regenerated after every `hermes update`.
2. **Plugin** — profile `terminal.client_env_passthrough: [HERDR_ENV, HERDR_PANE_ID, …]`; herdr plugin reads them via
   `agent.session_client_env.session_env` and passes the socket env to its `herdr` call; per-turn re-report
   (`pre_llm_call`) disabled (2b). New chats report at `on_session_start`; resumes via fix 1.
3. **hmw/ledger (to build, reviewed)** — on v0.23 hosts take the tab→session map from herdr's `agent_session`
   (now trustworthy) instead of leases; accept `local-[0-9a-f]{64}`; stand down when herdr 0.9.5 already resumed
   the tab (it does, see results); clear a session's label from the tab it left.
4. **hermes-pane (to build, reviewed)** — resolve the tab's last session from `herdr pane get $HERDR_PANE_ID`
   (`agent_session.value`) before the label lookup.

## Results on h-mini (live, after fixes 1–2, herdr 0.9.5)

- `herdr update --handoff` 0.9.3→0.9.5: running chats kept (same PIDs); sha256 fb77c223… = release asset.
- v0.23 resumes v0.21 sessions (H1 recalled the Oct-28 chime test; H2 its last question).
- agent detected in 3–4 s; herdr knows each tab's session (new chats and resumes, incl. cross-tab resume).
- gateway restart under live TUIs: chats continue.
- **hard kill of the ws herdr server: herdr 0.9.5 itself resumed H1 and H2 into the right tabs within 15 s.**
- Gap: one chat attached in two tabs is restored into only one (the stale-label tab won).
- First v0.23 launch shows a telemetry prompt; default "No thanks" (`shared_metrics.enabled: false`).
- Installer warns 12 non-default profiles are not served by the gateway (shared TELEGRAM_BOT_TOKEN); same as before
  (only one gateway ran on v0.21). Decision needed before relying on profile bots.
