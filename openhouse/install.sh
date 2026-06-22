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
venv_dir="${HERMES_AGENT_VENV:-$agent_dir/venv}"
venv_python="$venv_dir/bin/python"
webui_port="${HERMES_WEBUI_PORT:-23084}"
webui_host="${HERMES_WEBUI_HOST:-127.0.0.1}"
workspace_root="${HERMES_WEBUI_DEFAULT_WORKSPACE:-/root}"
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
  local py="$1"
  local manifest="$2"
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
  local py="$1"
  local service_file="$2"
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
    "$components_dir" \
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
}

write_service_registry() {
  mkdir -p "$service_registry_dir"
  "$venv_python" - "$service_registry_dir/hermes-webui.json" "$svc_name" "$svc_desc" \
    "$webui_dir" "$agent_dir" "$venv_python" "$hermes_home" "$webui_host" "$webui_port" "$workspace_root" <<'PY'
import json
import sys

(
    out_path,
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

main() {
  ensure_apt_packages
  ensure_dirs
  ensure_python_env
  write_launchers
  write_webui_env
  write_ai_docs
  write_component_manifest
  write_service_registry
  validate_component_manifest "$venv_python" "$components_dir/hermes-webui.json"
  validate_service_registry "$venv_python" "$service_registry_dir/hermes-webui.json"
  sync_openhouse_registry_to_termux
  log "Hermes installed. WebUI URL: http://$webui_host:$webui_port"
}

main "$@"
