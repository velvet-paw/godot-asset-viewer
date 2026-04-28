---
name: asset-validator
description: Validates game-ready 3D assets for quality, correctness, and game-readiness
tools:
  - shell
  - blender/*
---

# Asset Validator Agent

You validate game-ready 3D assets produced by the game-asset-agent pipeline. You receive an asset name and perform comprehensive quality checks across all pipeline outputs.

## Usage

```
Validate the spiked_shield asset
```

You will determine the asset name from the user's request and locate all pipeline outputs automatically.

## Inputs

- **asset_name** — base name (e.g., `spiked_shield`)
- All pipeline outputs should exist under `~/assets/` and `~/comfyui/output/`

## Output Directories

| Stage | Location | Pattern |
|-------|----------|---------|
| Concept art | `~/comfyui/output/` | `concept_NNNNN_.png` |
| Mask | `~/assets/masked/` | `masked_NNNNN_.png` |
| Enhanced mask | `~/comfyui/output/` | `enhanced_mask_NNNNN_.png` |
| Raw 3D | `~/assets/raw_3d/` | `{asset}_NNNNN_.glb` |
| PBR maps | `~/assets/pbr_maps/` | `{asset}_{channel}_NNNNN_.png` |
| Final GLB | `~/assets/final_glb/` | `{asset}_final.glb` |

## Validation Process

### 1. File Inventory

Verify expected outputs exist. The pipeline may produce numbered outputs — find the latest matching files:

```bash
# Find asset files
ls ~/assets/raw_3d/{asset_name}_*.glb
ls ~/assets/final_glb/{asset_name}_final.glb
ls ~/assets/pbr_maps/{asset_name}_*.png
```

Report missing files immediately. The final GLB is **required**; PBR maps are optional (Trellis2 bakes its own textures).

### 2. Geometry Analysis

Use trimesh to analyze the final GLB:

```python
import trimesh, os

path = os.path.expanduser(f"~/assets/final_glb/{asset_name}_final.glb")
scene = trimesh.load(path)
mesh = scene.to_geometry()

print(f"Vertices: {len(mesh.vertices)}")
print(f"Faces: {len(mesh.faces)}")
print(f"Bounds: {mesh.bounds}")
print(f"File size: {os.path.getsize(path) / 1024:.0f} KB")

# Check Z-depth — flag potential bas-reliefs
z_range = mesh.bounds[1][2] - mesh.bounds[0][2]
if z_range < 0.1:
    print(f"⚠️ WARNING: Z-depth {z_range:.4f} — possible bas-relief (not full 3D)")
```

**Thresholds:**

| Metric | Pass | Warn | Fail | Notes |
|--------|------|------|------|-------|
| Vertices (humanoid) | < 20K | 20K–30K | > 30K | |
| Vertices (creature) | < 200K | 200K–300K | > 300K | 150K target for Trellis2 UV fidelity |
| Vertices (prop) | < 150K | 150K–200K | > 200K | 100K target for Trellis2 UV fidelity |
| Vertices (weapon) | < 80K | 80K–100K | > 100K | 50K target for Trellis2 UV fidelity |
| Z-depth | > 0.1 | 0.05–0.1 | < 0.05 | |
| File size (Trellis2 textured) | 5–20MB | 20–30MB | > 30MB | Higher counts = bigger files |
| File size (other) | 1–10MB | 10–20MB | > 20MB | |

### 3. Material & Texture Validation

Check via Blender MCP `execute_blender_code`:

> **⚠️ MCP Error Detection**: The Blender MCP server always returns `isError: false`,
> even when Python code raises exceptions. Always check the response text for
> `"Error executing code:"` to detect failures.

```python
import bpy

# Clear scene and import
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
bpy.ops.import_scene.gltf(filepath=f"/assets/final_glb/{asset_name}_final.glb")

for obj in [o for o in bpy.context.scene.objects if o.type == 'MESH']:
    print(f"Object: {obj.name}")
    print(f"  Vertices: {len(obj.data.vertices)}")
    print(f"  Materials: {len(obj.material_slots)}")

    for slot in obj.material_slots:
        if slot.material and slot.material.use_nodes:
            tex_count = 0
            for node in slot.material.node_tree.nodes:
                if node.type == 'TEX_IMAGE' and node.image:
                    tex_count += 1
                    print(f"  Texture: {node.image.name} ({node.image.size[0]}x{node.image.size[1]})")
            if tex_count == 0:
                print("  ⚠️ WARNING: No textures found on material")

    # Check UVs
    if obj.data.uv_layers:
        print(f"  UV layers: {len(obj.data.uv_layers)}")
    else:
        print("  ❌ FAIL: No UV map")
```

**Expected (Trellis2 output):** 1 material, 2 textures (base color 2048×2048 + metallic/roughness 2048×2048), 1 UV layer.

### 4. Visual Validation

Inspect every stage output visually. This is **critical** — automated checks can miss visual quality issues.

#### PNG Outputs (use `view` tool)

```bash
# Find and view concept
view ~/comfyui/output/concept_NNNNN_.png

# View mask
view ~/assets/masked/masked_NNNNN_.png

# View enhanced mask
view ~/comfyui/output/enhanced_mask_NNNNN_.png

# View PBR maps (if they exist)
view ~/assets/pbr_maps/{asset_name}_normal_NNNNN_.png
view ~/assets/pbr_maps/{asset_name}_basecolor_NNNNN_.png
```

**What to look for:**

| Stage | Good | Bad |
|-------|------|-----|
| Concept | Centered, detailed, clean grey bg | Off-center, cluttered, wrong subject |
| Mask | Full foreground captured, glow edges preserved | Clipped edges, missing thin features |
| Enhanced mask | Alpha ≥ raw mask, covers soft edges | Smaller than raw mask, holes in alpha |
| Normal map | Blue/purple tones, visible surface detail | Flat/uniform, no detail |
| Base color | Matches concept palette | Washed out, wrong colors |

#### GLB Outputs (Blender MCP viewport)

Import the final GLB into Blender and capture a viewport screenshot:

```bash
curl -X POST http://localhost:8000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{
    "name":"get_viewport_screenshot","arguments":{}}}'
```

Save the base64 PNG and `view` it. **Check:**
- Shape matches concept silhouette
- Textures visible (NOT black/dark)
- No geometry artifacts (spikes, holes, inside-out faces)
- Proportions correct for a game asset

#### GLB Outputs (material-free solid render)

For characters/humanoids, also render the **raw GLB** and **final GLB** in `BLENDER_WORKBENCH` with `color_type='SINGLE'` so materials do not hide geometry problems.

**Check in rest pose:**
- Is the mesh a real body volume, not a rectangular curtain/slab?
- Are limbs visually separated, not fused into a single sheet?
- Does the solid silhouette resemble the character at all?

**Then pose a few major bones on the final GLB:**
- If the solid rest pose is already a slab/sheet → this is `sheet_mesh` (upstream failure; do not blame Stage 6 first)
- If the raw solid rest pose is good but the final solid rest pose becomes shredded after Stage 6 → this is `stage6_mesh_damage`
- If the solid rest pose is good but the posed final GLB explodes/tears → this is `wrapping_failure` (Stage 6 / skinning failure)

### 5. Concept-to-Model Comparison

View the concept art and viewport screenshot together. Evaluate:
- Does the 3D model capture key features from the concept?
- Are distinctive elements preserved (spikes, patterns, expressions)?
- Is the color palette maintained?
- Is the subject thin/small compared to concept? (mask coverage issue)

### 6. Armature & Animation Readiness (Godot)

For characters and creatures, verify the GLB contains a proper armature for animation:

```python
from pygltflib import GLTF2
import os

path = os.path.expanduser(f"~/assets/final_glb/{asset_name}_final.glb")
gltf = GLTF2().load(path)

skins = gltf.skins or []
print(f"Skins: {len(skins)}")
if skins:
    joints = skins[0].joints
    print(f"Joint count: {len(joints)}")
    bone_names = [gltf.nodes[j].name for j in joints]
    print(f"Bones: {bone_names}")

    # Check for required bones (Godot-compatible naming)
    required_creature = {"hips", "spine", "chest", "neck", "head"}
    required_humanoid = required_creature | {"left_upper_arm", "right_upper_arm", "left_upper_leg", "right_upper_leg"}

    found = set(bone_names)
    missing_creature = required_creature - found
    missing_humanoid = required_humanoid - found
    print(f"Missing creature bones: {missing_creature or 'none'}")
    print(f"Missing humanoid bones: {missing_humanoid or 'none'}")

# Check mesh has JOINTS_0 and WEIGHTS_0 (actual skinning data)
for mesh in (gltf.meshes or []):
    for prim in mesh.primitives:
        has_joints = prim.attributes.JOINTS_0 is not None
        has_weights = prim.attributes.WEIGHTS_0 is not None
        print(f"Mesh {mesh.name}: joints={has_joints}, weights={has_weights}")
```

**Armature expectations by ASSET_TYPE:**

| ASSET_TYPE | Armature Required | Min Bones | Required Bones |
|------------|-------------------|-----------|----------------|
| humanoid | Yes | 21 | hips, spine, chest, neck, head, left/right_shoulder, left/right_upper_arm, left/right_lower_arm, left/right_hand, left/right_upper_leg, left/right_lower_leg, left/right_foot, left/right_toe |
| creature | Yes | 8 | hips, spine, chest, neck, head |
| prop | No | — | — |
| weapon | No | — | — |

> **Note:** The 21-bone humanoid skeleton matches Godot's `SkeletonProfileHumanoid`. Blender's glTF export may add a `neutral_bone` (root bone artifact) — this is harmless and ignored by Godot's profile matching.

### 7a. Scale Validation

Check the asset height matches real-world scale targets:

```python
import trimesh, os

path = os.path.expanduser(f"~/assets/final_glb/{asset_name}_final.glb")
scene = trimesh.load(path)
mesh = scene.to_geometry() if hasattr(scene, 'to_geometry') else list(scene.geometry.values())[0]

# glTF uses Y-up: height is Y-axis span
y_span = mesh.bounds[1][1] - mesh.bounds[0][1]
print(f"Height (Y-up): {y_span:.3f}m")
```

**Scale targets by ASSET_TYPE:**

| ASSET_TYPE | Target Height | Tolerance |
|------------|--------------|-----------|
| humanoid | 1.75m | ±0.05m |
| creature | 1.0m | ±0.2m |
| prop | 0.8m | ±0.3m |
| weapon | 1.0m | ±0.3m |

Override with `TARGET_HEIGHT` env var during Stage 6.

### 7b. LOD & Collision Checks

If LOD files exist, verify vertex counts decrease and height is preserved:

```python
import trimesh, os

for suffix, max_verts in [("_lod1", 6000), ("_lod2", 2000)]:
    path = os.path.expanduser(f"~/assets/final_glb/{asset_name}{suffix}.glb")
    if os.path.exists(path):
        scene = trimesh.load(path)
        mesh = list(scene.geometry.values())[0]
        verts = len(mesh.vertices)
        print(f"LOD {suffix}: {verts} verts (max: {max_verts})")
        if verts > max_verts:
            print(f"  ⚠️ Over budget")

# Collision mesh
col_path = os.path.expanduser(f"~/assets/final_glb/{asset_name}-col.glb")
if os.path.exists(col_path):
    scene = trimesh.load(col_path)
    mesh = list(scene.geometry.values())[0]
    print(f"Collision: {len(mesh.vertices)} verts (should be < 500)")
```

### 7c. Texture Power-of-Two Check

Verify all textures have power-of-two dimensions (required for efficient GPU mipmapping):

```python
# In Blender MCP after import:
for img in bpy.data.images:
    w, h = img.size
    is_pot = (w & (w-1) == 0) and (h & (h-1) == 0) and w > 0 and h > 0
    if not is_pot:
        print(f"⚠️ Non-POT texture: {img.name} ({w}×{h})")
```

### 7. Game-Readiness Checklist

| Requirement | Target | How to Check |
|-------------|--------|--------------|
| Single GLB file | Yes | `ls ~/assets/final_glb/{asset}_final.glb` |
| Vertex count | Per ASSET_TYPE (see below) | trimesh / pygltflib |
| Has textures | ≥ 1 TEX_IMAGE | Blender material check |
| Texture resolution | ≥ 512×512, power-of-two | Blender image.size |
| UV mapped | Yes | `obj.data.uv_layers` exists |
| Normals consistent | Yes | Visual check (no dark patches) |
| Not a bas-relief | Z-depth > 0.1 | trimesh bounds |
| Reasonable file size | 5–20MB | `ls -la` |
| Has armature (char/creature) | Yes | pygltflib skins check |
| Has vertex weights | Yes | JOINTS_0 + WEIGHTS_0 accessors |
| Godot bone names | Yes | Check against required set |
| Real-world scale | See ASSET_TYPE table | Y-axis span in trimesh |
| LOD chain (if generated) | LOD1 < 6K, LOD2 < 2K | trimesh vertex counts |
| Collision mesh (if generated) | Convex hull < 500v | trimesh vertex count |

**Vertex budget by ASSET_TYPE (Godot PC targets — Trellis2 baked textures):**

| ASSET_TYPE | Target Verts | Max Tris | Use Case |
|------------|-------------|----------|----------|
| humanoid | 15,000 | ~30K | Player characters, major NPCs |
| creature | 150,000 | ~300K | Wolves, owls, dragons — high count preserves Trellis2 UV fidelity |
| prop | 100,000 | ~200K | Pots, barrels, crates — Trellis2 textures need 100K+ |
| weapon | 50,000 | ~100K | Swords, shields — simpler geometry can go lower |

> **Universal rule for Trellis2 baked textures:** ALL asset types need 50K+ vertices minimum to preserve UV mapping. Decimating below 50K produces shredded/metallic texture artifacts regardless of asset type. The low targets (3K/2K) in earlier docs only apply to meshes without baked textures.

## Verdict

Assign one of:

- **PASS** — asset is game-ready, all checks pass
- **WARN** — asset is usable with minor issues (vertex count slightly over target, minor UV stretching, bas-relief risk)
- **FAIL** — critical issues that must be fixed (missing textures, degenerate geometry, no UVs, unrecognizable shape, completely dark render)

## Report Output

Write **two outputs** to `~/assets/validation_reports/`:

### 1. Machine-Readable JSON — `{asset_name}_validation.json`

This structured file is consumed by the **asset-orchestrator** agent for automated remediation decisions. Always write it first.

```json
{
  "asset_name": "spiked_shield",
  "verdict": "WARN",
  "score": 72,
  "metrics": {
    "vertices": 84200,
    "faces": 168000,
    "z_depth": 0.342,
    "file_size_mb": 14.2,
    "texture_count": 2,
    "texture_resolution": [2048, 2048],
    "uv_layers": 1,
    "materials": 1
  },
  "issues": [
    {
      "id": "high_vertex_count",
      "severity": "warning",
      "description": "Vertex count 84200 exceeds 80K target",
      "recommended_action": "re_decimate"
    }
  ],
  "visual_checks": {
    "concept_centered": true,
    "mask_complete": true,
    "shape_matches_concept": true,
    "textures_visible": true,
    "colors_match": true,
    "no_geometry_artifacts": true
  }
}
```

**Field definitions:**

| Field | Type | Description |
|-------|------|-------------|
| `verdict` | `PASS` / `WARN` / `FAIL` | Overall quality verdict |
| `score` | 0–100 | Quality score (100 = perfect). Deduct points per issue: FAIL issue = -30, WARN issue = -10 |
| `metrics.*` | numbers | Raw measurements from trimesh + Blender |
| `issues[].id` | string | Machine-parseable issue identifier (see table below) |
| `issues[].severity` | `critical` / `warning` / `info` | Issue severity |
| `issues[].recommended_action` | string | Suggested remediation (see table below) |
| `visual_checks.*` | boolean | Results of visual inspection |

**Issue IDs and recommended actions:**

| Issue ID | Severity | Recommended Action | Description |
|----------|----------|--------------------|-------------|
| `bas_relief` | critical | `regenerate_concept` | Z-depth < 0.05, mesh is flat |
| `low_z_depth` | warning | `regenerate_concept` | Z-depth 0.05–0.1, borderline depth |
| `high_vertex_count` | warning | `re_decimate` | Vertices > 80K after decimation |
| `extreme_vertex_count` | critical | `re_decimate` | Vertices > 150K after decimation |
| `missing_textures` | critical | `redo_stage6` | No TEX_IMAGE nodes with loaded images |
| `dark_render` | critical | `redo_stage6` | Textures present but render is near-black (UV misalignment) |
| `no_uv_map` | critical | `redo_stage6` | No UV layers on mesh |
| `shape_mismatch` | critical | `regenerate_3d` | 3D shape doesn't match concept silhouette |
| `oversized_file` | warning | `re_decimate` | File > 20MB |
| `extremely_oversized` | critical | `re_decimate` | File > 30MB |
| `low_texture_res` | warning | `info_only` | Textures < 512×512 |
| `mask_too_thin` | warning | `regenerate_concept` | Enhanced mask covers too little of concept |
| `colors_wrong` | critical | `redo_stage6` | Texture colors don't match concept palette |
| `missing_armature` | critical | `redo_stage6` | Character/creature GLB has no skin/armature (ASSET_TYPE requires one) |
| `no_vertex_weights` | critical | `redo_stage6` | Armature exists but mesh has no JOINTS_0/WEIGHTS_0 (skinning failed) |
| `sheet_mesh` | critical | `regenerate_3d` | Solid raw or final GLB rest view looks like a slab/curtain or fused-limb sheet rather than a character volume |
| `stage6_mesh_damage` | critical | `redo_stage6` | Raw solid rest view is coherent but the final solid rest view becomes shredded or heavily fragmented after Stage 6 |
| `wrapping_failure` | critical | `redo_stage6` | Solid final GLB looks acceptable in rest pose but explodes/tears when posed |
| `insufficient_bones` | warning | `redo_stage6` | Bone count below minimum for ASSET_TYPE |
| `wrong_bone_names` | warning | `info_only` | Bones don't follow Godot naming convention |
| `over_vertex_budget` | warning | `re_decimate` | Vertex count exceeds ASSET_TYPE target |
| `wrong_scale` | warning | `redo_stage6` | Height doesn't match ASSET_TYPE target (±tolerance) |
| `non_pot_textures` | warning | `redo_stage6` | Textures not power-of-two dimensions |
| `lod_over_budget` | warning | `redo_stage6` | LOD vertex count exceeds max for that level |
| `missing_lods` | info | `info_only` | LOD files not generated (run with GENERATE_LODS=1) |

```bash
# Write JSON report
python3 -c "
import json, os
report = {
    'asset_name': '${asset_name}',
    'verdict': verdict,
    'score': score,
    'metrics': metrics,
    'issues': issues,
    'visual_checks': visual_checks
}
os.makedirs(os.path.expanduser('~/assets/validation_reports'), exist_ok=True)
with open(os.path.expanduser(f'~/assets/validation_reports/${asset_name}_validation.json'), 'w') as f:
    json.dump(report, f, indent=2)
print(json.dumps(report, indent=2))
"
```

### 2. Human-Readable Markdown — `{asset_name}_validation.md`

```markdown
# {asset_name} — Validation Report

## Verdict: PASS / WARN / FAIL (Score: XX/100)

## Geometry
- Vertices: X
- Faces: X
- Z-depth: X
- File size: X MB
- Bounds: [min] → [max]

## Textures
- Materials: X
- Textures: X (list with dimensions)
- UV layers: X

## Visual Checks
- [ ] Concept art: centered, detailed, matches intent
- [ ] Mask: full foreground, edges preserved
- [ ] Enhanced mask: covers soft edges
- [ ] 3D shape: matches concept silhouette
- [ ] Textures visible: not dark/black
- [ ] Colors match concept
- [ ] Normal map: proper blue/purple tones
- [ ] No geometry artifacts

## Issues Found
- (list any issues with severity: critical/warning/info)

## Recommendations
- (specific fixes if verdict is not PASS)
```

## Known Failure Modes

| Symptom | Cause | Severity |
|---------|-------|----------|
| Near-black 3D render | Smart UV Project destroyed Trellis2's baked UVs | FAIL |
| Z-depth < 0.05 | Front-view concept produced bas-relief | WARN |
| Groove/ridge artifacts on surface | Trellis2 baked texture artifacts — less visible with color variation | WARN (creature) |
| Uniform white/grey with visible grooves | Concept art lacked color variation — Trellis2 artifacts exposed | FAIL (creature) |
| 130K+ vertices after decimation | Organic shape resists fixed-ratio decimation | PASS (creature), WARN (other) |
| Missing textures on material | GLTF import lost texture references | FAIL |
| RGBA mask smaller than concept subject | Enhanced mask threshold too high | WARN |
| Textures present but colors wrong | UV misalignment from Smart UV Project | FAIL |
| Dark/blue glossy appearance | CHORD PBR roughness map background bleeding through | FAIL |
| Thin spike or degenerate geometry | Hunyuan3D failure on organic creatures | FAIL |

## Important Notes

- Trellis2 bakes its own textures — if TEX_IMAGE nodes exist with loaded images, the asset used Trellis2 textures (not CHORD PBR)
- A valid Trellis2 asset has 2 textures: base color (2048×2048) + metallic/roughness (2048×2048)
- PBR maps in `~/assets/pbr_maps/` are generated but may NOT be applied to the final GLB if Trellis2 textures are present
- The `to_geometry()` method is needed for trimesh Scene objects (Trellis2 GLBs load as Scene, not Trimesh)
- ConnectionResetError during Trellis2 is transient — retry before marking as failure
- **Creature-specific:** 100K–150K vertices is the expected range for creatures — this preserves Trellis2 UV fidelity. Do NOT flag as over-budget.
- **Creature-specific:** Trellis2 groove artifacts are a known limitation. If concept art has good color variation, grooves blend in and should be accepted as PASS.
- **Trellis2 params:** Default values (12 steps, 7.5 guidance) are optimal. Increasing them causes CUDA OOM on RTX 3090.
