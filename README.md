# hermes-host-bootstrap

Turn a fresh Ubuntu / Debian VPS (or a new Mac) into a fully-loaded
[Hermes Agent](https://hermes-agent.nousresearch.com) host in one command.

```bash
curl -fsSL https://raw.githubusercontent.com/dwhly/hermes-host-bootstrap/main/bootstrap.sh \
  | bash -s -- --tier=recommended
```

Or clone first if you want to read the script before running it (recommended):

```bash
git clone https://github.com/dwhly/hermes-host-bootstrap.git
cd hermes-host-bootstrap
./bootstrap.sh --tier=recommended
```

---

## What it does

A fresh DigitalOcean / Hostinger / Hetzner Linux box is missing a lot of
the daily-driver tooling an AI agent (and the human running it) actually
needs: a multiplexer, modern unix CLIs, a real Python/Node toolchain,
container runtime, media tooling, security baseline, and Hermes itself.

`bootstrap.sh` is one idempotent script that installs all of that, in
tiers, with sane defaults. Re-running it is safe — every step checks
before it acts.

### Roles

The script also asks *what is this machine for?* — because a VPS and your
Mac want very different software.

| Role     | Auto-detected when… | Skips                                | Adds                                  |
|----------|---------------------|--------------------------------------|---------------------------------------|
| `server` | Linux, no `$DISPLAY` | Ghostty, MS Remote Desktop, mac apps | xrdp/XFCE (with `--tier=full`)        |
| `client` | macOS               | xrdp, server-side daemons            | Ghostty, MS Remote Desktop, Tailscale GUI |
| `both`   | Linux with a desktop | nothing                              | both sides                            |

Override with `--role=server|client|both` if auto-detect gets it wrong.

Examples:

```bash
# Fresh VPS — server bits only (auto-detected)
./bootstrap.sh --tier=recommended

# Fresh VPS but you want a remote desktop too
./bootstrap.sh --tier=full              # xrdp + XFCE included

# New Mac — client bits only (auto-detected)
./bootstrap.sh --tier=recommended

# Desktop Linux you use as your daily driver AND as a Hermes host
./bootstrap.sh --tier=full --role=both
```

---

## Tiers

| Tier | What you get | When to use |
|------|--------------|-------------|
| `minimal`     | 25 items — Hermes runs, ssh is locked down, tmux works | small VPS, tight RAM, you'll add tooling on demand |
| `recommended` | + zsh/omz, mosh, docker, tailscale, full media stack, Claude Code + Codex | **default** — what most Hermes hosts should look like |
| `full`        | + small "nice-to-have" CLIs (tldr, tree, httpie, glances, etc.) | when disk is cheap |

Manifests: [`tiers/minimal.txt`](tiers/minimal.txt) ·
[`tiers/recommended.txt`](tiers/recommended.txt) ·
[`tiers/full.txt`](tiers/full.txt)

### Module layout

The work is split across prefixed modules in `lib/`. Numeric prefixes
run in order (`00 → 90`), then letter-prefixed modules run last
(`A0`, `M5`, …):

```
lib/
├── common.sh             shared helpers (logging, apt_install, ensure_line,
│                         tier_allows, role_includes, …)
├── 00-preflight.sh       hostname, tz, apt upgrade, swap, enable-linger
├── 10-security.sh        openssh, ufw, fail2ban, unattended-upgrades, ssh hardening
├── 20-buildchain.sh      build-essential + libs (so pip/cargo wheels compile)
├── 30-shell.sh           tmux, zsh, oh-my-zsh, neovim, mosh, micro
├── 40-cli.sh             rg, fd, fzf, bat, jq, htop, btop, eza, zoxide, delta, …
├── 50-languages.sh       python + uv + pipx, fnm + Node LTS, Rust
├── 60-containers.sh      Docker + compose, user added to docker group
├── 70-network.sh         Tailscale, cloudflared
├── 80-media.sh           ffmpeg, imagemagick, poppler, tesseract, pandoc, espeak-ng
├── 90-agents.sh          hermes, gh, Claude Code CLI, Codex CLI, faster-whisper
├── 95-ghostty.sh         Ghostty terminal — client/both role only
├── A0-remote-desktop.sh  xrdp + XFCE (opt-in: --tier=full or --only=A0-remote-desktop)
└── M5-mac-client.sh      tmux + mosh + MS Remote Desktop + Tailscale GUI (macOS client only)
```

Each module can also be run on its own:

```bash
./bootstrap.sh --only=90-agents,60-containers
```

---

## Flags

```
--tier=<minimal|recommended|full>   default: recommended
--skip=KEY1,KEY2,...                skip specific items (e.g. docker, zsh, ghostty)
--only=MOD1,MOD2,...                run only these modules
--dry-run                           print the plan, don't execute
--self-update                       git pull && re-exec
```

### Useful skip keys

| Key | Skips |
|-----|-------|
| `apt-upgrade`   | the initial `apt-get upgrade` |
| `swap`          | swap file creation |
| `linger`        | `loginctl enable-linger` |
| `ssh-harden`    | sshd_config edits (off by default — only fires if `HERMES_SSH_HARDEN=1`) |
| `ufw`           | ufw install + rules |
| `fail2ban`      | fail2ban |
| `unattended`    | unattended-upgrades |
| `tmux` / `tmux-conf` | tmux package / .tmux.conf install |
| `tmux-workspace-colors` | per-session statusbar coloring for hermes-workspace panes (ops/code/logs/scratch) |
| `tmux-autoattach` | auto-attach to tmux session "main" on interactive SSH (snippet sourced from .bashrc/.zshrc) |
| `hssh` | `hssh <session>` shell function: ssh + attach/create named tmux session in one shot |
| `aliases` | shell aliases (h, hm, ...) — managed by the add-shell-alias skill |
| `chsh-zsh` | make zsh the default login shell on Linux hosts (matches macOS default) |
| `mac-hostname` | macOS only: rename HostName + LocalHostName to `$HERMES_MAC_HOSTNAME` (opt-in) |
| `op` | install the 1Password CLI (for secrets resolution via `.env.template`) |
| `op-resolve` | resolve `~/.hermes/.env.template` → `~/.hermes/.env` via `op inject` on each bootstrap run |
| `ghostty-workspace` | macOS only: 2x2 Ghostty grid launcher (`hermes-workspace`) via AppleScript |
| `mosh-firewall` | UFW rule for mosh UDP 60000-61000 (rule still added if ufw stays disabled) |
| `zsh` / `oh-my-zsh`  | zsh / OMZ |
| `inputrc`       | .inputrc install |
| `mosh`, `neovim`, `micro` | per-tool |
| `python`, `uv`, `node`, `rust`, `pnpm` | language runtimes |
| `docker`        | Docker engine |
| `tailscale`, `cloudflared` | network tools |
| `media`         | ffmpeg + imagemagick + poppler + tesseract + pandoc |
| `hermes`, `gh`, `claude-code`, `codex`, `faster-whisper`, `browser-deps` | agent layer |
| `ghostty`       | Ghostty terminal |

### Useful env vars

| Var | Effect |
|-----|--------|
| `HERMES_HOSTNAME=mybox` | set the hostname during preflight |
| `HERMES_TZ=America/Los_Angeles` | set timezone (default: UTC) |
| `HERMES_SSH_HARDEN=1` | actually apply ssh hardening (off by default to avoid lockout) |
| `HERMES_UFW_ENABLE=1` | actually enable ufw (off by default to avoid lockout) |

---

## A note on Ghostty

Ghostty is a **GUI terminal emulator**. It needs a display server, which
a headless VPS does not have. The `95-ghostty.sh` module detects this
and skips with a friendly notice on headless boxes. It runs the real
install on:

- **macOS** (via `brew install --cask ghostty`) — for your *client* Mac
- **Desktop Linux** (via snap or flatpak)
- **Fedora** (via the pgdev/ghostty COPR)

So you can also point this script at a new Mac to set up your client
machine. Pass `--skip=docker,tailscale` if you don't want a heavy
client-side install.

---

## Idempotency

Everything in `lib/common.sh` is designed so re-running the script is
safe:

- `apt_install` filters out already-installed packages
- `ensure_line` only appends if the line isn't already in the file
- `backup_once` only backs up if no `.bak.<date>` already exists
- Each module checks `have X` / `[[ -d X ]]` before doing work
- `apt-get update` runs at most once per bootstrap invocation

The full log is teed to `~/.hermes-host-bootstrap.log` so you can audit
what happened.

---

## After install

The script prints a checklist at the end. The short version:

1. **Log out and back in** — so `PATH`, the `docker` group, and `linger`
   actually take effect.
2. `hermes setup` — configure your model + provider.
3. `hermes doctor` — sanity-check the install.
4. `hermes gateway setup` — wire up Telegram / Discord / Slack / …
5. `sudo tailscale up` — bring this node onto your tailnet.

---

## Tested on

- Ubuntu 24.04 LTS (DigitalOcean, Hetzner)
- Debian 12 (mostly — Ghostty falls back to flatpak)
- macOS 14 (Sonoma) and 15 (Sequoia)

Probably works on Ubuntu 22.04 too. PRs welcome for Fedora / Arch / WSL.

---

## Remote desktop on the VPS

A headless VPS doesn't have a graphical desktop by default. If you want
to ssh in *and* be able to run GUI apps (browser dev tools, an IDE,
whatever) on the box itself, opt into the `A0-remote-desktop` module:

```bash
# Either way enables it:
./bootstrap.sh --tier=full
./bootstrap.sh --only=A0-remote-desktop   # standalone
HERMES_RDP=1 ./bootstrap.sh                # any tier
```

What you get:
- **XFCE** as the desktop (lightweight, ~150 MB)
- **xrdp** as the protocol server, **bound to 127.0.0.1**

You connect from your Mac in one of two ways:

```bash
# Option A — ssh tunnel
ssh -L 3389:localhost:3389 you@vps
# then open Windows App / Microsoft Remote Desktop → connect to localhost:3389

# Option B — Tailscale
tailscale serve --tcp=3389 tcp://localhost:3389  # one-time
# then connect to your VPS's tailscale name on port 3389
```

**Microsoft Remote Desktop** (free, App Store; renamed "Windows App" in
late 2024) is the recommended Mac client. The `M5-mac-client` module
installs it automatically when `--role=client` or `--role=both`.

To expose xrdp publicly anyway (not recommended), set
`HERMES_RDP_PUBLIC=1`. You'll want `ufw` + `fail2ban` configured first.

---

## Personal config file (optional)

The repo itself is opinionated about *what* a Hermes host looks like
(packages, hardening, verification) but neutral about *who* you are.
If you want to set personal defaults — your preferred tier, your git
identity for commits the script makes, your timezone, your lockout-risk
overrides — drop them in `~/.hermes-bootstrap.conf` and `bootstrap.sh`
will source it on each run.

```bash
cp .hermes-bootstrap.conf.example ~/.hermes-bootstrap.conf
$EDITOR ~/.hermes-bootstrap.conf
```

See `.hermes-bootstrap.conf.example` for the full set of variables.
This keeps the repo cleanly forkable — a new user clones, drops their
own `.hermes-bootstrap.conf`, and never has to touch the repo itself.

---

## Shell sessions that survive Mac sleep (mosh + tmux)

The default `ssh` session from a Mac dies the moment the laptop sleeps —
Wi-Fi drops, the TCP socket goes stale, and when you wake up you get
`No route to host` / `Broken pipe` / `client_loop: send disconnect`. The
fix is two tools, used together:

- **mosh** replaces ssh for the transport. It uses UDP, so it survives
  sleep, Wi-Fi changes, and IP roaming. Auth still goes through ssh (mosh
  shells out to it under the hood), so your keys and `~/.ssh/config`
  aliases still work.
- **tmux** runs on the server and protects the running process state.
  Even if mosh itself dies, your shell + whatever it was running keeps
  going inside the tmux session; you reattach and you're back.

Both are installed by this bootstrap:

| Side | Where it's installed | Notes |
|------|----------------------|-------|
| Linux server | `lib/30-shell.sh` (tier R) | tmux + `~/.tmux.conf`, mosh package |
| macOS client | `lib/M5-mac-client.sh` (role=client/both) | tmux + mosh via Homebrew |
| Firewall | `lib/10-security.sh` | `ufw allow 60000:61000/udp` added even when ufw stays off |

Daily usage from the Mac:

```bash
mosh you@vps -- tmux new -A -s main
```

`tmux new -A -s main` creates a session named `main` if missing, or
attaches to it if it exists. Detach with `Ctrl-b d` (or `Ctrl-a d` if
you're using the bundled `~/.tmux.conf`, which rebinds prefix to
`Ctrl-a`). Re-run the same command tomorrow and you pick up exactly
where you left off.

Cloud-provider firewalls (DigitalOcean, Hetzner, etc.) usually need their
own rule — open UDP **60000-61000** in the provider's web console too,
not just `ufw`.

---

## Fleet registry & dashboard

Every bootstrap run drops a yaml snapshot of the host at
`~/.hermes/hosts/<hostname>.yaml` — OS, role, tier, IPs, tool versions,
resource ceiling, install date, and a free-form **`note:`** describing
what the box is for. If `~/.hermes` is git-tracked via the companion
`hermes-config-sync` repo, those snapshots roll forward to every other
machine, giving you a portable inventory.

### Interactive host identity (first run)

When `bootstrap.sh` runs in a real terminal (stdin is a TTY) and
`HERMES_HOSTNAME` isn't already set, it asks two short questions
before installing anything:

```
Hostname for this machine in the Hermes fleet.
  current OS hostname: ubuntu-s-1vcpu-2gb-70gb-intel-sfo2
  pick a short, unique name (e.g. h-do1, h-mini, hetzner-builder)
  empty = keep 'ubuntu-s-...', no rename
> h-do1
  → will rename to: h-do1

One-line note — what is this machine for?
  e.g. 'main production VPS for hermes', 'macbook M2 daily driver', 'hetzner build farm'
  empty = skip (registry will have no note for this host)
> main Hermes host, SFO, gateway + agent
```

Existing fleet hostnames are listed first so you don't pick a collision.
Both answers are optional — empty input keeps the current value. Skip
the prompts entirely with `HERMES_NONINTERACTIVE=1` or by pre-setting
`HERMES_HOSTNAME` / `HERMES_HOST_NOTE` (in `~/.hermes-bootstrap.conf`
or the environment).

> **Tip:** if you rename the box at the OS level, also rename it in
> your cloud provider's web console (DigitalOcean droplet name,
> Hetzner server name, etc.) so the dashboards and billing line up.

