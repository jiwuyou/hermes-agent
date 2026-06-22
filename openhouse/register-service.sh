#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[OpenHouse Hermes] %s\n' "$*"
}

warn() {
  printf '[OpenHouse Hermes] WARN: %s\n' "$*" >&2
}

bundle_root="$(cd "$(dirname "$0")/.." >/dev/null 2>&1 && pwd)"

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
venv_python="${HERMES_WEBUI_PYTHON:-$agent_dir/venv/bin/python}"
webui_host="${HERMES_WEBUI_HOST:-127.0.0.1}"
webui_port="${HERMES_WEBUI_PORT:-23084}"
workspace_root="${HERMES_WEBUI_DEFAULT_WORKSPACE:-/root}"
sm_url="${SERVICE_MANAGER_URL:-${SMALLPHONE_SERVICE_MANAGER_URL:-http://127.0.0.1:20087}}"
svc_name="hermes-webui"
svc_desc="Hermes WebUI managed by OpenHouseAI"
config_dir="${OPENHOUSEAI_CONFIG_DIR:-$home_dir/.config/openhouseai}"
components_dir="$config_dir/components.d"
ai_docs_dir="$config_dir/ai-docs/hermes-webui"
service_registry_dir="${OPENHOUSEAI_SERVICE_REGISTRY_DIR:-$config_dir/service-manager/services.d}"
termux_home="${OPENHOUSEAI_TERMUX_HOME:-/data/data/com.termux/files/home}"
termux_config_dir="${OPENHOUSEAI_TERMUX_CONFIG_DIR:-$termux_home/.config/openhouseai}"

have() {
  command -v "$1" >/dev/null 2>&1
}

validate_component_manifest() {
  py="$1"
  manifest="$2"
  "$py" - "$manifest" <<'PY'
import json
import sys

path = sys.argv[1]
forbidden = {"command", "shell", "script", "args"}

def walk(value, location):
    if isinstance(value, dict):
        for key, child in value.items():
            child_location = f"{location}.{key}" if location else key
            if key.lower() in forbidden:
                raise SystemExit(
                    f"component manifest contains forbidden executable key {child_location!r}; "
                    "this rule applies only to components.d/*.json, not bootstrap manifests or service-manager ServiceSpec"
                )
            walk(child, child_location)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            walk(child, f"{location}[{index}]")

with open(path, "r", encoding="utf-8") as handle:
    doc = json.load(handle)

missing = [key for key in ("shellMenu", "smallphoneApp", "serviceManager", "ai") if key not in doc]
if missing:
    raise SystemExit(f"component manifest missing required layers: {', '.join(missing)}")

if doc.get("id") != "hermes-webui":
    raise SystemExit("component manifest id must be hermes-webui")

services = doc.get("serviceManager", {}).get("services", [])
if not any(isinstance(service, dict) and service.get("name") == "hermes-webui" for service in services):
    raise SystemExit("component manifest missing serviceManager.services hermes-webui entry")

walk(doc, "$")
PY
}

validate_service_registry() {
  py="$1"
  service_file="$2"
  "$py" - "$service_file" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    doc = json.load(handle)

if doc.get("id") != "hermes-webui":
    raise SystemExit("service registry id must be hermes-webui")

service = doc.get("service")
if not isinstance(service, dict):
    raise SystemExit("service registry must contain service object")
if service.get("name") != "hermes-webui":
    raise SystemExit("service registry service.name must be hermes-webui")
command = service.get("command")
if not isinstance(command, list) or not command:
    raise SystemExit("service-manager ServiceSpec must contain service.command; this is allowed outside component manifests")
PY
}

