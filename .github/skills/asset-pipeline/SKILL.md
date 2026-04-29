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

**Critical parameters** (ExportGLB node):
```json
"decimation_target": 25000,
"texture_size": 1024,
"remesh": true,
"remesh_band": 2.0,
"remesh_project": 0.9
```

- `decimation_target` — Controls the vertex count of the output mesh. **Default: 25,000.** Trellis2 bakes textures ONTO this mesh, so UV fidelity is preserved at any target. Override per-asset by copying the workflow and editing the value. Do NOT try to achieve lower vertex counts via post-bake decimation in Stage 6 — that destroys UV fidelity.
- `texture_size` — Texture resolution. **Default: 1024.** Scale with vertex count: 1024 for ≤25K, 2048 for >50K.
- `remesh_project=0.9` — Projects remeshed vertices to original surface (Microsoft's default). **Must be ≥0.9** to avoid triangle-soup topology.
- `remesh_band=2.0` — Controls bandwidth of dual-contouring remesh. Higher = smoother.
- These parameters were exposed via a patch to `Trellis2ExportGLB` in the ComfyUI container.
- The node source: `/app/ComfyUI/custom_nodes/ComfyUI-TRELLIS2/nodes/nodes_unwrap.py`

**To override `decimation_target` per-asset:**
1. Copy workflow: `cp comfyui/flows/trellis2-img2mesh.json ~/assets/raw_3d/{asset}-workflow.json`
2. Edit the copy: change `"decimation_target"` to desired value
3. Use the modified workflow via the Python API (stage3-3d.sh uses the default)

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
| `TEXTURE_PADDING` | `16` | Pixel dilation for UV island gap filling. Increases to reduce seam bleed |

## Vertex Targets

Vertex count is controlled by Trellis2's `decimation_target` (Stage 3), NOT by Stage 6 decimation. Textures are baked onto the target mesh, so UV fidelity is preserved at any count.

| ASSET_TYPE | decimation_target | texture_size | Target Height | Auto-Rig |
|------------|-------------------|--------------|---------------|----------|
| `creature` | 25,000 | 1024 | 1.0m | Yes (creature) |
| `humanoid` | 15,000 | 1024 | 1.75m | Yes (21-bone biped) |
| `prop` | 25,000 | 1024 | 0.8m | No |
| `weapon` | 15,000 | 1024 | 1.0m | No |

**Stage 6 `TARGET_VERTS`** should match or exceed the `decimation_target` so Stage 6 does NOT decimate further. Set `TARGET_VERTS` equal to `decimation_target`.

**Never decimate below the Trellis2 output in Stage 6** — post-bake decimation destroys UV fidelity. See `docs/logbook-optimization-attempts.md` for details.

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

Always include: `game asset, flat lighting, no shadows, no ground shadow, no drop shadow, neutral grey background`

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

**Vertex count gate:** Also check the raw GLB vertex count. If it's >3× the `decimation_target`, the Trellis2 decimation failed and baked textures will have fragmented UV islands with garbage-colored pixels. Stage 6 now warns about this automatically.

## Texture Quality: UV Fragmentation

When Trellis2's `decimation_target` fails (mesh outputs at much higher vertex counts than requested), the UV layout becomes heavily fragmented — thousands of tiny UV islands with garbage-colored pixels (bright pink, white, metallic silver) between them. These bleed through at UV seam boundaries via bilinear texture filtering, causing visible "shiny brown" or "shiny silver" artifacts in Godot.

**Diagnosis:** Extract and view the texture PNG from the GLB. A healthy texture has large, coherent UV islands (like the 15K boar). A fragmented texture looks like confetti — tiny patches of correct color interspersed with garbage.

**Stage 6 mitigations (Step 4b + 4c):**
- Step 4b strips metallic/roughness textures and sets roughness=1.0, metallic=0, specular=0
- Step 4c applies texture padding: alpha-based gap detection + BFS dilation (16px default) + despeckle
- These help with UV seam bleed but **cannot fix fundamentally fragmented textures**

**When artifacts persist after Stage 6:**
1. **Regenerate at lower vertex count** — set `decimation_target` to 15,000 or even 10,000 in the Trellis2 workflow
2. **Check raw GLB vertex count** — if it's >>25K despite `decimation_target=25000`, Trellis2 hit a "decimation floor" for this mesh topology
3. **FORCE_PBR=1** replaces the Trellis2 texture with CHORD PBR maps, but this only works well with camera UV projection (not Smart UV)

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
stylized grey wolf, natural grey fur with dark grey back and light grey belly, amber eyes, Genshin Impact style, 3D rendered, volumetric, three-quarter front view, all four legs visible and separated, fluffy tail, bold clean cel-shaded forms, game asset, flat lighting, no shadows, no ground shadow, no drop shadow, neutral grey background
```

**Owl (creature, bird):**
```
stylized owl, Genshin Impact style, 3D rendered, volumetric, three-quarter front view, perched upright with wings folded against body, sharp talons gripping a branch, tawny brown feathers with warm amber chest, cream-white facial disc, bright golden-yellow eyes with black pupils, dark brown wingtips, small ear tufts, round head, bold clean cel-shaded forms, game asset, flat lighting, no shadows, no ground shadow, no drop shadow, neutral grey background
```

**Clay Pot (prop):**
```
stylized hand-painted clay pot, round terracotta vessel with wide belly and narrow neck, painted cobalt blue and white geometric patterns around the body, warm orange-brown clay base color, visible brush stroke texture, small decorative handles on each side, centered, single object, orthographic view, game asset, flat lighting, no shadows, no ground shadow, no drop shadow, neutral grey background
```

## Golden Path Quick Reference

| Asset Type | Verts | Size | Pipeline Time | Key Prompt Keywords |
|------------|-------|------|---------------|-------------------|
| Creature (quadruped) | 25K | ~3 MB | ~3.5 min | `three-quarter, four legs separated, color variation, cel-shaded` |
| Creature (bird) | 25K | ~3 MB | ~3.5 min | `three-quarter, wings folded, color variation in plumage` |
| Prop (textured) | 25K | ~3 MB | ~3.5 min | `centered, single object, orthographic, color variation` |
| Weapon | 15K | ~2 MB | ~3.5 min | `centered, single object, orthographic, flat lighting` |
| Humanoid | 15K | ~2 MB | ~3.5 min | `front view, 3D rendered, neutral A-pose, no cape` |

> Times assume warm containers. Flux: ~28s, BiRefNet: ~4s, Trellis2: ~170s, Stage 6: ~15s.
> Sizes reflect 1024px PNG textures with MR stripped. Low-poly-at-source = small files.

## Prompt Do's and Don'ts

- ✅ "3D rendered" or "volumetric" for characters (helps Trellis2 infer depth)
- ✅ Neutral A-pose/T-pose, clear limb separation, no cape for riggable humanoids
- ✅ Color variation in creature fur/skin (darker back, lighter belly, distinct markings)
- ✅ Subjects with natural depth (overlapping elements, perspective)
- ✅ "no shadows, no ground shadow, no drop shadow" — shadows bake into Trellis2 textures and render as dark patches on the 3D model
- ⚠️ "orthographic" alone on organic characters risks flat/bas-relief output
- ❌ Humanoids with merged arms, capes, or wall-like silhouettes
- ❌ Uniform white/grey creature concepts — groove artifacts visible
- ❌ Any shadow language in prompts — Trellis2 bakes shadows into geometry/textures

## Godot 4.6 Compatibility (CRITICAL)

These operations **break** Godot 4.6 rendering — never use them:
- ❌ `gltf-transform quantize` — produces blank renders
- ❌ `gltf-transform webp` — WebP textures in GLB not supported
- ❌ `gltf-transform simplify` — **destroys normals on Trellis2 meshes**, causing shiny faceted artifacts. All mesh decimation MUST be done in Blender.
- ❌ Draco compression, KTX2/Basis, EXT_meshopt_compression
- ❌ Post-bake decimation in Stage 6 below Trellis2's `decimation_target` — destroys UV fidelity
- ❌ JPEG texture compression in GLB — quality loss not worth the file size savings

**No post-processing optimization after Stage 6.** Stage 6 output (`_final.glb`) IS the shipping asset. MR stripping, doubleSided, and mesh cleanup are all handled inside Stage 6 before export.

## Trellis2 Topology — Low-Poly at Source

Trellis2's `decimation_target` controls vertex count BEFORE texture baking. This means textures are mapped to the target mesh directly — UV fidelity is preserved at any vertex count, even 15K.

**Key insight:** Do NOT decimate after Trellis2 bakes textures. Instead, set `decimation_target` in the workflow to your desired vertex count. The default (25K) produces ~3 MB assets with clean textures.

**`remesh_project=0.9`** (with `remesh_band=2.0`) produces manifold topology with shared vertices. Tested results:
- Near-duplicate vertex pairs: **637K → 244K** (62% reduction)
- Boundary edges: **402K → 230K** (43% reduction)
- Vertex/face ratio: **1.04 (soup) → 0.78 (shared)**
- **No visible polygon gaps** at any decimation level
- **No texture bleed** — textures baked onto final mesh

### Legacy Triangle Soup Limitations (remesh_project=0)

These issues are **resolved** by `remesh_project=0.9` but documented for reference:

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

| Asset | Type | Verts | Size | GLB Path |
|-------|------|-------|------|----------|
| Wild Boar (15K) | creature | 12K | 2.7MB | `res://actors/wild_boar_15k/wild_boar_15k_final.glb` |
| Wild Boar (150K) | creature | 150K | 24MB | `res://actors/wild_boar/wild_boar_source_final.glb` |

## Agent Configs

Specialized agent definitions in `.github/agents/`:

| Agent | Role |
|-------|------|
| `asset-orchestrator` | Generate → validate → remediate loop (≤5 attempts) |
| `game-asset-agent` | End-to-end pipeline execution (Stages 1–6) |
| `asset-validator` | Quality checks: geometry, UVs, materials, file size, web-readiness |
| `modify-game-asset` | Modify existing GLBs via Blender MCP |