### Dashboard

The bundled `hermes-fleet` script (installed to `~/.local/bin/`) reads
the registry and prints a one-screen dashboard:

```
$ hermes-fleet
  Hermes Fleet  (3 hosts in registry)

  HOST               TIER       ROLE     OS                    HERMES     DISK         NOTE
  hermes-do1         recommended server  Ubuntu 24.04.4 LTS    0.14.0     18%          main Hermes host, SFO, gateway + agent
  hetzner-builder    full       server   Debian 12             0.18.1     72%          background build farm + cache mirror
  mac-mini           recommended both    macOS 15.2            0.18.2     58%          M2 daily driver

  Detail for one host:  hermes-fleet <hostname>
  Live SSH probe:       hermes-fleet --live
  Refresh this box:     hermes-fleet --refresh
```

Modes:
- `hermes-fleet` — static dashboard from snapshot files
- `hermes-fleet <hostname>` — dump the full yaml for one host
- `hermes-fleet --live` — also SSH into each reachable host for current
  uptime + live disk (uses `BatchMode=yes`, so it only works for hosts
  with passwordless key auth from this box, e.g. via Tailscale)
- `hermes-fleet --refresh` — rewrite this host's entry (re-runs the
  `99-register-host` module)
- `hermes-fleet --json` — machine-readable output for scripting

To keep snapshots current between bootstrap runs (e.g. so disk and
uptime are fresh on the dashboard), wire a cron job on each host:

```bash
# crontab -e
0 * * * * cd ~/path/to/hermes-host-bootstrap && ./bootstrap.sh --only=99-register-host >/dev/null 2>&1 && ~/.hermes/sync.sh save "hourly host snapshot" >/dev/null 2>&1
```

---

## License

MIT. Use it however you like.
