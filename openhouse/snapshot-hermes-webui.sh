#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[OpenHouse Hermes Snapshot] %s\n' "$*"
}

warn() {
  printf '[OpenHouse Hermes Snapshot] WARN: %s\n' "$*" >&2
}

die() {
  warn "$*"
  exit 1
}

openhouse_dir="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd)"
bundle_root="$(cd "$openhouse_dir/.." >/dev/null 2>&1 && pwd)"

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

home_dir="${HOME:-/root}"
agent_dir="$(resolve_agent_dir)"
webui_dir="$(resolve_webui_dir)"
hermes_home="${HERMES_HOME:-$home_dir/.hermes}"
venv_python="${HERMES_WEBUI_PYTHON:-$agent_dir/venv/bin/python}"
venv_dir="$(cd "$(dirname "$venv_python")/.." >/dev/null 2>&1 && pwd)"
webui_host="${HERMES_WEBUI_HOST:-127.0.0.1}"
webui_port="${HERMES_WEBUI_PORT:-23084}"
workspace_root="${HERMES_WEBUI_DEFAULT_WORKSPACE:-/root}"
start_script="$openhouse_dir/start-hermes-webui.sh"
server_script="$webui_dir/server.py"
config_dir="${OPENHOUSEAI_CONFIG_DIR:-$home_dir/.config/openhouseai}"
service_registry_dir="${OPENHOUSEAI_SERVICE_REGISTRY_DIR:-$config_dir/service-manager/services.d}"
service_registry_file="${OPENHOUSEAI_HERMES_WEBUI_SERVICE_REGISTRY:-$service_registry_dir/hermes-webui.json}"
backup_root="${OPENHOUSEAI_HERMES_WEBUI_BACKUP_ROOT:-$home_dir/.smallphoneai/backups/hermes-webui}"
backup_dir="$backup_root/last-known-good"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

[ -d "$agent_dir" ] || die "missing Hermes Agent directory: $agent_dir"
[ -d "$webui_dir" ] || die "missing Hermes WebUI directory: $webui_dir"
[ -f "$webui_dir/bootstrap.py" ] || die "missing Hermes WebUI bootstrap.py: $webui_dir/bootstrap.py"
[ -f "$server_script" ] || die "missing Hermes WebUI server.py: $server_script"
[ -x "$venv_python" ] || die "missing executable Hermes venv python: $venv_python"
[ -d "$venv_dir" ] || die "missing Hermes venv directory: $venv_dir"
[ -x "$start_script" ] || die "missing executable Hermes foreground wrapper: $start_script"
grep -Fq 'OPENHOUSE_FOREGROUND_WRAPPER=hermes-webui-v1' "$start_script" \
  || die "Hermes foreground wrapper missing OpenHouse contract marker: $start_script"
grep -Fq 'exec -a "$exec_argv0" "$venv_python" "$server_path"' "$start_script" \
  || die "Hermes foreground wrapper must exec the long-running server with stable argv: $start_script"
[ -f "$service_registry_file" ] || die "missing service registry JSON: $service_registry_file"
command -v curl >/dev/null 2>&1 || die "curl is required for WebUI health check"
command -v tar >/dev/null 2>&1 || die "tar is required for snapshot archives"

curl -fsS --max-time 3 "http://$webui_host:$webui_port/health" >/dev/null \
  || die "Hermes WebUI health check failed: http://$webui_host:$webui_port/health"

"$venv_python" - "$agent_dir" "$service_registry_file" "$start_script" "$server_script" <<'PY'
import json
import sys

agent_dir, service_registry_file, start_script, server_script = sys.argv[1:]
sys.path.insert(0, agent_dir)

import yaml  # noqa: F401
from run_agent import AIAgent  # noqa: F401

with open(service_registry_file, "r", encoding="utf-8") as handle:
    doc = json.load(handle)

if doc.get("id") != "hermes-webui":
    raise SystemExit("service registry id must be hermes-webui")
service = doc.get("service")
if not isinstance(service, dict):
    raise SystemExit("service registry must contain service object")
if service.get("name") != "hermes-webui":
    raise SystemExit("service.name must be hermes-webui")
command = service.get("command")
if not isinstance(command, list) or not command:
    raise SystemExit("service.command must be a non-empty argv")
expected_command = [start_script, server_script]
if command != expected_command:
    raise SystemExit(
        "service.command must use the Hermes foreground wrapper with stable argv: "
        f"expected {expected_command!r}, got {command!r}"
    )
if any("bootstrap.py" in str(item) for item in command):
    raise SystemExit("service.command must not launch bootstrap.py under service-manager")
PY

mkdir -p "$backup_root"
chmod 700 "$backup_root" 2>/dev/null || true
tmp_dir="$backup_root/.last-known-good.tmp.$$"
rm -rf "$tmp_dir"
mkdir -p "$tmp_dir/env" "$tmp_dir/config"
chmod 700 "$tmp_dir" "$tmp_dir/env" "$tmp_dir/config" 2>/dev/null || true

tar -C "$(dirname "$venv_dir")" -czf "$tmp_dir/venv.tar.gz" "$(basename "$venv_dir")"
tar -C "$(dirname "$webui_dir")" -czf "$tmp_dir/hermes-webui.tar.gz" "$(basename "$webui_dir")"
cp "$service_registry_file" "$tmp_dir/service-registry.json"

if [ -f "$webui_dir/.env" ]; then
  cp "$webui_dir/.env" "$tmp_dir/env/webui.env"
fi
if [ -f "$agent_dir/.env" ]; then
  cp "$agent_dir/.env" "$tmp_dir/env/agent.env"
fi
if [ -f "$config_dir/hermes-webui-port" ]; then
  cp "$config_dir/hermes-webui-port" "$tmp_dir/config/hermes-webui-port"
fi
if [ -f "$config_dir/hermes-webui-url" ]; then
  cp "$config_dir/hermes-webui-url" "$tmp_dir/config/hermes-webui-url"
fi

"$venv_python" - "$tmp_dir/manifest.json" <<PY
import json
import os
import sys

manifest_path = sys.argv[1]
doc = {
    "schemaVersion": 1,
    "createdAt": "$timestamp",
    "component": "hermes-webui",
    "agentDir": "$agent_dir",
    "webuiDir": "$webui_dir",
    "venvDir": "$venv_dir",
    "venvPython": "$venv_python",
    "hermesHome": "$hermes_home",
    "workspaceRoot": "$workspace_root",
    "healthUrl": "http://$webui_host:$webui_port/health",
    "serviceRegistry": "$service_registry_file",
    "archives": {
        "venv": "venv.tar.gz",
        "webui": "hermes-webui.tar.gz",
        "serviceRegistry": "service-registry.json",
    },
    "excludedUserData": [
        "$hermes_home"
    ],
    "checks": {
        "webHealth": True,
        "venvImport": True,
        "serviceRegistryJson": True,
    },
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(doc, handle, ensure_ascii=True, indent=2)
    handle.write("\\n")
PY

chmod 600 "$tmp_dir"/*.json "$tmp_dir"/*.tar.gz 2>/dev/null || true
chmod 600 "$tmp_dir/env"/* "$tmp_dir/config"/* 2>/dev/null || true

if [ -d "$backup_dir" ]; then
  previous_dir="$backup_root/previous-$timestamp"
  if [ -e "$previous_dir" ]; then
    previous_dir="$backup_root/previous-$timestamp-$$"
  fi
  mv "$backup_dir" "$previous_dir"
fi
mv "$tmp_dir" "$backup_dir"

log "last-known-good snapshot created at $backup_dir"
log "user data was not backed up or modified: $hermes_home"
