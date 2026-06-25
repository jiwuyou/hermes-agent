#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[OpenHouse Hermes] %s\n' "$*"
}

warn() {
  printf '[OpenHouse Hermes] WARN: %s\n' "$*" >&2
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

agent_dir="$(resolve_agent_dir)"
webui_dir="$(resolve_webui_dir)"
home_dir="${HOME:-/root}"
hermes_home="${HERMES_HOME:-$home_dir/.hermes}"
venv_python="${HERMES_WEBUI_PYTHON:-$agent_dir/venv/bin/python}"
webui_host="${HERMES_WEBUI_HOST:-127.0.0.1}"
webui_port="${HERMES_WEBUI_PORT:-23084}"
workspace_root="${HERMES_WEBUI_DEFAULT_WORKSPACE:-/root}"
start_script="$openhouse_dir/start-hermes-webui.sh"
server_script="$webui_dir/server.py"
sm_url="${SERVICE_MANAGER_URL:-${SMALLPHONE_SERVICE_MANAGER_URL:-http://127.0.0.1:20087}}"
registry_apply_path="${OPENHOUSEAI_REGISTRY_APPLY_PATH:-/api/v1/registry/apply}"
svc_name="hermes-webui"
svc_desc="Hermes WebUI managed by OpenHouseAI"

config_dir="${OPENHOUSEAI_CONFIG_DIR:-$home_dir/.config/openhouseai}"
components_dir="$config_dir/components.d"
ai_docs_dir="$config_dir/ai-docs/hermes-webui"
service_registry_dir="${OPENHOUSEAI_SERVICE_REGISTRY_DIR:-$config_dir/service-manager/services.d}"
termux_home="${OPENHOUSEAI_TERMUX_HOME:-/data/data/com.termux/files/home}"
termux_config_dir="${OPENHOUSEAI_TERMUX_CONFIG_DIR:-$termux_home/.config/openhouseai}"

component_source="$openhouse_dir/component-manifest.json"
ai_doc_source="$openhouse_dir/openhouse.ai.md"
capabilities_source="$openhouse_dir/capabilities.json"

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

find_python() {
  if [ -n "${HERMES_REGISTER_PYTHON:-}" ] && have "$HERMES_REGISTER_PYTHON"; then
    command -v "$HERMES_REGISTER_PYTHON"
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

validate_runtime_inputs() {
  [ -d "$agent_dir" ] || die "missing Hermes Agent directory: $agent_dir"
  [ -f "$agent_dir/pyproject.toml" ] || die "missing Hermes Agent pyproject.toml: $agent_dir/pyproject.toml"
  [ -d "$webui_dir" ] || die "missing Hermes WebUI directory: $webui_dir"
  [ -f "$webui_dir/bootstrap.py" ] || die "missing Hermes WebUI bootstrap.py: $webui_dir/bootstrap.py"
  [ -f "$server_script" ] || die "missing Hermes WebUI server.py: $server_script"
  [ -x "$venv_python" ] || die "Hermes Python is missing; run install first: $venv_python"
  [ -x "$start_script" ] || die "Hermes foreground wrapper is missing or not executable: $start_script"
  grep -Fq 'OPENHOUSE_FOREGROUND_WRAPPER=hermes-webui-v1' "$start_script" \
    || die "Hermes foreground wrapper missing OpenHouse contract marker: $start_script"
  grep -Fq 'exec -a "$exec_argv0" "$venv_python" "$server_path"' "$start_script" \
    || die "Hermes foreground wrapper must end by execing the long-running server with stable argv: $start_script"
  [ -f "$component_source" ] || die "missing project component manifest source: $component_source"
  [ -f "$ai_doc_source" ] || die "missing project AI doc source: $ai_doc_source"
  [ -f "$capabilities_source" ] || die "missing project capabilities source: $capabilities_source"
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
  "$py" - "$service_file" "$start_script" "$server_script" <<'PY'
import json
import sys

path, start_script, server_script = sys.argv[1:]
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
expected_command = [start_script, server_script]
if command != expected_command:
    raise SystemExit(
        "hermes-webui service.command must use the OpenHouse foreground wrapper "
        f"with stable argv: expected {expected_command!r}, got {command!r}"
    )
if any("bootstrap.py" in str(item) for item in command):
    raise SystemExit("hermes-webui service.command must not launch bootstrap.py under service-manager")
repair = service.get("repair")
if not isinstance(repair, dict):
    raise SystemExit("service-manager ServiceSpec must contain repair hook for hermes-webui")
if repair.get("mode") != "hook":
    raise SystemExit("service-manager ServiceSpec repair.mode must be hook")
repair_command = repair.get("command")
if not isinstance(repair_command, list) or not repair_command:
    raise SystemExit("service-manager ServiceSpec repair.command must be a non-empty argv")
PY
}

render_component_manifest() {
  py="$1"
  out="$2"
  "$py" - "$component_source" "$out" "$webui_host" "$webui_port" \
    "$agent_dir" "$webui_dir" "$hermes_home" "$workspace_root" \
    "$ai_docs_dir/openhouse.ai.md" "$ai_docs_dir/capabilities.json" <<'PY'
import json
import sys

(
    source,
    out,
    host,
    port,
    agent_dir,
    webui_dir,
    hermes_home,
    workspace_root,
    summary_doc,
    capabilities,
) = sys.argv[1:]

with open(source, "r", encoding="utf-8") as f:
    doc = json.load(f)

url = f"http://{host}:{port}"

def replace_urls(value):
    if isinstance(value, dict):
        for key, child in list(value.items()):
            if key == "url" and isinstance(child, str) and child.startswith("http://"):
                value[key] = url if child.rstrip("/") == "http://127.0.0.1:23084" else child.replace("http://127.0.0.1:23084", url)
            else:
                replace_urls(child)
    elif isinstance(value, list):
        for child in value:
            replace_urls(child)

replace_urls(doc)
doc.setdefault("ports", [])
for item in doc["ports"]:
    if isinstance(item, dict) and item.get("name") == "web":
        item["host"] = host
        item["port"] = int(port)
        item["url"] = url

for service in doc.get("serviceManager", {}).get("services", []):
    if not isinstance(service, dict) or service.get("name") != "hermes-webui":
        continue
    service["port"] = int(port)
    service["url"] = url
    health = service.get("health")
    if isinstance(health, dict):
        health["url"] = f"{url}/health"

ai = doc.setdefault("ai", {})
ai["summaryDoc"] = summary_doc
ai["capabilities"] = capabilities

doc["paths"] = {
    "agentDir": agent_dir,
    "webuiDir": webui_dir,
    "home": hermes_home,
    "workspaceRoot": workspace_root,
}

with open(out, "w", encoding="utf-8") as f:
    json.dump(doc, f, ensure_ascii=True, indent=2)
    f.write("\n")
PY
}

render_ai_docs() {
  py="$1"
  ai_doc_out="$2"
  capabilities_out="$3"

  "$py" - "$ai_doc_source" "$ai_doc_out" "$webui_host" "$webui_port" <<'PY'
import sys

source, out, host, port = sys.argv[1:]
with open(source, "r", encoding="utf-8") as f:
    text = f.read()
text = text.replace("http://127.0.0.1:23084", f"http://{host}:{port}")
with open(out, "w", encoding="utf-8") as f:
    f.write(text)
PY

  "$py" - "$capabilities_source" "$capabilities_out" "$webui_host" "$webui_port" <<'PY'
import json
import sys

source, out, host, port = sys.argv[1:]
with open(source, "r", encoding="utf-8") as f:
    doc = json.load(f)

url = f"http://{host}:{port}"

def replace_urls(value):
    if isinstance(value, dict):
        for key, child in list(value.items()):
            if key == "url" and isinstance(child, str) and child.startswith("http://"):
                value[key] = child.replace("http://127.0.0.1:23084", url)
            else:
                replace_urls(child)
    elif isinstance(value, list):
        for child in value:
            replace_urls(child)

replace_urls(doc)
with open(out, "w", encoding="utf-8") as f:
    json.dump(doc, f, ensure_ascii=True, indent=2)
    f.write("\n")
PY
}

emit_spec() {
  py="$1"
  "$py" - "$svc_name" "$svc_desc" "$webui_dir" "$agent_dir" "$venv_python" \
    "$hermes_home" "$webui_host" "$webui_port" "$workspace_root" "$openhouse_dir" \
    "$start_script" "$server_script" <<'PY'
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
    openhouse_dir,
    start_script,
    server_script,
) = sys.argv[1:]

spec = {
    "name": svc_name,
    "description": svc_desc,
    "provider": "process",
    "command": [
        start_script,
        server_script,
    ],
    "working_dir": workspace_root,
    "env": {
        "HERMES_HOME": hermes_home,
        "HERMES_AGENT_DIR": agent_dir,
        "HERMES_WEBUI_AGENT_DIR": agent_dir,
        "HERMES_WEBUI_PYTHON": venv_python,
        "HERMES_WEBUI_HOST": webui_host,
        "HERMES_WEBUI_PORT": str(webui_port),
        "HERMES_WEBUI_STATE_DIR": f"{hermes_home}/webui",
        "HERMES_WEBUI_DEFAULT_WORKSPACE": workspace_root,
        "HERMES_WEBUI_SERVER_CWD": workspace_root,
        "HERMES_WEBUI_AUTO_INSTALL": "0",
        "HERMES_WEBUI_SKIP_ONBOARDING": "0",
        "HERMES_WEBUI_FOREGROUND": "1",
        "PYTHONPATH": agent_dir,
        "PATH": "/root/.local/bin:/root/.local/node/bin:/root/.npm-global/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin:/system/bin:/system/xbin:/data/data/com.termux/files/usr/bin",
    },
    "runtime": {},
    "restart": {"mode": "always", "max_retries": 0},
    "repair": {
        "mode": "hook",
        "command": [
            "bash",
            f"{openhouse_dir}/repair-hermes-webui.sh",
        ],
        "working_dir": openhouse_dir,
        "timeout": "10m",
        "env": {
            "HERMES_AGENT_DIR": agent_dir,
            "HERMES_WEBUI_DIR": webui_dir,
            "HERMES_WEBUI_PYTHON": venv_python,
            "HERMES_HOME": hermes_home,
            "HERMES_WEBUI_HOST": webui_host,
            "HERMES_WEBUI_PORT": str(webui_port),
            "HERMES_WEBUI_DEFAULT_WORKSPACE": workspace_root,
        },
    },
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

emit_service_registry() {
  py="$1"
  spec_file="$2"
  out="$3"
  "$py" - "$spec_file" "$out" <<'PY'
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
}

emit_apply_payload() {
  py="$1"
  component_file="$2"
  service_spec_file="$3"
  ai_doc_file="$4"
  capabilities_file="$5"
  out="$6"
  "$py" - "$component_file" "$service_spec_file" "$ai_doc_file" "$capabilities_file" "$out" <<'PY'
import json
import sys

(
    component_path,
    service_spec_path,
    ai_doc_path,
    capabilities_path,
    out_path,
) = sys.argv[1:]

with open(component_path, "r", encoding="utf-8") as f:
    component = json.load(f)
with open(service_spec_path, "r", encoding="utf-8") as f:
    service_spec = json.load(f)
with open(ai_doc_path, "r", encoding="utf-8") as f:
    ai_doc = f.read()
with open(capabilities_path, "r", encoding="utf-8") as f:
    capabilities = json.load(f)
capabilities_content = json.dumps(capabilities, ensure_ascii=True, indent=2) + "\n"

payload = {
    "component": component,
    "services": [
        {
            "id": "hermes-webui",
            "service": service_spec,
        }
    ],
    "aiDocs": [
        {
            "path": "hermes-webui/openhouse.ai.md",
            "content": ai_doc,
        },
        {
            "path": "hermes-webui/capabilities.json",
            "content": capabilities_content,
        },
    ],
}

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=True, indent=2)
    f.write("\n")
PY
}

write_curl_cfg() {
  cfg="$1"
  token="$2"
  printf 'header = "Authorization: Bearer %s"\n' "$token" >"$cfg"
  printf 'header = "Content-Type: application/json"\n' >>"$cfg"
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

apply_registry_api() {
  payload_file="$1"
  curl_cfg="$2"
  response_file="$3"

  [ -n "$registry_apply_path" ] || die "OPENHOUSEAI_REGISTRY_APPLY_PATH is empty"
  case "$registry_apply_path" in
    http://*|https://*) apply_url="$registry_apply_path" ;;
    /*) apply_url="${sm_url%/}$registry_apply_path" ;;
    *) apply_url="${sm_url%/}/$registry_apply_path" ;;
  esac

  if ! have curl; then
    die "curl not found; cannot call service-manager registry API"
  fi
  if ! curl -fsS --max-time 2 "$sm_url/api/v1/health" >/dev/null 2>&1; then
    die "service-manager is not reachable at $sm_url; start service-manager before registering Hermes or set OPENHOUSEAI_REGISTRY_LEGACY_WRITE=1 for explicit debug fallback"
  fi

  http_code="$(
    curl -q -sS --max-time 10 \
      -o "$response_file" \
      -w '%{http_code}' \
      -X POST \
      -K "$curl_cfg" \
      --data-binary "@$payload_file" \
      "$apply_url" || true
  )"
  case "$http_code" in
    200|201|202|204)
      log "service-manager registry API applied Hermes component: $apply_url"
      return 0
      ;;
    *)
      if [ -s "$response_file" ]; then
        warn "service-manager registry API failed with HTTP $http_code: $(head -c 500 "$response_file")"
      else
        warn "service-manager registry API failed with HTTP $http_code and empty response"
      fi
      return 1
      ;;
  esac
}

legacy_sync_openhouse_registry_to_termux() {
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
  log "legacy registry synced to Termux canonical: $termux_config_dir"
}

legacy_write_registry() {
  component_file="$1"
  service_registry_file="$2"
  ai_doc_file="$3"
  capabilities_file="$4"

  mkdir -p "$components_dir" "$service_registry_dir" "$ai_docs_dir"
  cp "$component_file" "$components_dir/hermes-webui.json"
  cp "$service_registry_file" "$service_registry_dir/hermes-webui.json"
  cp "$ai_doc_file" "$ai_docs_dir/openhouse.ai.md"
  cp "$capabilities_file" "$ai_docs_dir/capabilities.json"
  chmod 600 \
    "$components_dir/hermes-webui.json" \
    "$service_registry_dir/hermes-webui.json" \
    "$ai_docs_dir/openhouse.ai.md" \
    "$ai_docs_dir/capabilities.json" 2>/dev/null || true
  printf '%s\n' "$webui_port" >"$config_dir/hermes-webui-port"
  printf 'http://%s:%s\n' "$webui_host" "$webui_port" >"$config_dir/hermes-webui-url"
  legacy_sync_openhouse_registry_to_termux
  warn "used OPENHOUSEAI_REGISTRY_LEGACY_WRITE=1 debug fallback; normal registration should use service-manager registry API"
}

main() {
  py="$(find_python)" || die "python not found; cannot prepare Hermes registry payload"
  validate_runtime_inputs

  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/hermes-registry.XXXXXX")"
  curl_cfg="$work_dir/curl.cfg"
  component_file="$work_dir/component-manifest.json"
  service_spec_file="$work_dir/service-spec.json"
  service_registry_file="$work_dir/service-registry.json"
  ai_doc_file="$work_dir/openhouse.ai.md"
  capabilities_file="$work_dir/capabilities.json"
  payload_file="$work_dir/registry-apply.json"
  response_file="$work_dir/registry-apply-response.json"
  cleanup() {
    rm -f "$curl_cfg" "$component_file" "$service_spec_file" "$service_registry_file" \
      "$ai_doc_file" "$capabilities_file" "$payload_file" "$response_file" >/dev/null 2>&1 || true
    rmdir "$work_dir" >/dev/null 2>&1 || true
  }
  trap cleanup 0 INT HUP TERM

  render_component_manifest "$py" "$component_file"
  render_ai_docs "$py" "$ai_doc_file" "$capabilities_file"
  emit_spec "$py" >"$service_spec_file"
  emit_service_registry "$py" "$service_spec_file" "$service_registry_file"
  validate_component_manifest "$py" "$component_file"
  validate_service_registry "$py" "$service_registry_file"
  emit_apply_payload "$py" "$component_file" "$service_spec_file" "$ai_doc_file" "$capabilities_file" "$payload_file"

  if [ "${OPENHOUSEAI_REGISTRY_LEGACY_WRITE:-0}" = "1" ]; then
    legacy_write_registry "$component_file" "$service_registry_file" "$ai_doc_file" "$capabilities_file"
    exit 0
  fi

  token="$(service_manager_token)"
  [ -n "$token" ] || die "service-manager token unavailable; cannot call registry API"
  write_curl_cfg "$curl_cfg" "$token"
  apply_registry_api "$payload_file" "$curl_cfg" "$response_file"
}

main "$@"
