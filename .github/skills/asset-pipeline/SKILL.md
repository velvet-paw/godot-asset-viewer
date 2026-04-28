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
| `ASSET_TYPE` | `creature` | **REQUIRED.** Controls vertex target, scale, rigging |
| `TARGET_VERTS` | (per type) | **REQUIRED.** Always pass explicitly — see vertex targets table below |
| `TARGET_HEIGHT` | (per type) | Override height in meters |
| `GENERATE_LODS` | `0` | **Always set `1`** to produce LOD1 + LOD2 |
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

## Early Quality Gates

Run cheap checks after Stage 3 (before full Stage 6) to catch obvious failures:

```bash
python3 -c "
import trimesh, os
path = os.path.expanduser('~/assets/raw_3d/{asset_name}_NNNNN_.glb')
scene = trimesh.load(path)
mesh = scene.to_geometry()
z_range = mesh.bounds[1][2] - mesh.bounds[0][2]
verts = len(mesh.vertices)
if z_range < 0.05:
    print('EARLY_FAIL: bas_relief')
elif verts < 100:
    print('EARLY_FAIL: degenerate_mesh')
else:
    print('EARLY_PASS: proceed to Stage 6')
"
```

If `EARLY_FAIL`, skip Stage 6 and go directly to remediation (saves GPU time).

For **humanoids**, add a solid-render gate: import raw GLB into Blender in `BLENDER_WORKBENCH` `color_type='SINGLE'` and reject if the silhouette looks like a slab/curtain/fused limbs. Treat as upstream failure, not Stage 6 failure.

## Prompt Refinement Strategies

When `regenerate_concept` is needed, choose a DIFFERENT variation each attempt:

### Humanoid Strategies

| Attempt | Strategy | Added Keywords |
|---------|----------|---------------|
| 2 | Neutral riggable pose | `"3D rendered, character model sheet, neutral A-pose, arms away from torso, legs separated, no cape"` |
| 3 | Clay turnaround | `"3D character model, turnaround sheet, neutral pose, clay render style, no cloak"` |
| 4 | Front + depth cues | `"front view, volumetric, sculpted armor, separated limbs, strong body volume"` |
| 5 | Maximum readability | `"game-ready humanoid, full body, clean silhouette, animation-ready, no occluding cloth, bold forms"` |

### Creature/Quadruped Strategies

| Attempt | Strategy | Added Keywords |
|---------|----------|---------------|
| 2 | Color variation emphasis | `"natural coloring with darker back and lighter belly, distinct markings, cel-shaded, Genshin Impact style"` |
| 3 | Simpler forms | `"bold clean forms, smooth fur, strong silhouette, all four legs clearly separated"` |
| 4 | Different angle | `"side profile view, stylized proportions, game character, visible color gradients across body"` |
| 5 | Maximum readability | `"game-ready creature model, clean silhouette, bright color palette, bold markings, 3D render"` |

**Critical:** Never use the exact same prompt twice. Always vary style/viewpoint keywords.
**Critical for creatures:** Every prompt MUST request color variation.

## Proven Reference Prompts

First-attempt successes — use as starting templates:

**Wolf (creature, quadruped):**
```
stylized grey wolf, natural grey fur with dark grey back and light grey belly, amber eyes, Genshin Impact style, 3D rendered, volumetric, three-quarter front view, all four legs visible and separated, fluffy tail, bold clean cel-shaded forms, game asset, flat lighting, no shadows, neutral grey background
```

**Owl (creature, bird):**
```
stylized owl, Genshin Impact style, 3D rendered, volumetric, three-quarter front view, perched upright with wings folded against body, sharp talons gripping a branch, tawny brown feathers with warm amber chest, cream-white facial disc, bright golden-yellow eyes with black pupils, dark brown wingtips, small ear tufts, round head, bold clean cel-shaded forms, game asset, flat lighting, no shadows, neutral grey background
```

**Clay Pot (prop):**
```
stylized hand-painted clay pot, round terracotta vessel with wide belly and narrow neck, painted cobalt blue and white geometric patterns around the body, warm orange-brown clay base color, visible brush stroke texture, small decorative handles on each side, centered, single object, orthographic view, game asset, flat lighting, no shadows, neutral grey background
```

## Golden Path Quick Reference

| Asset Type | Vertex Target | File Size | Pipeline Time | Key Prompt Keywords |
|------------|--------------|-----------|---------------|-------------------|
| Creature (quadruped) | 150K | 20–25MB | ~4 min | `three-quarter, four legs separated, color variation, cel-shaded` |
| Creature (bird) | 150K | 20–25MB | ~4 min | `three-quarter, wings folded, color variation in plumage` |
| Prop (textured) | 100K | 12–16MB | ~4 min | `centered, single object, orthographic, color variation` |
| Weapon | 50K | 8–12MB | ~4 min | `centered, single object, orthographic, flat lighting` |
| Humanoid | 15K | 8–12MB | ~4 min | `front view, 3D rendered, neutral A-pose, no cape` |

> Times assume warm containers. Flux: ~28s, BiRefNet: ~4s, Trellis2: ~170s, Stage 6: ~10s.

## Prompt Do's and Don'ts

- ✅ "3D rendered" or "volumetric" for characters (helps Trellis2 infer depth)
- ✅ Neutral A-pose/T-pose, clear limb separation, no cape for riggable humanoids
- ✅ Color variation in creature fur/skin (darker back, lighter belly, distinct markings)
- ✅ Subjects with natural depth (overlapping elements, perspective)
- ⚠️ "orthographic" alone on organic characters risks flat/bas-relief output
- ❌ Humanoids with merged arms, capes, or wall-like silhouettes
- ❌ Uniform white/grey creature concepts — groove artifacts visible

