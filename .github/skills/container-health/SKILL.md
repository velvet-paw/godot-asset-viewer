---
name: container-health
description: Container health checks and lifecycle management for ComfyUI and Blender MCP containers used in the 3D asset generation pipeline. Use when starting/stopping containers, checking container health, troubleshooting container issues, or performing preflight checks before asset generation.
allowed-tools: shell
---

# Container Health & Lifecycle

## Quick Health Check

```bash
# ComfyUI
curl -sf http://localhost:8188/system_stats >/dev/null && echo "ComfyUI OK" || echo "ComfyUI DOWN"

# Blender MCP
curl -sf --max-time 30 http://localhost:8000/mcp -X POST \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
  2>/dev/null | grep -q '^data: ' && echo "Blender MCP OK" || echo "Blender MCP DOWN"
```

## Container Inventory

| Container | Compose Stack | Script | Port | Purpose |
|-----------|--------------|--------|------|---------|
| `gaap-comfyui` | `comfyui/docker-compose.yml` | `./compose-comfyui.sh` | 8188 | AI generation (Flux, BiRefNet, Trellis2, CHORD) |
| `gaap-blender` | `blender/docker-compose.yml` | `./compose-run.sh` | — | Blender headless renderer |
| `gaap-blender-mcp` | `blender/docker-compose.yml` | `./compose-run.sh` | 8000 | MCP server for Blender scripting |

## Starting Containers

**ComfyUI down:**
```bash
./compose-comfyui.sh          # Builds + starts + waits (~2 min)
```

**Blender MCP down — check which containers need attention:**
```bash
podman ps -a --format '{{.Names}} {{.Status}}' | grep -E 'gaap-blender|gaap-blender-mcp'
```

- Both missing/stopped → `./compose-run.sh` (~2 min)
- Only `gaap-blender-mcp` Exited while `gaap-blender` Up → `podman start gaap-blender-mcp` (~10s)
- After starting, wait ~10s then re-run health check

## Teardown & Status

```bash
./compose-comfyui.sh --teardown   # Stop ComfyUI
./compose-run.sh --teardown       # Stop Blender + MCP

./compose-comfyui.sh --status
./compose-run.sh --status
```

## Troubleshooting

```bash
podman ps -a --format '{{.Names}} {{.Status}}'
podman logs gaap-comfyui --tail 50
podman logs gaap-blender --tail 50
podman logs gaap-blender-mcp --tail 50
```

## Asset Directory Setup

```bash
mkdir -p ~/assets/{concepts,masked,raw_3d,pbr_maps,final_glb,validation_reports}
```

## Infrastructure Retry Pattern

Transient failures (ConnectionResetError, container timeout, MCP unreachable) get up to 3 retries and do NOT count against quality attempt budgets:

```bash
for i in 1 2 3; do
    if run_stage_command; then break; fi
    echo "Transient failure, retry $i/3..."
    sleep 10
done
```

## Important Notes

- Container runtime is **Podman** — never use `docker` commands
- CUDA_VISIBLE_DEVICES is always 0 inside containers — CDI remaps GPUs
- Images: `gaap/comfyui:latest`, `gaap/blender:latest`, `gaap/blender-mcp:latest`
- Override tag: `GAAP_VERSION=v1.2.3`
- Image builds are in the `blender-container` repository, NOT here
