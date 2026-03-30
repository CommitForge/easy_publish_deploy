#!/usr/bin/env bash
set -euo pipefail

MODE="check"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--check|--install] [--help]

Options:
  --check      Validate required tools (default)
  --install    Install requirements on Debian/Ubuntu via apt
  -h, --help   Show this help

Checks for:
  - bash
  - git
  - curl
  - docker
  - docker compose (plugin) OR docker-compose (standalone)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      MODE="check"
      ;;
    --install)
      MODE="install"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

check_cmd() {
  local cmd="$1"
  local label="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "[ok] $label"
    return 0
  fi
  echo "[missing] $label"
  return 1
}

check_compose() {
  if docker compose version >/dev/null 2>&1; then
    echo "[ok] docker compose plugin"
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    echo "[ok] docker-compose standalone"
    return 0
  fi
  echo "[missing] docker compose plugin or docker-compose"
  return 1
}

check_docker_daemon() {
  if docker info >/dev/null 2>&1; then
    echo "[ok] docker daemon access"
    return 0
  fi

  echo "[missing] docker daemon access (is the daemon running, and is your user in the docker group?)"
  return 1
}

run_checks() {
  local missing=0

  check_cmd bash "bash" || missing=1
  check_cmd git "git" || missing=1
  check_cmd curl "curl" || missing=1
  check_cmd docker "docker" || missing=1

  if command -v docker >/dev/null 2>&1; then
    check_docker_daemon || missing=1
    check_compose || missing=1
  else
    echo "[missing] compose check skipped because docker is missing"
    missing=1
  fi

  if [[ "$missing" -eq 0 ]]; then
    echo "[requirements] All required tools are available."
    return 0
  fi

  echo "[requirements] Missing tools detected."
  echo "[requirements] On Linux, run: ./scripts/requirements_linux.sh --install"
  return 1
}

install_requirements_debian_ubuntu() {
  local sudo_cmd=""

  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      sudo_cmd="sudo"
    else
      echo "[install] Please run as root or install sudo." >&2
      exit 1
    fi
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "[install] --install currently supports apt-based Linux only." >&2
    exit 1
  fi

  echo "[install] Installing base packages"
  $sudo_cmd apt-get update
  $sudo_cmd apt-get install -y bash git curl ca-certificates

  if ! command -v docker >/dev/null 2>&1; then
    echo "[install] Installing docker.io"
    $sudo_cmd apt-get install -y docker.io
  fi

  if docker compose version >/dev/null 2>&1; then
    echo "[install] docker compose plugin already available"
  elif command -v docker-compose >/dev/null 2>&1; then
    echo "[install] docker-compose standalone already available"
  else
    echo "[install] Installing compose support"
    if ! $sudo_cmd apt-get install -y docker-compose-plugin; then
      $sudo_cmd apt-get install -y docker-compose
    fi
  fi

  if getent group docker >/dev/null 2>&1; then
    if [[ -n "${SUDO_USER:-}" ]]; then
      $sudo_cmd usermod -aG docker "$SUDO_USER" || true
      echo "[install] Added $SUDO_USER to docker group (log out/in may be required)."
    fi
  fi
}

if [[ "$MODE" == "install" ]]; then
  install_requirements_debian_ubuntu
fi

run_checks