## Stage 7 — Web Optimization (Default)

After Stage 6, **always** run web optimization unless the user explicitly requests `source` quality.

**Input must be a Blender collapse-decimated GLB** (e.g., `_final.glb` from Stage 6). Do NOT use raw Trellis2 output.

```bash
# Default: web quality (<2 MB target)
QUALITY=web ./pipeline/optimize-for-web.sh ~/assets/final_glb/{asset}_final.glb ~/assets/final_glb/{asset}_web.glb

# Desktop quality (<5 MB target)
QUALITY=desktop ./pipeline/optimize-for-web.sh ~/assets/final_glb/{asset}_final.glb ~/assets/final_glb/{asset}_desktop.glb
```

| Variable | Default | Description |
|----------|---------|-------------|
| `QUALITY` | `web` | **REQUIRED.** `web` (512px textures), `desktop` (1024px textures), `source` (no-op) |
| `TEXTURE_SIZE` | (per preset) | Override texture resize dimension |
| `STRIP_METALROUGH` | `1` | Set to `0` to keep metallicRoughness texture (only for undecimated meshes) |

### Quality Presets

| Preset | Textures | Mesh | Target Size | Use Case |
|--------|----------|------|-------------|----------|
| `web` (default) | 512×512 PNG | As-is (decimated by Blender) | <2 MB | Browser games, mobile |
| `desktop` | 1024×1024 PNG | As-is (decimated by Blender) | <5 MB | Desktop games |
| `source` | Original | None | No limit | Archival, highest quality |

MetallicRoughness is **stripped by default** (metallic=0, roughness=0.9). Even with Blender collapse decimation, the MR texture on decimated meshes causes shiny brown artifacts in Godot. Set `STRIP_METALROUGH=0` only for undecimated full-res meshes.

All materials are set to **doubleSided=true** automatically. Trellis2 outputs triangle-soup meshes where triangles share no vertices — after decimation, visible gaps appear between triangles. doubleSided renders back faces, filling these gaps at zero file-size cost.

### Godot 4.6 Compatibility (CRITICAL)

These operations **break** Godot 4.6 rendering — never use them:
- ❌ `gltf-transform quantize` — produces blank renders
- ❌ `gltf-transform webp` — WebP textures in GLB not supported
- ❌ `gltf-transform simplify` — **destroys normals on Trellis2 meshes**, causing shiny faceted artifacts. All mesh decimation MUST be done in Blender.
- ❌ Draco compression, KTX2/Basis, EXT_meshopt_compression

These operations are **safe** and used by optimize-for-web.sh:
- ✅ `gltf-transform resize` — PNG texture resizing
- ✅ `gltf-transform dedup` / `prune` — cleanup
- ✅ `doubleSided=true` — fills polygon gaps from decimated triangle soup (set via strip-metalrough.mjs or set-doublesided.mjs)

### Input Selection

**Input must be Stage 6 output** (already decimated by Blender collapse decimation). The optimize-for-web.sh script only resizes textures and cleans up — it does NOT simplify meshes. Mesh decimation is Blender's job (Stage 6) because gltf-transform simplify destroys vertex normals and UV quality on Trellis2 triangle-soup meshes.

### Trellis2 Triangle Soup — Known Limitations

Trellis2 outputs **triangle soup**: each triangle has its own 3 unique vertices, not shared with neighbors. This causes:

1. **Polygon gaps after decimation** — Tiny sub-pixel gaps exist between all triangles. After decimation to <60K verts, triangles become larger and gaps become visible when zooming in. **Mitigation:** `doubleSided=true` (applied automatically by optimize-for-web.sh) renders back faces to visually fill gaps.

2. **Merge-by-distance limitations** — Pre-merge at 0.0005 catches exact duplicates but doesn't fix topology. Higher thresholds (0.002+) weld the mesh but cause collapse decimation to produce 3× more faces than triangle soup (shared verts prevent face collapse). Post-merge (after decimation) at 0.003+ destroys geometry.

3. **File size inflation from merging** — Merged vertices with shared positions but different normals/UVs get duplicated in glTF export, making files larger than triangle soup equivalents despite fewer Blender vertices.

## Reference Assets

| Asset | Type | Verts | Size | GLB Path | Screenshot |
|-------|------|-------|------|----------|------------|
| Grey Wolf | creature | 150K | 24MB | `res://actors/wolf/wolf_final.glb` | `~/assets/final_glb/wolf_screenshot.png` |
| Barn Owl | creature | 150K | 23MB | `res://actors/barn_owl/barn_owl_final.glb` | `~/assets/final_glb/barn_owl_screenshot.png` |
| Clay Pot | prop | 100K | 15MB | `res://actors/clay_pot/clay_pot_final.glb` | `~/assets/final_glb/clay_pot_screenshot.png` |

## Agent Configs

Specialized agent definitions in `.github/agents/`:

| Agent | Role |
|-------|------|
| `asset-orchestrator` | Generate → validate → remediate loop (≤5 attempts) |
| `game-asset-agent` | End-to-end pipeline execution (Stages 1–7) |
| `asset-validator` | Quality checks: geometry, UVs, materials, file size, web-readiness |
| `modify-game-asset` | Modify existing GLBs via Blender MCP |
