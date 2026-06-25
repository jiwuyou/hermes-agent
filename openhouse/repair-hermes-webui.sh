#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[OpenHouse Hermes Repair] %s\n' "$*"
}

warn() {
  printf '[OpenHouse Hermes Repair] WARN: %s\n' "$*" >&2
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

have() {
  command -v "$1" >/dev/null 2>&1
}

service_manager_cli() {
  if have service-manager; then
    command -v service-manager
    return 0
  fi
  if [ -x "$home_dir/.local/bin/service-manager" ]; then
    printf '%s\n' "$home_dir/.local/bin/service-manager"
    return 0
  fi
  if [ -x /root/.local/bin/service-manager ]; then
    printf '%s\n' /root/.local/bin/service-manager
    return 0
  fi
  return 1
}

home_dir="${HOME:-/root}"
agent_dir="$(resolve_agent_dir)"
webui_dir="$(resolve_webui_dir)"
hermes_home="${HERMES_HOME:-$home_dir/.hermes}"
venv_python="${HERMES_WEBUI_PYTHON:-$agent_dir/venv/bin/python}"
venv_dir="$(cd "$(dirname "$venv_python")/.." >/dev/null 2>&1 && pwd 2>/dev/null || printf '%s\n' "$agent_dir/venv")"
webui_host="${HERMES_WEBUI_HOST:-127.0.0.1}"
webui_port="${HERMES_WEBUI_PORT:-23084}"
server_script="$webui_dir/server.py"
sm_url="${SERVICE_MANAGER_URL:-${SMALLPHONE_SERVICE_MANAGER_URL:-http://127.0.0.1:20087}}"
config_dir="${OPENHOUSEAI_CONFIG_DIR:-$home_dir/.config/openhouseai}"
service_registry_dir="${OPENHOUSEAI_SERVICE_REGISTRY_DIR:-$config_dir/service-manager/services.d}"
service_registry_file="${OPENHOUSEAI_HERMES_WEBUI_SERVICE_REGISTRY:-$service_registry_dir/hermes-webui.json}"
backup_root="${OPENHOUSEAI_HERMES_WEBUI_BACKUP_ROOT:-$home_dir/.smallphoneai/backups/hermes-webui}"
backup_dir="$backup_root/last-known-good"
quarantine_root="${OPENHOUSEAI_HERMES_WEBUI_QUARANTINE_ROOT:-$home_dir/.smallphoneai/quarantine/hermes-webui}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
svc_name="hermes-webui"

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v tar >/dev/null 2>&1 || die "tar is required"

health_ok() {
  curl -fsS --max-time 3 "http://$webui_host:$webui_port/health" >/dev/null 2>&1
}

json_python() {
  if [ -x "$venv_python" ]; then
    printf '%s\n' "$venv_python"
  elif command -v python3 >/dev/null 2>&1; then
    command -v python3
  elif command -v python >/dev/null 2>&1; then
    command -v python
  else
    return 1
  fi
}

validate_foreground_server() {
  [ -x "$venv_python" ] || die "missing executable Hermes Python: $venv_python"
  [ -f "$server_script" ] || die "missing Hermes WebUI server.py: $server_script"
}

validate_service_registry_contract() {
  [ -f "$service_registry_file" ] || die "missing service registry JSON: $service_registry_file"
  py="$(json_python)" || die "python is required to validate service registry JSON"
  "$py" - "$service_registry_file" "$venv_python" "$server_script" <<'PY'
import json
import sys

service_registry_file, venv_python, server_script = sys.argv[1:]
with open(service_registry_file, "r", encoding="utf-8") as handle:
    doc = json.load(handle)

service = doc.get("service")
if not isinstance(service, dict):
    raise SystemExit("service registry must contain service object")
command = service.get("command")
expected_command = [venv_python, server_script]
if command != expected_command:
    raise SystemExit(
        "hermes-webui service.command must launch the real foreground Python server "
        f"argv: expected {expected_command!r}, got {command!r}"
    )
if any("bootstrap.py" in str(item) for item in command):
    raise SystemExit("hermes-webui service.command must not launch bootstrap.py under service-manager")
repair = service.get("repair")
if not isinstance(repair, dict) or repair.get("mode") != "hook":
    raise SystemExit("hermes-webui repair hook is missing")
PY
}

service_manager_token() {
  sm_token="${SERVICE_MANAGER_TOKEN:-${SMALLPHONE_SERVICE_MANAGER_TOKEN:-}}"
  if [ -z "$sm_token" ]; then
    sm_cli="$(service_manager_cli || true)"
    if [ -n "$sm_cli" ]; then
      sm_token="$("$sm_cli" token show 2>/dev/null | tr -d '\r\n' || true)"
    fi
  fi
  printf '%s\n' "$sm_token"
}

write_curl_cfg() {
  cfg="$1"
  token="$2"
  : >"$cfg"
  if [ -n "$token" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$token" >>"$cfg"
  fi
  printf 'header = "Content-Type: application/json"\n' >>"$cfg"
}

sm_post() {
  endpoint="$1"
  curl_cfg="$2"
  curl -q -fsS --max-time 15 -X POST -K "$curl_cfg" "$sm_url$endpoint" >/dev/null
}

sm_get() {
  endpoint="$1"
  curl_cfg="$2"
  out_file="$3"
  curl -q -fsS --max-time 8 -K "$curl_cfg" "$sm_url$endpoint" >"$out_file"
}

service_state() {
  curl_cfg="$1"
  out_file="$2"
  sm_get "/api/v1/services/$svc_name/status" "$curl_cfg" "$out_file" || return 1
  py="$(json_python)" || return 1
  "$py" - "$out_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    doc = json.load(handle)
print(doc.get("state", "unknown"))
PY
}

stop_service() {
  curl_cfg="$1"
  if curl -fsS --max-time 2 "$sm_url/api/v1/health" >/dev/null 2>&1; then
    if sm_post "/api/v1/services/$svc_name/stop" "$curl_cfg"; then
      log "service-manager stop requested for $svc_name"
    else
      warn "service-manager stop failed; continuing with restore"
    fi
  else
    warn "service-manager is not reachable at $sm_url; continuing without API stop"
  fi
}

start_service() {
  curl_cfg="$1"
  curl -fsS --max-time 2 "$sm_url/api/v1/health" >/dev/null 2>&1 \
    || die "service-manager is not reachable at $sm_url"
  sm_post "/api/v1/services/$svc_name/start" "$curl_cfg" \
    || die "service-manager failed to start $svc_name"
}

wait_health() {
  deadline="$((SECONDS + 45))"
  while [ "$SECONDS" -le "$deadline" ]; do
    if health_ok; then
      return 0
    fi
    sleep 2
  done
  return 1
}

wait_ready() {
  curl_cfg="$1"
  status_file="$2"
  deadline="$((SECONDS + 60))"
  last_state="unknown"
  while [ "$SECONDS" -le "$deadline" ]; do
    if last_state="$(service_state "$curl_cfg" "$status_file" 2>/dev/null)"; then
      if [ "$last_state" = "running" ] && health_ok; then
        return 0
      fi
    fi
    sleep 2
  done

  if ! last_state="$(service_state "$curl_cfg" "$status_file" 2>/dev/null)"; then
    last_state="unavailable"
  fi
  if health_ok; then
    die "Hermes WebUI health passed, but service-manager state is $last_state; foreground process tracking is broken"
  fi
  die "Hermes WebUI did not become ready; service-manager state=$last_state and health check failed"
}

create_snapshot_if_possible() {
  if [ -x "$openhouse_dir/snapshot-hermes-webui.sh" ]; then
    "$openhouse_dir/snapshot-hermes-webui.sh"
  else
    die "missing snapshot helper: $openhouse_dir/snapshot-hermes-webui.sh"
  fi
}

restore_last_known_good() {
  [ -d "$backup_dir" ] || die "no last-known-good snapshot found at $backup_dir"
  [ -f "$backup_dir/venv.tar.gz" ] || die "snapshot missing venv.tar.gz"
  [ -f "$backup_dir/hermes-webui.tar.gz" ] || die "snapshot missing hermes-webui.tar.gz"
  [ -f "$backup_dir/service-registry.json" ] || die "snapshot missing service-registry.json"
  [ -f "$backup_dir/manifest.json" ] || die "snapshot missing manifest.json"

  quarantine_dir="$quarantine_root/$timestamp"
  mkdir -p "$quarantine_dir"
  chmod 700 "$quarantine_root" "$quarantine_dir" 2>/dev/null || true

  if [ -d "$venv_dir" ]; then
    mkdir -p "$quarantine_dir/$(basename "$(dirname "$venv_dir")")"
    mv "$venv_dir" "$quarantine_dir/venv"
  fi
  if [ -d "$webui_dir" ]; then
    mv "$webui_dir" "$quarantine_dir/hermes-webui"
  fi
  if [ -f "$service_registry_file" ]; then
    mkdir -p "$quarantine_dir/service-registry"
    cp "$service_registry_file" "$quarantine_dir/service-registry/hermes-webui.json"
  fi

  mkdir -p "$(dirname "$venv_dir")" "$(dirname "$webui_dir")" "$(dirname "$service_registry_file")"
  tar -C "$(dirname "$venv_dir")" -xzf "$backup_dir/venv.tar.gz"
  tar -C "$(dirname "$webui_dir")" -xzf "$backup_dir/hermes-webui.tar.gz"
  cp "$backup_dir/service-registry.json" "$service_registry_file"

  if [ -f "$backup_dir/env/webui.env" ]; then
    cp "$backup_dir/env/webui.env" "$webui_dir/.env"
    chmod 600 "$webui_dir/.env" 2>/dev/null || true
  fi
  if [ -f "$backup_dir/env/agent.env" ]; then
    cp "$backup_dir/env/agent.env" "$agent_dir/.env"
    chmod 600 "$agent_dir/.env" 2>/dev/null || true
  fi
  if [ -f "$backup_dir/config/hermes-webui-port" ]; then
    cp "$backup_dir/config/hermes-webui-port" "$config_dir/hermes-webui-port"
  fi
  if [ -f "$backup_dir/config/hermes-webui-url" ]; then
    cp "$backup_dir/config/hermes-webui-url" "$config_dir/hermes-webui-url"
  fi

  log "restored last-known-good snapshot; previous runtime moved to $quarantine_dir"
  log "user data was not restored or modified: $hermes_home"
}

register_service() {
  [ -x "$openhouse_dir/register-service.sh" ] || die "missing register-service.sh"
  "$openhouse_dir/register-service.sh"
}

main() {
  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/hermes-webui-repair.XXXXXX")"
  curl_cfg="$work_dir/curl.cfg"
  status_file="$work_dir/status.json"
  cleanup() {
    rm -f "$curl_cfg" "$status_file" >/dev/null 2>&1 || true
    rmdir "$work_dir" >/dev/null 2>&1 || true
  }
  trap cleanup 0 INT HUP TERM

  token="$(service_manager_token)"
  write_curl_cfg "$curl_cfg" "$token"
  validate_foreground_server

  was_healthy=0
  if health_ok; then
    was_healthy=1
    log "Hermes WebUI is currently healthy."
  else
    log "Hermes WebUI is currently unhealthy or stopped."
  fi

  if [ "$was_healthy" = "1" ] && [ ! -d "$backup_dir" ]; then
    log "No last-known-good snapshot found; creating one before repair."
    create_snapshot_if_possible
  fi

  stop_service "$curl_cfg"

  if [ -d "$backup_dir" ]; then
    restore_last_known_good
  else
    warn "No snapshot is available; attempting re-register and start without restore."
  fi

  register_service
  validate_service_registry_contract
  start_service "$curl_cfg"
  wait_ready "$curl_cfg" "$status_file"
  log "Hermes WebUI repaired, service-manager state is running, and health passed at http://$webui_host:$webui_port"
  if [ ! -d "$backup_dir" ]; then
    create_snapshot_if_possible || warn "repair succeeded but snapshot creation failed"
  fi
  exit 0
}

main "$@"