write_ai_docs() {
  mkdir -p "$ai_docs_dir"
  if [ -f "$bundle_root/openhouse.ai.md" ]; then
    cp "$bundle_root/openhouse.ai.md" "$ai_docs_dir/openhouse.ai.md"
  elif [ -f "$webui_dir/openhouse.ai.md" ]; then
    cp "$webui_dir/openhouse.ai.md" "$ai_docs_dir/openhouse.ai.md"
  else
    cat >"$ai_docs_dir/openhouse.ai.md" <<EOF
# Hermes WebUI

Hermes WebUI is an OpenHouseAI AI partner exposed at http://$webui_host:$webui_port.
Use service-manager service hermes-webui for status, start, stop, restart, logs, and repair.
EOF
  fi
  cat >"$ai_docs_dir/capabilities.json" <<EOF
{
  "schemaVersion": 1,
  "componentId": "hermes-webui",
  "title": "Hermes",
  "entry": {
    "type": "webview",
    "url": "http://$webui_host:$webui_port"
  },
  "services": [
    {
      "name": "hermes-webui",
      "serviceRef": "service-manager://services/hermes-webui",
      "controls": {
        "status": "service-manager://services/hermes-webui/status",
        "start": "service-manager://services/hermes-webui/start",
        "stop": "service-manager://services/hermes-webui/stop",
        "restart": "service-manager://services/hermes-webui/restart",
        "logs": "service-manager://services/hermes-webui/logs",
        "repair": "service-manager://actions/hermes-webui.repair"
      }
    }
  ],
  "capabilities": [
    {
      "id": "ai-partner-web-console",
      "title": "Hermes WebUI",
      "description": "Open, configure, and use Hermes through the managed WebUI."
    },
    {
      "id": "service-control",
      "title": "Managed lifecycle",
      "description": "Lifecycle control is delegated to service-manager."
    }
  ]
}
EOF
  chmod 600 "$ai_docs_dir/openhouse.ai.md" "$ai_docs_dir/capabilities.json" 2>/dev/null || true
}

write_component_manifest() {
  local manifest="$components_dir/hermes-webui.json"
  mkdir -p "$components_dir"
  cat >"$manifest" <<EOF
{
  "schemaVersion": 1,
  "id": "hermes-webui",
  "title": "Hermes",
  "description": "Hermes AI partner web console managed by OpenHouseAI.",
  "kind": "ai-partner",
  "version": "0.1.0-openhouse",
  "shellMenu": {
    "visible": true,
    "section": "ai",
    "order": 40,
    "entry": {
      "type": "webview",
      "url": "http://$webui_host:$webui_port"
    },
    "controlEntry": {
      "type": "service-control",
      "serviceNames": ["hermes-webui"],
      "serviceRefs": ["service-manager://services/hermes-webui"]
    }
  },
  "smallphoneApp": {
    "visible": true,
    "section": "ai",
    "order": 40,
    "icon": "sparkles",
    "entry": {
      "type": "webview",
      "url": "http://$webui_host:$webui_port"
    },
    "controlEntry": {
      "type": "service-control",
      "serviceNames": ["hermes-webui"],
      "serviceRefs": ["service-manager://services/hermes-webui"]
    }
  },
  "serviceManager": {
    "required": true,
    "services": [
      {
        "name": "hermes-webui",
        "title": "Hermes WebUI",
        "role": "web",
        "port": $webui_port,
        "url": "http://$webui_host:$webui_port",
        "serviceRef": "service-manager://services/hermes-webui",
        "health": {
          "type": "http",
          "url": "http://$webui_host:$webui_port/health"
        },
        "controls": ["status", "start", "stop", "restart", "logs", "repair"],
        "repairActionRef": "service-manager://actions/hermes-webui.repair"
      }
    ]
  },
  "ai": {
    "visible": true,
    "summaryDoc": "$ai_docs_dir/openhouse.ai.md",
    "capabilities": "$ai_docs_dir/capabilities.json",
    "intents": [
      { "name": "open", "target": "shellMenu.entry" },
      { "name": "control", "target": "shellMenu.controlEntry" },
      { "name": "repair", "target": "serviceManager.services.hermes-webui.repairActionRef" }
    ]
  },
  "ports": [
    {
      "name": "web",
      "host": "$webui_host",
      "port": $webui_port,
      "url": "http://$webui_host:$webui_port"
    }
  ],
  "paths": {
    "agentDir": "$agent_dir",
    "webuiDir": "$webui_dir",
    "home": "$hermes_home",
    "workspaceRoot": "$workspace_root"
  },
  "tags": ["group:local-stack", "openhouse-component:hermes-webui", "openhouse-ai-partner:hermes"]
}
EOF
  chmod 600 "$manifest" 2>/dev/null || true
  printf '%s\n' "$webui_port" >"$config_dir/hermes-webui-port"
  printf 'http://%s:%s\n' "$webui_host" "$webui_port" >"$config_dir/hermes-webui-url"
  log "component manifest written: $manifest"
}

