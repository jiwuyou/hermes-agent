#!/usr/bin/env bash
set -euo pipefail

# OPENHOUSE_FOREGROUND_START=hermes-webui-v2
# Manual foreground launcher for Hermes WebUI. service-manager registers the
# real long-running argv directly: venv/bin/python server.py. Do not override
# argv0 here; Python uses argv[0] to resolve the venv/site-packages.

log() {
  printf '[OpenHouse Hermes Start] %s\n' "$*"
}

die() {
  printf '[OpenHouse Hermes Start] ERROR: %s\n' "$*" >&2
  exit 1
}

openhouse_dir="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd)"
bundle_root="$(cd "$openhouse_dir/.." >/dev/null 2>&1 && pwd)"

resolve_agent_dir() {
  if [ -n "${HERMES_AGENT_DIR:-}" ]; then
    printf '%s\n' "$HERMES_AGENT_DIR"
  elif [ -n "${HERMES_WEBUI_AGENT_DIR:-}" ]; then
    printf '%s\n' "$HERMES_WEBUI_AGENT_DIR"
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
  elif [ -f "$bundle_root/hermes-webui/server.py" ]; then
    printf '%s\n' "$bundle_root/hermes-webui"
  elif [ -f "$bundle_root/../hermes-webui/server.py" ]; then
    (cd "$bundle_root/../hermes-webui" >/dev/null 2>&1 && pwd)
  else
    printf '%s\n' "$bundle_root/hermes-webui"
  fi
}

load_webui_env_defaults() {
  env_file="$1"
  [ -f "$env_file" ] || return 0
  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    line="${raw_line#"${raw_line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      ''|\#*) continue ;;
    esac
    case "$line" in
      export\ *) line="${line#export }" ;;
    esac
    case "$line" in
      *=*) ;;
      *) continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "$key" in
      ''|*[!A-Za-z0-9_]*|[0-9]*) continue ;;
    esac
    if [ -z "${!key+x}" ]; then
      case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
      esac
      export "$key=$value"
    fi
  done <"$env_file"
}

agent_dir="$(resolve_agent_dir)"
webui_dir="$(resolve_webui_dir)"
load_webui_env_defaults "$webui_dir/.env"

home_dir="${HOME:-/root}"
hermes_home="${HERMES_HOME:-$home_dir/.hermes}"
venv_python="${HERMES_WEBUI_PYTHON:-$agent_dir/venv/bin/python}"
webui_host="${HERMES_WEBUI_HOST:-127.0.0.1}"
webui_port="${HERMES_WEBUI_PORT:-23084}"
workspace_root="${HERMES_WEBUI_DEFAULT_WORKSPACE:-/root}"
server_cwd="${HERMES_WEBUI_SERVER_CWD:-$workspace_root}"
state_dir="${HERMES_WEBUI_STATE_DIR:-$hermes_home/webui}"
server_path="${1:-$webui_dir/server.py}"

[ -d "$agent_dir" ] || die "missing Hermes Agent directory: $agent_dir"
[ -f "$agent_dir/pyproject.toml" ] || die "missing Hermes Agent pyproject.toml: $agent_dir/pyproject.toml"
[ -d "$webui_dir" ] || die "missing Hermes WebUI directory: $webui_dir"
[ -f "$server_path" ] || die "missing Hermes WebUI server.py: $server_path"
[ "$server_path" = "$webui_dir/server.py" ] || die "unexpected server path: $server_path"
[ -x "$venv_python" ] || die "Hermes Python is missing or not executable: $venv_python"

mkdir -p "$hermes_home" "$state_dir" "$workspace_root"

export HERMES_HOME="$hermes_home"
export HERMES_WEBUI_AGENT_DIR="$agent_dir"
export HERMES_WEBUI_PYTHON="$venv_python"
export HERMES_WEBUI_HOST="$webui_host"
export HERMES_WEBUI_PORT="$webui_port"
export HERMES_WEBUI_STATE_DIR="$state_dir"
export HERMES_WEBUI_DEFAULT_WORKSPACE="$workspace_root"
export HERMES_WEBUI_SERVER_CWD="$server_cwd"
export HERMES_WEBUI_AUTO_INSTALL="${HERMES_WEBUI_AUTO_INSTALL:-0}"
export HERMES_WEBUI_SKIP_ONBOARDING="${HERMES_WEBUI_SKIP_ONBOARDING:-0}"
export HERMES_WEBUI_FOREGROUND=1
export PYTHONPATH="$agent_dir${PYTHONPATH:+:$PYTHONPATH}"

cd "$server_cwd" || die "could not chdir to server cwd: $server_cwd"
log "exec Hermes WebUI server on http://$webui_host:$webui_port"
exec "$venv_python" "$server_path"
