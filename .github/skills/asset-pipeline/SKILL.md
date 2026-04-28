---
name: asset-pipeline
description: Asset generation pipeline for 3D game assets (ComfyUI + Trellis2 + CHORD PBR + Blender). Use this skill when working with pipeline/ scripts, infra/ container management (compose-comfyui.sh, compose-blender.sh, Podman), ComfyUI workflows, Trellis2 3D generation, Blender MCP post-processing, asset quality/validation, or discussing 3D asset creation stages and parameters.
allowed-tools: shell
---

# Asset Generation Pipeline

## Pipeline Stages

| Stage | Tool | Purpose | Time (RTX 3090) |
|-------|------|---------|-----------------|
| 1 — Concept | ComfyUI (Flux.1 Dev) | Text-to-image generation | ~30s |
| 2 — Mask | BiRefNet-HR | Background removal | ~4s |
| 3 — 3D | Trellis2 4B | Image-to-3D textured mesh | 1–9 min |
| 4-5 — PBR | CHORD v1 | PBR material maps (only when Trellis2 textures absent) | ~8s |
| 6 — Post-process | Blender (MCP) | Mesh cleanup, decimation, rigging, LODs, export | ~12s |

**Flow:** `concept → mask → Trellis2 3D (baked textures) → Blender post-process`

Trellis2 baked textures are preserved by default. CHORD PBR is only applied when textures are stripped (`FORCE_PBR=1`) or absent.

## Stage 6 Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ASSET_TYPE` | `creature` | Controls vertex target, scale, rigging |
| `TARGET_VERTS` | (per type) | Override vertex target |
| `TARGET_HEIGHT` | (per type) | Override height in meters |
| `GENERATE_LODS` | `0` | Set `1` to produce LOD1 + LOD2 |
| `GENERATE_COLLISION` | `0` | Set `1` to produce convex hull collision |
| `FORCE_PBR` | `0` | Set `1` to strip Trellis2 textures and apply fresh UV + CHORD PBR |
| `UV_METHOD` | `smart` | `smart` for Smart UV Project, `camera` for concept-art-aligned projection |
| `PBR_CHANNELS` | `all` | Comma-separated list: `albedo,normal,roughness,metallic,height` |
| `SKIP_RIGGING` | `0` | Set `1` to skip armature/weighting |
| `SKIP_GROUND_REMOVAL` | `0` | Set `1` to keep ground plane |

## Vertex Targets (Trellis2 Baked Textures)

| ASSET_TYPE | Target Verts | Target Height | Auto-Rig |
|------------|-------------|---------------|----------|
| `creature` | 150,000 | 1.0m | Yes (creature) |
| `humanoid` | 15,000 | 1.75m | Yes (21-bone biped) |
| `prop` | 100,000 | 0.8m | No |
| `weapon` | 50,000 | 1.0m | No |

**Universal rule:** ALL asset types need 50K+ vertices to preserve Trellis2 baked UV mapping. Decimating below 50K destroys UV fidelity regardless of asset type.

## Creature-Specific Guidance

- **Concept art must have color variation** — uniform white/grey surfaces expose Trellis2 groove artifacts. Use distinct markings (e.g., grey body, lighter belly, darker back).
- **Quadruped prompts**: include `three-quarter front view, all four legs visible and separated, fluffy tail, bold clean cel-shaded forms`.
- **Trellis2 default params**: keep at 12 sampling steps, 7.5 guidance. Higher values cause CUDA OOM on RTX 3090.

## Prompting Guidelines

| Asset Type | Prompt Keywords |
|-----------|----------------|
| Weapons/props | `centered, single object, orthographic, flat lighting` |
| Characters | `front view, 3D rendered, volumetric, full body, neutral A-pose, arms slightly away from torso, legs separated` |
| Creatures | `three-quarter front view, all four legs visible and separated, bold clean cel-shaded forms, natural coloring with visible markings` |

Always include: `game asset, flat lighting, no shadows, neutral grey background`

## Output Directories

```
~/assets/
  concepts/     # Stage 1 — concept_NNNNN_.png
  masked/       # Stage 2 — masked_NNNNN_.png
  raw_3d/       # Stage 3 — {asset}_NNNNN_.glb
  pbr_maps/     # Stage 4-5 — {asset}_{channel}_NNNNN_.png
  final_glb/    # Stage 6 — {asset}_final.glb
```

- **Import**: `tools/import-asset.sh` copies assets into `res://`
- **CHORD is research-only** (Ubisoft ML License) — never ship commercially

## Container Infrastructure

Container management scripts live in `infra/`. These operate pre-built images from the `gaap/` registry (image builds are in the `blender-container` repository).

```bash
./infra/setup-dirs.sh            # Create host directories (first-time)
./infra/download-models.sh       # Download AI models from HuggingFace (first-time)
./infra/compose-comfyui.sh       # Start/stop ComfyUI (GPU 0, port 8188)
./infra/compose-blender.sh       # Start/stop Blender + MCP (GPU 1, port 8000)
```

Images: `gaap/comfyui:latest`, `gaap/blender:latest`, `gaap/blender-mcp:latest`. Override tag with `GAAP_VERSION=v1.2.3`.

Container runtime is **Podman** — never use `docker` commands.

## Agent Configs

Specialized agent definitions in `.github/agents/`:

| Agent | Role |
|-------|------|
| `asset-orchestrator` | Generate → validate → remediate loop (≤5 attempts) |
| `game-asset-agent` | End-to-end pipeline execution (Stages 1–6) |
| `asset-validator` | Quality checks: geometry, UVs, materials, file size |
| `modify-game-asset` | Modify existing GLBs via Blender MCP |