write_service_registry() {
  py="$1"
  spec_file="$2"
  mkdir -p "$service_registry_dir"
  "$py" - "$spec_file" "$service_registry_dir/hermes-webui.json" <<'PY'
import json
import sys

spec_path, out_path = sys.argv[1:]
with open(spec_path, "r", encoding="utf-8") as f:
    spec = json.load(f)

doc = {
    "schemaVersion": 1,
    "id": "hermes-webui",
    "service": spec,
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(doc, f, ensure_ascii=True, indent=2)
    f.write("\n")
PY
  chmod 600 "$service_registry_dir/hermes-webui.json" 2>/dev/null || true
  log "service-manager service registry written: $service_registry_dir/hermes-webui.json"
}

sync_openhouse_registry_to_termux() {
  [ "${OPENHOUSEAI_SKIP_TERMUX_SYNC:-0}" = "1" ] && return 0
  [ -n "$termux_config_dir" ] || return 0
  [ "$config_dir" = "$termux_config_dir" ] && return 0
  [ -d "$termux_home" ] || return 0

  mkdir -p "$termux_config_dir/components.d" \
    "$termux_config_dir/ai-docs" \
    "$termux_config_dir/service-manager/services.d"
  if [ -d "$config_dir/components.d" ]; then
    cp -a "$config_dir/components.d/." "$termux_config_dir/components.d/" 2>/dev/null || true
  fi
  if [ -d "$config_dir/ai-docs" ]; then
    cp -a "$config_dir/ai-docs/." "$termux_config_dir/ai-docs/" 2>/dev/null || true
  fi
  if [ -d "$config_dir/service-manager/services.d" ]; then
    cp -a "$config_dir/service-manager/services.d/." "$termux_config_dir/service-manager/services.d/" 2>/dev/null || true
  fi
  log "OpenHouseAI registry synced to Termux canonical: $termux_config_dir"
}

service_name_to_id() {
  py="$1"
  name="$2"
  "$py" -c '
import json
import sys

name = sys.argv[1]
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)
try:
    payload = json.loads(raw)
except Exception:
    sys.exit(0)
services = payload if isinstance(payload, list) else []
for svc in services:
    if not isinstance(svc, dict):
        continue
    spec = svc.get("spec")
    if isinstance(spec, dict) and spec.get("name") == name:
        sid = svc.get("id")
        if isinstance(sid, str) and sid:
            sys.stdout.write(sid)
            break
' "$name"
}

write_curl_cfg() {
  cfg="$1"
  token="$2"
  printf 'header = "Authorization: Bearer %s"\n' "$token" >"$cfg"
  printf 'header = "Content-Type: application/json"\n' >>"$cfg"
}

emit_spec() {
  py="$1"
  "$py" - "$svc_name" "$svc_desc" "$webui_dir" "$agent_dir" "$venv_python" \
    "$hermes_home" "$webui_host" "$webui_port" "$workspace_root" <<'PY'
import json
import sys

(
    svc_name,
    svc_desc,
    webui_dir,
    agent_dir,
    venv_python,
    hermes_home,
    webui_host,
    webui_port,
    workspace_root,
) = sys.argv[1:]

spec = {
    "name": svc_name,
    "description": svc_desc,
    "provider": "process",
    "command": [
        venv_python,
        "./bootstrap.py",
        "--no-browser",
        "--foreground",
        "--skip-agent-install",
        "--host",
        webui_host,
        str(webui_port),
    ],
    "working_dir": webui_dir,
    "env": {
        "HERMES_HOME": hermes_home,
        "HERMES_WEBUI_AGENT_DIR": agent_dir,
        "HERMES_WEBUI_PYTHON": venv_python,
        "HERMES_WEBUI_HOST": webui_host,
        "HERMES_WEBUI_PORT": str(webui_port),
        "HERMES_WEBUI_STATE_DIR": f"{hermes_home}/webui",
        "HERMES_WEBUI_DEFAULT_WORKSPACE": workspace_root,
        "HERMES_WEBUI_SERVER_CWD": workspace_root,
        "HERMES_WEBUI_AUTO_INSTALL": "0",
        "HERMES_WEBUI_SKIP_ONBOARDING": "0",
        "PATH": "/root/.local/bin:/root/.local/node/bin:/root/.npm-global/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin:/system/bin:/system/xbin:/data/data/com.termux/files/usr/bin",
    },
    "runtime": {},
    "restart": {"mode": "always", "max_retries": 0},
    "health": [
        {
            "type": "http",
            "url": f"http://{webui_host}:{webui_port}/health",
            "interval": "30s",
            "timeout": "5s",
        }
    ],
    "enabled": True,
    "tags": [
        "group:local-stack",
        "openhouse-component:hermes-webui",
        "openhouse-ai-partner:hermes",
    ],
}
json.dump(spec, sys.stdout, ensure_ascii=True)
PY
}

