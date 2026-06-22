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
venv_python="${HERMES_WEBUI_PYTHON:-$agent_dir/venv/bin/python}"
webui_port="${HERMES_WEBUI_PORT:-23084}"
webui_host="${HERMES_WEBUI_HOST:-127.0.0.1}"
config_dir="${OPENHOUSEAI_CONFIG_DIR:-$home_dir/.config/openhouseai}"
manifest="$config_dir/components.d/hermes-webui.json"
service_registry="$config_dir/service-manager/services.d/hermes-webui.json"
ai_doc="$config_dir/ai-docs/hermes-webui/openhouse.ai.md"
capabilities="$config_dir/ai-docs/hermes-webui/capabilities.json"
component_schema="$openhouse_dir/component-manifest.schema.json"
termux_home="${OPENHOUSEAI_TERMUX_HOME:-/data/data/com.termux/files/home}"
termux_config_dir="${OPENHOUSEAI_TERMUX_CONFIG_DIR:-$termux_home/.config/openhouseai}"

[ -d "$agent_dir" ] || { warn "missing Hermes Agent directory: $agent_dir"; exit 2; }
[ -f "$agent_dir/pyproject.toml" ] || { warn "missing Hermes Agent pyproject.toml"; exit 2; }
[ -d "$webui_dir" ] || { warn "missing Hermes WebUI directory: $webui_dir"; exit 2; }
[ -f "$webui_dir/bootstrap.py" ] || { warn "missing Hermes WebUI bootstrap.py"; exit 2; }
[ -x "$venv_python" ] || { warn "missing Hermes Python: $venv_python"; exit 3; }
[ -f "$manifest" ] || { warn "missing component manifest: $manifest"; exit 4; }
[ -f "$service_registry" ] || { warn "missing service-manager registry: $service_registry"; exit 4; }
[ -f "$ai_doc" ] || { warn "missing AI doc: $ai_doc"; exit 4; }
[ -f "$capabilities" ] || { warn "missing AI capabilities: $capabilities"; exit 4; }
[ -f "$component_schema" ] || { warn "missing component manifest schema: $component_schema"; exit 4; }

"$venv_python" - "$agent_dir" <<'PY'
import os
import sys

agent_dir = sys.argv[1]
sys.path.insert(0, agent_dir)
import yaml  # noqa: F401
from run_agent import AIAgent  # noqa: F401
PY

"$venv_python" - "$manifest" "$service_registry" "$capabilities" "$component_schema" "$termux_config_dir" <<'PY'
import json
import pathlib
import sys

component_path, service_path, capabilities_path, schema_path, termux_config_dir = sys.argv[1:]
for path in (component_path, service_path, capabilities_path, schema_path):
    with open(path, "r", encoding="utf-8") as f:
        json.load(f)

with open(component_path, "r", encoding="utf-8") as f:
    component = json.load(f)

forbidden = {"command", "shell", "script", "args"}

def walk_component(value, location="$"):
    if isinstance(value, dict):
        for key, child in value.items():
            child_location = f"{location}.{key}" if location else key
            if key.lower() in forbidden:
                raise SystemExit(
                    f"forbidden component manifest key: {child_location}; "
                    "this rule only applies to components.d/*.json, not bootstrap manifests or service-manager ServiceSpec"
                )
            walk_component(child, child_location)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            walk_component(child, f"{location}[{index}]")

required = ("shellMenu", "smallphoneApp", "serviceManager", "ai")
missing = [key for key in required if key not in component]
if missing:
    raise SystemExit(f"component manifest missing required layers: {', '.join(missing)}")
walk_component(component)

services = component.get("serviceManager", {}).get("services", [])
if not any(isinstance(svc, dict) and svc.get("name") == "hermes-webui" for svc in services):
    raise SystemExit("component manifest missing hermes-webui serviceManager entry")

with open(service_path, "r", encoding="utf-8") as f:
    service_doc = json.load(f)
if service_doc.get("id") != "hermes-webui":
    raise SystemExit("service registry id must be hermes-webui")
service = service_doc.get("service", {})
if service.get("name") != "hermes-webui":
    raise SystemExit("service registry service.name must be hermes-webui")
if not isinstance(service.get("command"), list) or not service.get("command"):
    raise SystemExit("service-manager ServiceSpec must keep service.command; forbidden-key policy is component-manifest only")

termux_root = pathlib.Path(termux_config_dir)
if termux_root.exists():
    mirrors = [
        termux_root / "components.d" / "hermes-webui.json",
        termux_root / "service-manager" / "services.d" / "hermes-webui.json",
        termux_root / "ai-docs" / "hermes-webui" / "openhouse.ai.md",
        termux_root / "ai-docs" / "hermes-webui" / "capabilities.json",
    ]
    missing_mirrors = [str(path) for path in mirrors if not path.exists()]
    if missing_mirrors:
        raise SystemExit("Termux canonical registry is missing Hermes files: " + ", ".join(missing_mirrors))
PY

log "Hermes sources, Python imports, four-layer component manifest, service registry, AI docs, and registry sync are valid."
if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 2 "http://$webui_host:$webui_port/health" >/dev/null 2>&1; then
  log "Hermes WebUI is healthy at http://$webui_host:$webui_port"
else
  log "Hermes WebUI is installed but not currently reachable at http://$webui_host:$webui_port"
fi

printf 'hermes_home=%s\nagent_dir=%s\nwebui_dir=%s\nurl=http://%s:%s\n' \
  "$hermes_home" "$agent_dir" "$webui_dir" "$webui_host" "$webui_port"
