# OpenHouse Hermes Integration

Hermes is an AI partner managed by OpenHouseAI. It is exposed through Hermes WebUI on `http://127.0.0.1:23084` and controlled by service-manager as service `hermes-webui`.

## Open

Use the component registry entry `hermes-webui`. The Android shell should open the entry as a WebView:

```text
http://127.0.0.1:23084
```

## Control

Use service-manager refs. Do not run arbitrary shell commands from component JSON.

- Service: `service-manager://services/hermes-webui`
- Status: `service-manager://services/hermes-webui/status`
- Start: `service-manager://services/hermes-webui/start`
- Stop: `service-manager://services/hermes-webui/stop`
- Restart: `service-manager://services/hermes-webui/restart`
- Logs: `service-manager://services/hermes-webui/logs`
- Repair: `service-manager://actions/hermes-webui.repair`
- Health: `GET http://127.0.0.1:23084/health`

## Registration Contract

Hermes registers into four OpenHouseAI layers:

- `shellMenu`: Android App shell sidebar entry.
- `smallphoneApp`: SmallPhone desktop app entry.
- `serviceManager`: managed service metadata and lifecycle refs.
- `ai`: AI-readable docs, capabilities, and intent mappings.

The forbidden executable fields `command`, `shell`, `script`, and `args` apply
only to `components.d/*.json` component manifests. service-manager ServiceSpec
files intentionally keep `service.command` because service-manager owns process
execution.

## Files

- Agent source: `/root/smallphoneai-repos/hermes/hermes-agent`
- WebUI source: `/root/smallphoneai-repos/hermes/hermes-webui`
- Runtime data: `/root/.hermes`
- Component registry: `/root/.config/openhouseai/components.d/hermes-webui.json`
- service-manager registry: `/root/.config/openhouseai/service-manager/services.d/hermes-webui.json`
- AI capabilities: `/root/.config/openhouseai/ai-docs/hermes-webui/capabilities.json`
- Component schema: `component-manifest.schema.json`

## Repair

1. Call `service-manager://actions/hermes-webui.repair`.
2. Check `http://127.0.0.1:23084/health`.
3. If repair still fails, ask the App Shell to run the Hermes install stage from the maintenance UI.

## Notes

The APK bundle contains source snapshots for Hermes Agent and Hermes WebUI, so first-run install does not require GitHub. Python package downloads may still use PyPI or the configured package mirror.
