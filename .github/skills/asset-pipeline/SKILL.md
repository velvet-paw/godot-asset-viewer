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

### Stage 3 — Trellis2 Workflow Parameters

Workflow file: `comfyui/flows/trellis2-img2mesh.json`

**Critical remesh parameters** (ExportGLB node):
```json
"remesh": true,
"remesh_band": 2.0,
"remesh_project": 0.9
```

- `remesh_project=0.9` — Projects remeshed vertices to original surface (Microsoft's default). **Must be ≥0.9** to avoid triangle-soup topology.
- `remesh_band=2.0` — Controls bandwidth of dual-contouring remesh. Higher = smoother.
- These parameters were exposed via a patch to `Trellis2ExportGLB` in the ComfyUI container.
- The node source: `/app/ComfyUI/custom_nodes/ComfyUI-TRELLIS2/nodes/nodes_unwrap.py`

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
| `SKIP_MR_STRIP` | `0` | Set `1` to keep metallic/roughness texture (NOT recommended for Godot) |

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

| Asset Type | Source Verts | Desktop (30K) | Web (15K) | Pipeline Time | Key Prompt Keywords |
|------------|-------------|---------------|-----------|---------------|-------------------|
| Creature (quadruped) | 150K | ~5 MB | ~2 MB | ~50s×3 | `three-quarter, four legs separated, color variation, cel-shaded` |
| Creature (bird) | 150K | ~5 MB | ~2 MB | ~50s×3 | `three-quarter, wings folded, color variation in plumage` |
| Prop (textured) | 100K | ~4 MB | ~1.5 MB | ~50s×3 | `centered, single object, orthographic, color variation` |
| Weapon | 50K | ~3 MB | ~1 MB | ~50s×3 | `centered, single object, orthographic, flat lighting` |
| Humanoid | 15K | ~3 MB | ~1.5 MB | ~50s×3 | `front view, 3D rendered, neutral A-pose, no cape` |

> Times assume warm containers + 3 tiers. Flux: ~28s, BiRefNet: ~4s, Trellis2: ~170s, Stage 6: ~15s×3.
> File sizes with JPEG textures + MR strip + doubleSided. Mesh geometry dominates due to per-triangle UVs.

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

### Three-Tier Generation (Recommended)

Generate source, desktop, and web variants from the same Trellis2 output:

```bash
./pipeline/generate-asset-tiers.sh <input_glb> <asset_name> [asset_type]
```

| Tier | Verts | Textures | Rigging | Target Size | Use Case |
|------|-------|----------|---------|-------------|----------|
| `source` | 150K | Original PNG | Yes | Unlimited | Archival, highest quality |
| `desktop` | 30K | 1024px JPEG q85 | Yes | <5 MB | Desktop games |
| `web` | 15K | 512px JPEG q80 | No | <2 MB | Browser games, mobile |

Override defaults with env vars: `SOURCE_VERTS`, `DESKTOP_VERTS`, `WEB_VERTS`.

### Single-Tier Optimization

For manual control, use optimize-for-web.sh directly:

```bash
# Desktop quality
QUALITY=desktop ./pipeline/optimize-for-web.sh ~/assets/final_glb/{asset}_final.glb ~/assets/final_glb/{asset}_desktop.glb

# Web quality
QUALITY=web ./pipeline/optimize-for-web.sh ~/assets/final_glb/{asset}_final.glb ~/assets/final_glb/{asset}_web.glb
```

| Variable | Default | Description |
|----------|---------|-------------|
| `QUALITY` | `web` | **REQUIRED.** `web` (512px JPEG q80), `desktop` (1024px JPEG q85), `source` (no-op) |
| `TEXTURE_SIZE` | (per preset) | Override texture resize dimension |
| `JPEG_QUALITY` | (per preset) | JPEG compression quality 1-100 (0=skip, keep PNG) |
| `STRIP_METALROUGH` | `1` | Set to `0` to keep metallicRoughness texture (only for undecimated meshes) |

### Quality Presets

| Preset | Textures | Format | Mesh | Target Size | Use Case |
|--------|----------|--------|------|-------------|----------|
| `web` (default) | 512×512 | JPEG q80 | As-is | <2 MB | Browser games, mobile |
| `desktop` | 1024×1024 | JPEG q85 | As-is | <5 MB | Desktop games |
| `source` | Original | PNG | None | No limit | Archival, highest quality |

MetallicRoughness is **prevented at source** in Stage 6 Step 4b — Blender strips the MR texture from the Principled BSDF before export (metallic=0.0, roughness=0.8). This means exported GLBs never contain MR textures, eliminating shiny brown artifacts in Godot's Forward+ renderer. The `STRIP_METALROUGH` option in optimize-for-web.sh is now redundant for Trellis2 meshes but kept as a safety net for non-pipeline GLBs.

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

### Trellis2 Triangle Soup — Root Cause & Fix

Trellis2's CuMesh remesher outputs **triangle soup** by default because the `Trellis2ExportGLB` node
hardcoded `remesh_project=0` (no surface projection) and `remesh_band=1` (minimum bandwidth).

**Golden Path (both layers):**

1. **Source fix — CuMesh remesh parameters** (workflow JSON):
   ```json
   "remesh_band": 2.0,
   "remesh_project": 0.9
   ```
   Setting `remesh_project=0.9` (Microsoft's recommended default) projects remeshed vertices back to
   the original surface, creating shared vertices with proper topology. Tested results:
   - Near-duplicate vertex pairs: **637K → 244K** (62% reduction)
   - Boundary edges: **402K → 230K** (43% reduction)
   - Vertex/face ratio: **1.04 (soup) → 0.78 (shared)**
   - **No visible polygon gaps** after decimation to 30K verts
   - **No texture bleed** — decimation preserves UV fidelity on manifold topology

2. **Defense-in-depth — `doubleSided=true`** (optimize-for-web.sh):
   Applied automatically during texture optimization. Renders back faces to fill any
   remaining micro-gaps at extreme zoom. Zero file-size cost.

**Always use both layers.** The remesh fix produces dramatically better meshes, and
doubleSided catches edge cases at extreme zoom levels.

### Legacy Triangle Soup Limitations (remesh_project=0)

These issues are **resolved** by the golden path above but documented for reference:

1. **Polygon gaps after decimation** — Each triangle had its own 3 unique vertices.
   After decimation to <60K verts, gaps became visible when zooming in.

2. **Merge-by-distance limitations** — Pre-merge at 0.002+ caused collapse decimation
   to produce 3× more faces. Post-merge at 0.003+ destroyed geometry.

3. **File size inflation** — Merged vertices with different normals/UVs got duplicated
   in glTF export, making files larger despite fewer Blender vertices.

4. **Texture bleed after decimation** — With per-triangle UV islands, collapse decimation
   averaged UV coordinates across island boundaries, sampling wrong texels. Light-colored
   pixels from unrelated UV islands bled through dark areas (visible on belly/legs).
   **Fix:** Regenerate with `remesh_project=0.9` — the improved topology produces coherent
   decimation that preserves UV fidelity. No post-hoc re-bake needed.

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
