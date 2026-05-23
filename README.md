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

### Tiers

| Tier | What you get | When to use |
|------|--------------|-------------|
| `minimal`     | 25 items — Hermes runs, ssh is locked down, tmux works | small VPS, tight RAM, you'll add tooling on demand |
| `recommended` | + zsh/omz, mosh, docker, tailscale, full media stack, Claude Code + Codex | **default** — what most Hermes hosts should look like |
| `full`        | + small "nice-to-have" CLIs (tldr, tree, httpie, glances, etc.) | when disk is cheap |

Manifests: [`tiers/minimal.txt`](tiers/minimal.txt) ·
[`tiers/recommended.txt`](tiers/recommended.txt) ·
[`tiers/full.txt`](tiers/full.txt)

### Module layout

The work is split across numbered modules in `lib/`. The runner just
sorts them and executes in order:

```
lib/
├── common.sh         shared helpers (logging, apt_install, ensure_line, tier_allows, …)
├── 00-preflight.sh   hostname, tz, apt upgrade, swap, enable-linger
├── 10-security.sh    openssh, ufw, fail2ban, unattended-upgrades, ssh hardening
├── 20-buildchain.sh  build-essential + libs (so pip/cargo wheels compile)
├── 30-shell.sh       tmux, zsh, oh-my-zsh, neovim, mosh, micro
├── 40-cli.sh         rg, fd, fzf, bat, jq, htop, btop, eza, zoxide, delta, …
├── 50-languages.sh   python + uv + pipx, fnm + Node LTS, Rust
├── 60-containers.sh  Docker + compose, user added to docker group
├── 70-network.sh     Tailscale, cloudflared
├── 80-media.sh       ffmpeg, imagemagick, poppler, tesseract, pandoc, espeak-ng
├── 90-agents.sh      hermes, gh, Claude Code CLI, Codex CLI, faster-whisper
└── 95-ghostty.sh     Ghostty terminal — auto-skipped on headless hosts
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

## License

MIT. Use it however you like.
