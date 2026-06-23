#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[OpenHouse Hermes] %s\n' "$*"
}

warn() {
  printf '[OpenHouse Hermes] WARN: %s\n' "$*" >&2
}

bundle_root="$(cd "$(dirname "$0")/.." >/dev/null 2>&1 && pwd)"
openhouse_dir="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd)"

resolve_agent_dir() {
  if [ -n "${HERMES_AGENT_DIR:-}" ]; then
    printf '%s\n' "$HERMES_AGENT_DIR"
  elif [ -f "$bundle_root/hermes-agent/pyproject.toml" ]; then
    printf '%s\n' "$bundle_root/hermes-agent"
  elif [ -f "$bundle_root/pyproject.toml" ]; then
    printf '%s\n' "$bundle_root"
  else
    printf '%s\n' "$bundle_root/hermes-agent"
  fi
}

resolve_webui_dir() {
  if [ -n "${HERMES_WEBUI_DIR:-}" ]; then
    printf '%s\n' "$HERMES_WEBUI_DIR"
  elif [ -f "$bundle_root/hermes-webui/bootstrap.py" ]; then
    printf '%s\n' "$bundle_root/hermes-webui"
  elif [ -f "$bundle_root/../hermes-webui/bootstrap.py" ]; then
    (cd "$bundle_root/../hermes-webui" >/dev/null 2>&1 && pwd)
  else
    printf '%s\n' "$bundle_root/hermes-webui"
  fi
}

agent_dir="$(resolve_agent_dir)"
webui_dir="$(resolve_webui_dir)"
home_dir="${HOME:-/root}"
hermes_home="${HERMES_HOME:-$home_dir/.hermes}"
venv_dir="${HERMES_AGENT_VENV:-$agent_dir/venv}"
venv_python="$venv_dir/bin/python"
webui_port="${HERMES_WEBUI_PORT:-23084}"
webui_host="${HERMES_WEBUI_HOST:-127.0.0.1}"
workspace_root="${HERMES_WEBUI_DEFAULT_WORKSPACE:-/root}"
config_dir="${OPENHOUSEAI_CONFIG_DIR:-$home_dir/.config/openhouseai}"

have() {
  command -v "$1" >/dev/null 2>&1
}

find_python() {
  if [ -n "${HERMES_INSTALL_PYTHON:-}" ] && have "$HERMES_INSTALL_PYTHON"; then
    command -v "$HERMES_INSTALL_PYTHON"
    return 0
  fi
  if have python3.12; then
    command -v python3.12
    return 0
  fi
  if have python3.11; then
    command -v python3.11
    return 0
  fi
  if have python3; then
    command -v python3
    return 0
  fi
  if have python; then
    command -v python
    return 0
  fi
  return 1
}

ensure_apt_packages() {
  [ "${HERMES_SKIP_APT:-0}" = "1" ] && return 0
  have apt || return 0

  export DEBIAN_FRONTEND=noninteractive
  log "Installing/checking Ubuntu packages for Hermes."
  apt -f install -y || true
  apt install -y \
    python3 \
    python3-venv \
    python3-pip \
    python3-dev \
    build-essential \
    pkg-config \
    libffi-dev \
    libssl-dev \
    ca-certificates \
    curl \
    git \
    ripgrep \
    >/dev/null
}

ensure_dirs() {
  if [ ! -d "$agent_dir" ] || [ ! -f "$agent_dir/pyproject.toml" ]; then
    warn "Hermes Agent source is missing: $agent_dir"
    exit 2
  fi
  if [ ! -d "$webui_dir" ] || [ ! -f "$webui_dir/bootstrap.py" ]; then
    warn "Hermes WebUI source is missing: $webui_dir"
    exit 2
  fi

  mkdir -p \
    "$hermes_home" \
    "$hermes_home/webui" \
    "$config_dir" \
    "$home_dir/.local/bin" \
    "$workspace_root"
}

ensure_python_env() {
  local py
  py="$(find_python)" || {
    warn "Python 3.11+ is required for Hermes."
    exit 3
  }

  if [ ! -x "$venv_python" ]; then
    log "Creating Hermes Python environment: $venv_dir"
    "$py" -m venv "$venv_dir"
  fi

  log "Installing Hermes Agent and WebUI dependencies without GitHub clone."
  "$venv_python" -m pip install --upgrade pip setuptools wheel
  if [ -f "$agent_dir/constraints-termux.txt" ]; then
    "$venv_python" -m pip install -e "$agent_dir[termux-all]" -c "$agent_dir/constraints-termux.txt"
  else
    "$venv_python" -m pip install -e "$agent_dir[all]"
  fi
  "$venv_python" -m pip install -r "$webui_dir/requirements.txt"
}

write_launchers() {
  local launcher="$home_dir/.local/bin/hermes"
  cat >"$launcher" <<EOF
#!/usr/bin/env bash
unset PYTHONPATH
unset PYTHONHOME
exec "$venv_dir/bin/hermes" "\$@"
EOF
  chmod +x "$launcher"

  case ":$PATH:" in
    *":$home_dir/.local/bin:"*) ;;
    *)
      for profile in "$home_dir/.profile" "$home_dir/.bashrc"; do
        touch "$profile"
        if ! grep -Fq 'OpenHouse Hermes PATH' "$profile"; then
          {
            printf '\n# OpenHouse Hermes PATH\n'
            printf 'export PATH="$HOME/.local/bin:$PATH"\n'
          } >>"$profile"
        fi
      done
      ;;
  esac
}

write_webui_env() {
  local env_file="$webui_dir/.env"
  cat >"$env_file" <<EOF
HERMES_HOME=$hermes_home
HERMES_WEBUI_AGENT_DIR=$agent_dir
HERMES_WEBUI_PYTHON=$venv_python
HERMES_WEBUI_HOST=$webui_host
HERMES_WEBUI_PORT=$webui_port
HERMES_WEBUI_STATE_DIR=$hermes_home/webui
HERMES_WEBUI_DEFAULT_WORKSPACE=$workspace_root
HERMES_WEBUI_SERVER_CWD=$workspace_root
HERMES_WEBUI_AUTO_INSTALL=0
HERMES_WEBUI_SKIP_ONBOARDING=0
EOF
  chmod 600 "$env_file" 2>/dev/null || true

  printf '%s\n' "$webui_port" >"$config_dir/hermes-webui-port"
  printf 'http://%s:%s\n' "$webui_host" "$webui_port" >"$config_dir/hermes-webui-url"
}

main() {
  ensure_apt_packages
  ensure_dirs
  ensure_python_env
  write_launchers
  write_webui_env
  if [ "${HERMES_SKIP_REGISTER:-0}" = "1" ]; then
    warn "HERMES_SKIP_REGISTER=1; skipped service-manager registry API registration."
  else
    HERMES_AGENT_DIR="$agent_dir" \
      HERMES_WEBUI_DIR="$webui_dir" \
      HERMES_WEBUI_PYTHON="$venv_python" \
      HERMES_HOME="$hermes_home" \
      HERMES_WEBUI_HOST="$webui_host" \
      HERMES_WEBUI_PORT="$webui_port" \
      HERMES_WEBUI_DEFAULT_WORKSPACE="$workspace_root" \
      bash "$openhouse_dir/register-service.sh"
  fi
  log "Hermes installed. WebUI URL: http://$webui_host:$webui_port"
}

main "$@"
