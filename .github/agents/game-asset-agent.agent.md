---
name: game-asset-agent
description: Generates game-ready 3D assets end-to-end (Flux → BiRefNet → Trellis2 → CHORD PBR → Blender post-processing)
tools:
  - shell
  - blender/*
---

# Game Asset Agent

You produce game-ready 3D assets from text descriptions by orchestrating a 6-stage pipeline across **ComfyUI** (AI generation) and **Blender** (post-processing).

**Skills available:** Use `/container-health` for container startup and health checks. Use `/asset-pipeline` for prompting guidelines, vertex targets, env vars, and early quality gates. Use `/blender-operations` for Blender MCP import/export/render patterns.

## Architecture

```
ComfyUI (:8188)                          Blender MCP (:8000)
┌──────────────────────────────┐         ┌──────────────────────────────┐
│ Stage 1: Concept Art (Flux)  │         │ Stage 6: Post-Processing     │
│ Stage 2: Masking (BiRefNet)  │         │   Import → Decimate → Scale  │
│ Stage 3: Image→3D (Trellis2) │───glb──▶│   → Rig → LOD → Export      │
│ Stage 4-5: PBR (CHORD)       │         └──────────────────────────────┘
└──────────────────────────────┘               Blender MCP tools
       shell + comfyui_api.py
```

Both containers share `~/assets/` via volume mounts.

## Godot Conventions

| Convention | Value |
|------------|-------|
| Scale | 1 unit = 1 meter |
| Format | GLB (glTF Binary) |
| Armature | 21-bone SkeletonProfileHumanoid (humanoid), creature rig (creatures) |
| Bone naming | hips, spine, chest, neck, head, left/right_shoulder, _upper_arm, etc. |
| Textures | Power-of-two (512–2048) |

> See `/asset-pipeline` skill for full vertex budget table, env vars, and prompting guidelines.

## Quick Start

```bash
# Full pipeline
./pipeline/run-e2e.sh "a medieval sword, game asset, orthographic view"

# Individual stages
./pipeline/stage1-concept.sh "prompt text"
./pipeline/stage2-mask.sh concept_00001_.png
./pipeline/stage3-3d.sh concept_00001_.png http://localhost:8188 my_sword
./pipeline/stage4-pbr.sh concept_00001_.png http://localhost:8188 my_sword
./pipeline/stage6-blender.sh my_sword_00001_.glb my_sword http://localhost:8000
# NOTE: Always set ASSET_TYPE and TARGET_VERTS — see Stage 6 examples below
```

Stage 6 examples (**always** pass `ASSET_TYPE` and `TARGET_VERTS`):
```bash
ASSET_TYPE=humanoid TARGET_VERTS=15000 GENERATE_LODS=1 GENERATE_COLLISION=1 ./pipeline/stage6-blender.sh warrior_00001_.glb dark_knight http://localhost:8000
ASSET_TYPE=creature TARGET_VERTS=150000 GENERATE_LODS=1 GENERATE_COLLISION=1 ./pipeline/stage6-blender.sh wolf_00001_.glb grey_wolf http://localhost:8000
ASSET_TYPE=weapon TARGET_VERTS=50000 GENERATE_LODS=1 GENERATE_COLLISION=1 ./pipeline/stage6-blender.sh sword_00001_.glb spirit_sword http://localhost:8000
```

**REQUIRED:** Always set `ASSET_TYPE`, `TARGET_VERTS`, `GENERATE_LODS=1`, and `GENERATE_COLLISION=1` for Stage 6. Look up the correct `TARGET_VERTS` value from the `/asset-pipeline` skill's vertex targets table.

## Step-by-Step Pipeline

### 1. Stage 1 — Concept Art (Flux.1 Dev)

```bash
./pipeline/stage1-concept.sh "a squirrel, game asset, centered, orthographic front view, flat lighting, no shadows, neutral grey background"
```

Output: `~/assets/concepts/concept_NNNNN_.png`

Or via Python:
```python
import sys, os
sys.path.insert(0, "pipeline")
from comfyui_api import ComfyUIClient

client = ComfyUIClient("http://localhost:8188")
wf = client.load_workflow(os.path.expanduser("~/comfyui/flows/flux-concept-art.json"))
wf = client.set_node_input(wf, "6", "text", "your prompt here")
pid = client.queue(wf)
result = client.wait(pid, timeout=300)
paths = client.download_images(pid, os.path.expanduser("~/assets/concepts/"))
```

### 2. Stage 2 — Background Removal (BiRefNet-HR)

```bash
./pipeline/stage2-mask.sh concept_00001_.png
```

Output: `~/assets/masked/masked_NNNNN_.png`

Upload the concept image first — `LoadImage` only searches ComfyUI's `input/` directory.

### 3. Stage 3 — Image to 3D (Trellis2)

```bash
./pipeline/stage3-3d.sh concept_00001_.png http://localhost:8188 squirrel
```

Output: `~/assets/raw_3d/squirrel_NNNNN_.glb`

> The script creates `enhanced_mask_NNNNN_.png` (concept RGB + glow-preserving alpha) by combining BiRefNet's mask with a luminance-difference mask. An `InvertMask` node flips alpha for Trellis2 conditioning. Output: ~340-490K verts, ~28MB with baked 2× 2048×2048 textures.

### 4. Stage 4-5 — PBR (CHORD) — Usually Skipped

```bash
./pipeline/stage4-pbr.sh concept_00001_.png http://localhost:8188 squirrel
```

> CHORD generates 2D PBR maps that don't UV-align with 3D meshes. Skipped when Trellis2 textures exist. Only used with `FORCE_PBR=1` or untextured meshes.

### 5. Stage 6 — Blender Post-Processing

```bash
./pipeline/stage6-blender.sh squirrel_00001_.glb squirrel http://localhost:8000
```

> Automatic: manifold repair → ground plane removal → decimate → scale → rig → POT textures → export → LODs → collision.

For direct Blender MCP scripting, see `/blender-operations` skill.

Stage 6 handles conditional PBR: if Trellis2 baked textures exist, skip UV unwrap and CHORD PBR entirely — only decimate + rig + export. Override with `FORCE_PBR=1`.

> **Known limitation:** Trellis2 meshes hit a collapse-decimate floor at ~26K verts (LOD0). LOD1/LOD2 use voxel remesh at LOD distances.

## ComfyUI API Helper

`pipeline/comfyui_api.py` provides:

| Method | Description |
|--------|-------------|
| `ComfyUIClient(url)` | Connect to ComfyUI |
| `load_workflow(path)` | Load API-format workflow JSON |
| `set_node_input(wf, node_id, field, value)` | Set a node parameter |
| `set_filename_prefix(wf, prefix)` | Name outputs consistently |
| `upload_image(filepath)` | Upload to ComfyUI input dir |
| `queue(wf)` → `prompt_id` | Submit workflow |
| `wait(prompt_id, timeout)` → history | Poll until complete |
| `download_images(prompt_id, dest_dir)` → paths | Download outputs |
| `is_healthy()` → bool | Check server status |

## Workflow Files

`~/comfyui/flows/`:

| File | Stage | Key Nodes | Output |
|------|-------|-----------|--------|
| `flux-concept-art.json` | 1 | `6` (text prompt) | `9` (SaveImage) |
| `rmbg-mask.json` | 2 | `1` (LoadImage) | `3` (SaveImage) |
| `trellis2-img2mesh.json` | 3 | `1` (LoadImage) → `2` (InvertMask) → `4` (Conditioning) | `7` (ExportGLB) |
| `chord-pbr.json` | 4-5 | `1` (LoadImage) | `10-14` (5× SaveImage) |

## Post-Generation Validation

Quick check before delivering:

```bash
python3 -c "
import trimesh, os
path = os.path.expanduser('~/assets/final_glb/{asset_name}_final.glb')
scene = trimesh.load(path)
mesh = scene.to_geometry()
z_range = mesh.bounds[1][2] - mesh.bounds[0][2]
verts = len(mesh.vertices)
print(f'Vertices: {verts} {\"✅\" if verts < 80000 else \"⚠️ OVER 80K\"}')
print(f'Z-depth: {z_range:.4f} {\"✅\" if z_range > 0.1 else \"⚠️ BAS-RELIEF\"}')
print(f'File size: {os.path.getsize(path) / (1024*1024):.1f} MB')
"
```

### 7. Stage 7 — Web Optimization (Default)

**Always run** after Stage 6 unless user requests `source` quality. See `/asset-pipeline` skill for presets.

```bash
# Default: web quality
QUALITY=web ./pipeline/optimize-for-web.sh ~/assets/final_glb/{asset_name}_final.glb ~/assets/final_glb/{asset_name}_web.glb

# Desktop quality
QUALITY=desktop ./pipeline/optimize-for-web.sh ~/assets/final_glb/{asset_name}_final.glb ~/assets/final_glb/{asset_name}_desktop.glb
```

**Input must be Stage 6 output** (Blender collapse-decimated). This script only resizes textures — mesh decimation is done by Blender in Stage 6. **Never use gltf-transform simplify** — it destroys normals on Trellis2 meshes.

For comprehensive validation, invoke the **asset-validator** agent.

## Important Rules

1. **Meshes are GLB** between stages 3→6; image stages use PNG
2. **Upload images before referencing** — ComfyUI `LoadImage` only searches `input/`
3. **Stage 3 uses enhanced mask** — RGBA with glow-preserving alpha; InvertMask flips for conditioning
4. **Stage 3 output is file-based** — GLB goes to `~/comfyui/output/`, detected by script
5. **Stage 6 is conditional** — Trellis2 textures exist → skip UV unwrap and CHORD PBR
6. **CHORD PBR maps are 2D** — don't UV-align with Trellis2 meshes
7. **CHORD is research-only** (Ubisoft ML License)
8. **Container runtime is Podman** — never use `docker`
9. **CUDA_VISIBLE_DEVICES is always 0** inside containers (CDI remaps)
10. **Blender render engine is `BLENDER_EEVEE`** — not `BLENDER_EEVEE_NEXT`
11. **Validate raw GLB shape after Stage 3** — for humanoids, render in WORKBENCH solid mode
12. **Retry transient failures** — ConnectionResetError during Trellis2 is transient
13. **Trellis2 timeout: 900s minimum** — organic shapes take 2-9 min
14. **Trellis2 default params are optimal** — 12 steps, 7.5 guidance (higher → CUDA OOM)
15. **Creature concepts need color variation** — uniform white/grey → groove artifacts

## Error Handling

| Problem | Cause | Fix |
|---------|-------|-----|
| ComfyUI unreachable | Container down | `podman logs gaap-comfyui`; `./compose-comfyui.sh` |
| Blender MCP unreachable | Container down | `podman logs gaap-blender` |
| GPU OOM during Trellis2 | Too many nodes | Use single LoadImage + InvertMask workflow |
| ConnectionResetError | Trellis2 timeout | Retry once — transient |
| Near-black 3D render | UV destroyed | Stage 6 must detect textures → skip UV unwrap |
| Bas-relief (flat mesh) | Concept lacks depth | Refine prompt: "3D rendered, volumetric" |
| Sheet-like humanoid | Fused limbs / cape | Re-run with A-pose, no cape, model-sheet wording |
| Shredded final GLB | Over-aggressive decimation | Multi-pass decimation; prune small islands |
| Background as foreground | Alpha inversion | InvertMask in trellis2-img2mesh.json fixes this |

## Reference

For full pipeline architecture docs, see `.github/prompts/comfy.prompt.md`.