main() {
  py=""
  if have python3; then
    py="python3"
  elif have python; then
    py="python"
  fi

  write_ai_docs
  write_component_manifest
  if [ -n "$py" ]; then
    validate_component_manifest "$py" "$components_dir/hermes-webui.json"
  fi
  sync_openhouse_registry_to_termux

  if [ ! -x "$venv_python" ]; then
    warn "Hermes Python is missing, install first: $venv_python"
    exit 0
  fi

  if [ -z "$py" ]; then
    warn "python not found; skipped service registry and API registration."
    exit 0
  fi

  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/hermes-sm.XXXXXX")"
  curl_cfg="$work_dir/curl.cfg"
  spec_file="$work_dir/service-spec.json"
  cleanup() {
    rm -f "$curl_cfg" "$spec_file" >/dev/null 2>&1 || true
    rmdir "$work_dir" >/dev/null 2>&1 || true
  }
  trap cleanup 0 INT HUP TERM

  emit_spec "$py" >"$spec_file"
  write_service_registry "$py" "$spec_file"
  validate_component_manifest "$py" "$components_dir/hermes-webui.json"
  validate_service_registry "$py" "$service_registry_dir/hermes-webui.json"
  sync_openhouse_registry_to_termux

  if ! have service-manager; then
    warn "service-manager CLI not found; services.d has been written, skipped API registration."
    exit 0
  fi
  if ! have curl; then
    warn "curl not found; services.d has been written, skipped API registration."
    exit 0
  fi
  if ! curl -fsS --max-time 2 "$sm_url/api/v1/health" >/dev/null 2>&1; then
    warn "service-manager is not reachable at $sm_url; services.d has been written, skipped API registration."
    exit 0
  fi

  sm_token="${SERVICE_MANAGER_TOKEN:-${SMALLPHONE_SERVICE_MANAGER_TOKEN:-}}"
  if [ -z "$sm_token" ]; then
    sm_token="$(service-manager token show 2>/dev/null | tr -d '\r\n' || true)"
  fi
  if [ -z "$sm_token" ]; then
    warn "service-manager token unavailable; services.d has been written, skipped API registration."
    exit 0
  fi
  write_curl_cfg "$curl_cfg" "$sm_token"

  services_json="$(curl -q -fsS --max-time 3 -K "$curl_cfg" "$sm_url/api/v1/services" 2>/dev/null || true)"
  svc_id="$(printf '%s' "$services_json" | service_name_to_id "$py" "$svc_name" 2>/dev/null || true)"

  if [ -n "$svc_id" ]; then
    log "service-manager: updating $svc_name"
    curl -q -fsS --max-time 5 -X PUT -K "$curl_cfg" --data-binary "@$spec_file" "$sm_url/api/v1/services/$svc_id" >/dev/null
    curl -q -fsS --max-time 5 -X POST -K "$curl_cfg" "$sm_url/api/v1/services/$svc_id/register" >/dev/null 2>&1 || true
    log "service-manager: updated and registered $svc_name"
    exit 0
  fi

  log "service-manager: creating $svc_name"
  create_resp="$(curl -q -fsS --max-time 5 -X POST -K "$curl_cfg" --data-binary "@$spec_file" "$sm_url/api/v1/services" 2>/dev/null || true)"
  created_id="$(printf '%s' "$create_resp" | "$py" -c 'import json,sys
raw=sys.stdin.read().strip()
if raw:
    try:
        payload=json.loads(raw)
        sid=payload.get("id", "") if isinstance(payload, dict) else ""
        sys.stdout.write(sid if isinstance(sid, str) else "")
    except Exception:
        pass
' 2>/dev/null || true)"
  if [ -n "$created_id" ]; then
    curl -q -fsS --max-time 5 -X POST -K "$curl_cfg" "$sm_url/api/v1/services/$created_id/register" >/dev/null 2>&1 || true
    log "service-manager: created and registered $svc_name"
  else
    warn "service-manager create response did not include an id."
  fi
}

main "$@"
