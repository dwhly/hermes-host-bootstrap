#!/usr/bin/env bash
# 60-containers: Docker engine + compose (Colima on macOS).

set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/common.sh"

step "Containers (Docker)"

if ! tier_allows R; then
  skip "tier=$TIER — docker is recommended-tier, skipping"
  return 0 2>/dev/null || exit 0
fi
if is_skipped docker; then
  skip "--skip=docker passed"
  return 0 2>/dev/null || exit 0
fi

if [[ "$OS" == "macos" ]]; then
  if ! have brew; then
    warn "Homebrew is required to install the open-source macOS container stack"
    return 0 2>/dev/null || exit 0
  fi

  formulas=(colima docker docker-compose docker-buildx qemu)
  missing=()
  for formula in "${formulas[@]}"; do
    if ! brew list --formula "$formula" >/dev/null 2>&1; then
      missing+=("$formula")
    fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    skip "macOS container formulas already installed: ${formulas[*]}"
  else
    info "brew install: ${missing[*]}"
    if ! brew install "${missing[@]}"; then
      warn "could not install the macOS container formulas"
      return 0 2>/dev/null || exit 0
    fi
  fi

  docker_config_dir="${DOCKER_CONFIG:-$HOME/.docker}"
  docker_config="$docker_config_dir/config.json"
  plugin_dir="$(brew --prefix)/lib/docker/cli-plugins"
  if ! docker compose version >/dev/null 2>&1 || ! docker buildx version >/dev/null 2>&1; then
    mkdir -p "$docker_config_dir"
    if have python3; then
      if python3 - "$docker_config" "$plugin_dir" <<'PY'
import json
import os
import stat
import sys
import tempfile

config_path, plugin_dir = sys.argv[1:]
config = {}
mode = 0o600
if os.path.exists(config_path):
    mode = stat.S_IMODE(os.stat(config_path).st_mode)
    with open(config_path, encoding="utf-8") as handle:
        config = json.load(handle)
if not isinstance(config, dict):
    raise ValueError("Docker config must contain a JSON object")

extra_dirs = config.get("cliPluginsExtraDirs", [])
if not isinstance(extra_dirs, list):
    raise ValueError("cliPluginsExtraDirs must be a JSON array")
if plugin_dir not in extra_dirs:
    config["cliPluginsExtraDirs"] = [*extra_dirs, plugin_dir]

directory = os.path.dirname(config_path)
fd, temporary_path = tempfile.mkstemp(prefix="config.json.", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2)
        handle.write("\n")
    os.chmod(temporary_path, mode)
    os.replace(temporary_path, config_path)
except BaseException:
    try:
        os.unlink(temporary_path)
    except FileNotFoundError:
        pass
    raise
PY
      then
        compose_discovered=0
        buildx_discovered=0
        if docker compose version >/dev/null 2>&1; then
          compose_discovered=1
        fi
        if docker buildx version >/dev/null 2>&1; then
          buildx_discovered=1
        fi
        if [[ "$compose_discovered" -eq 1 && "$buildx_discovered" -eq 1 ]]; then
          ok "Docker Compose and Buildx plugin discovery configured: $plugin_dir"
        else
          warn "updated $docker_config, but Docker Compose or Buildx plugin discovery still fails"
        fi
      else
        warn "could not safely update $docker_config; configure cliPluginsExtraDirs manually"
      fi
    else
      warn "python3 unavailable; configure Docker cliPluginsExtraDirs for $plugin_dir manually"
    fi
  else
    skip "Docker Compose and Buildx plugins already discovered"
  fi

  colima_start_mode="${HERMES_COLIMA_START:-auto}"
  start_colima=0
  case "$colima_start_mode" in
    1|true|yes) start_colima=1 ;;
    0|false|no) start_colima=0 ;;
    auto)
      role_includes server && start_colima=1
      ;;
    *)
      warn "invalid HERMES_COLIMA_START=$colima_start_mode (use auto, 1, or 0); not starting Colima"
      ;;
  esac

  if [[ "$start_colima" -eq 0 ]]; then
    info "Colima installed but not started (set HERMES_COLIMA_START=1 for a build host)"
    return 0 2>/dev/null || exit 0
  fi

  colima_cpu="${HERMES_COLIMA_CPU:-4}"
  colima_memory="${HERMES_COLIMA_MEMORY:-8}"
  colima_disk="${HERMES_COLIMA_DISK:-80}"
  colima_arch="${HERMES_COLIMA_ARCH:-native}"
  colima_cpu_max=64
  colima_memory_max=256
  colima_disk_max=2048
  for value_name in cpu memory disk; do
    case "$value_name" in
      cpu) value="$colima_cpu"; maximum="$colima_cpu_max"; env_name=CPU ;;
      memory) value="$colima_memory"; maximum="$colima_memory_max"; env_name=MEMORY ;;
      disk) value="$colima_disk"; maximum="$colima_disk_max"; env_name=DISK ;;
    esac
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
      warn "HERMES_COLIMA_$env_name must be a positive integer; not starting Colima"
      return 0 2>/dev/null || exit 0
    fi
    if (( ${#value} > ${#maximum} )) ||
      { (( ${#value} == ${#maximum} )) && [[ "$value" > "$maximum" ]]; }; then
      warn "HERMES_COLIMA_$env_name must be at most $maximum; not starting Colima"
      return 0 2>/dev/null || exit 0
    fi
  done
  case "$colima_arch" in
    native|aarch64|x86_64) ;;
    *)
      warn "HERMES_COLIMA_ARCH must be native, aarch64, or x86_64; not starting Colima"
      return 0 2>/dev/null || exit 0
      ;;
  esac

  if colima status >/dev/null 2>&1; then
    skip "Colima already running"
  else
    colima_args=(start --cpu "$colima_cpu" --memory "$colima_memory" --disk "$colima_disk")
    if [[ "$colima_arch" != "native" ]]; then
      colima_args+=(--arch "$colima_arch")
    fi
    info "starting Colima: ${colima_cpu} CPU, ${colima_memory}GiB memory, ${colima_disk}GiB disk, arch=${colima_arch}"
    if ! colima "${colima_args[@]}"; then
      warn "Colima failed to start"
      return 0 2>/dev/null || exit 0
    fi
  fi

  if docker info >/dev/null 2>&1; then
    ok "Colima Docker daemon ready"
  else
    warn "Docker CLI is installed, but the Colima daemon is not ready"
  fi
  return 0 2>/dev/null || exit 0
fi

# Linux
require_sudo
if have docker; then
  skip "docker already installed: $(docker --version)"
else
  info "installing Docker via get.docker.com (official convenience script)"
  curl -fsSL https://get.docker.com | sudo sh
fi

# Add invoking user to docker group
target_user="${SUDO_USER:-$USER}"
if ! id -nG "$target_user" | grep -qw docker; then
  sudo usermod -aG docker "$target_user"
  warn "added $target_user to 'docker' group — log out and back in for it to take effect"
fi

# Enable & start
sudo systemctl enable --now docker >/dev/null 2>&1 || true

ok "Docker ready"
