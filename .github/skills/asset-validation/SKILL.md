---
name: asset-validation
description: Validates game-ready 3D GLB assets — geometry analysis (trimesh), material/texture checks (Blender MCP), armature validation, scale/LOD/POT checks, issue taxonomy, and report templates. Use when validating assets, writing validation reports, checking asset quality, or interpreting validation results.
allowed-tools: shell
---

# Asset Validation

## Geometry Analysis (trimesh)

```python
import trimesh, os

path = os.path.expanduser(f"~/assets/final_glb/{asset_name}_final.glb")
scene = trimesh.load(path)
mesh = scene.to_geometry()

print(f"Vertices: {len(mesh.vertices)}")
print(f"Faces: {len(mesh.faces)}")
print(f"Bounds: {mesh.bounds}")
print(f"File size: {os.path.getsize(path) / 1024:.0f} KB")

z_range = mesh.bounds[1][2] - mesh.bounds[0][2]
if z_range < 0.1:
    print(f"⚠️ WARNING: Z-depth {z_range:.4f} — possible bas-relief")
```

**Thresholds:**

| Metric | Pass | Warn | Fail | Notes |
|--------|------|------|------|-------|
| Vertices (humanoid) | < 20K | 20K–30K | > 30K | |
| Vertices (creature) | < 200K | 200K–300K | > 300K | 150K target for Trellis2 UV fidelity |
| Vertices (prop) | < 150K | 150K–200K | > 200K | 100K target |
| Vertices (weapon) | < 80K | 80K–100K | > 100K | 50K target |
| Z-depth | > 0.1 | 0.05–0.1 | < 0.05 | |
| File size (Trellis2) | 5–20MB | 20–30MB | > 30MB | |
| File size (other) | 1–10MB | 10–20MB | > 20MB | |

## Material & Texture Validation (Blender MCP)

> **⚠️ MCP Error Detection**: Blender MCP always returns `isError: false` even on exceptions. Check response text for `"Error executing code:"`.

```python
import bpy

bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
bpy.ops.import_scene.gltf(filepath=f"/assets/final_glb/{asset_name}_final.glb")

for obj in [o for o in bpy.context.scene.objects if o.type == 'MESH']:
    print(f"Object: {obj.name}, Vertices: {len(obj.data.vertices)}, Materials: {len(obj.material_slots)}")
    for slot in obj.material_slots:
        if slot.material and slot.material.use_nodes:
            tex_count = 0
            for node in slot.material.node_tree.nodes:
                if node.type == 'TEX_IMAGE' and node.image:
                    tex_count += 1
                    print(f"  Texture: {node.image.name} ({node.image.size[0]}x{node.image.size[1]})")
            if tex_count == 0:
                print("  ⚠️ No textures found")
    if obj.data.uv_layers:
        print(f"  UV layers: {len(obj.data.uv_layers)}")
    else:
        print("  ❌ No UV map")
```

**Expected (Trellis2):** 1 material, 2 textures (base color 2048×2048 + metallic/roughness 2048×2048), 1 UV layer.

## Armature & Animation Readiness

```python
from pygltflib import GLTF2
import os

path = os.path.expanduser(f"~/assets/final_glb/{asset_name}_final.glb")
gltf = GLTF2().load(path)

skins = gltf.skins or []
print(f"Skins: {len(skins)}")
if skins:
    joints = skins[0].joints
    bone_names = [gltf.nodes[j].name for j in joints]
    print(f"Joint count: {len(joints)}, Bones: {bone_names}")

    required_creature = {"hips", "spine", "chest", "neck", "head"}
    required_humanoid = required_creature | {"left_upper_arm", "right_upper_arm", "left_upper_leg", "right_upper_leg"}
    found = set(bone_names)
    print(f"Missing creature bones: {required_creature - found or 'none'}")
    print(f"Missing humanoid bones: {required_humanoid - found or 'none'}")

for mesh in (gltf.meshes or []):
    for prim in mesh.primitives:
        has_joints = prim.attributes.JOINTS_0 is not None
        has_weights = prim.attributes.WEIGHTS_0 is not None
        print(f"Mesh {mesh.name}: joints={has_joints}, weights={has_weights}")
```

| ASSET_TYPE | Armature Required | Min Bones | Required Bones |
|------------|-------------------|-----------|----------------|
| humanoid | Yes | 21 | hips, spine, chest, neck, head, left/right_shoulder, _upper_arm, _lower_arm, _hand, _upper_leg, _lower_leg, _foot, _toe |
| creature | Yes | 8 | hips, spine, chest, neck, head |
| prop | No | — | — |
| weapon | No | — | — |

> The 21-bone humanoid skeleton matches Godot's `SkeletonProfileHumanoid`. Blender may add a `neutral_bone` root — harmless, ignored by Godot.

## Scale Validation

```python
import trimesh, os
path = os.path.expanduser(f"~/assets/final_glb/{asset_name}_final.glb")
scene = trimesh.load(path)
mesh = scene.to_geometry() if hasattr(scene, 'to_geometry') else list(scene.geometry.values())[0]
y_span = mesh.bounds[1][1] - mesh.bounds[0][1]  # glTF Y-up
print(f"Height (Y-up): {y_span:.3f}m")
```

| ASSET_TYPE | Target Height | Tolerance |
|------------|--------------|-----------|
| humanoid | 1.75m | ±0.05m |
| creature | 1.0m | ±0.2m |
| prop | 0.8m | ±0.3m |
| weapon | 1.0m | ±0.3m |

## LOD & Collision Checks

```python
import trimesh, os
for suffix, max_verts in [("_lod1", 6000), ("_lod2", 2000)]:
    path = os.path.expanduser(f"~/assets/final_glb/{asset_name}{suffix}.glb")
    if os.path.exists(path):
        scene = trimesh.load(path)
        mesh = list(scene.geometry.values())[0]
        verts = len(mesh.vertices)
        print(f"LOD {suffix}: {verts} verts (max: {max_verts}) {'⚠️' if verts > max_verts else '✅'}")

col_path = os.path.expanduser(f"~/assets/final_glb/{asset_name}-col.glb")
if os.path.exists(col_path):
    scene = trimesh.load(col_path)
    mesh = list(scene.geometry.values())[0]
    print(f"Collision: {len(mesh.vertices)} verts (should be < 500)")
```

## Texture Power-of-Two Check

```python
# In Blender MCP after import:
for img in bpy.data.images:
    w, h = img.size
    is_pot = (w & (w-1) == 0) and (h & (h-1) == 0) and w > 0 and h > 0
    if not is_pot:
        print(f"⚠️ Non-POT texture: {img.name} ({w}×{h})")
```

## Game-Readiness Checklist

| Requirement | Target | How to Check |
|-------------|--------|--------------|
| Single GLB file | Yes | `ls ~/assets/final_glb/{asset}_final.glb` |
| Vertex count | Per ASSET_TYPE | trimesh / pygltflib |
| Has textures | ≥ 1 TEX_IMAGE | Blender material check |
| Texture resolution | ≥ 512×512, POT | Blender image.size |
| UV mapped | Yes | `obj.data.uv_layers` |
| Normals consistent | Yes | Visual check (no dark patches) |
| Not bas-relief | Z-depth > 0.1 | trimesh bounds |
| File size | 5–20MB | `ls -la` |
| Has armature (char/creature) | Yes | pygltflib skins check |
| Has vertex weights | Yes | JOINTS_0 + WEIGHTS_0 |
| Godot bone names | Yes | Check against required set |
| Real-world scale | Per ASSET_TYPE | Y-axis span in trimesh |
| LOD chain (if generated) | LOD1 < 6K, LOD2 < 2K | trimesh |
| Collision mesh (if generated) | < 500v | trimesh |

**Vertex budget (Trellis2 baked textures):**

| ASSET_TYPE | Target Verts | Max Tris | Notes |
|------------|-------------|----------|-------|
| humanoid | 15,000 | ~30K | Player characters, major NPCs |
| creature | 150,000 | ~300K | Preserves Trellis2 UV fidelity |
| prop | 100,000 | ~200K | Trellis2 textures need 100K+ |
| weapon | 50,000 | ~100K | Simpler geometry |

> **Universal rule:** ALL asset types need 50K+ vertices minimum to preserve Trellis2 baked UV mapping.

## Issue Taxonomy

| Issue ID | Severity | Recommended Action | Description |
|----------|----------|--------------------|-------------|
| `bas_relief` | critical | `regenerate_concept` | Z-depth < 0.05, mesh is flat |
| `low_z_depth` | warning | `regenerate_concept` | Z-depth 0.05–0.1, borderline |
| `high_vertex_count` | warning | `re_decimate` | Vertices over budget |
| `extreme_vertex_count` | critical | `re_decimate` | Vertices > 150K after decimation |
| `missing_textures` | critical | `redo_stage6` | No TEX_IMAGE nodes |
| `dark_render` | critical | `redo_stage6` | Render near-black (UV misalignment) |
| `no_uv_map` | critical | `redo_stage6` | No UV layers |
| `shape_mismatch` | critical | `regenerate_3d` | Shape doesn't match concept |
| `oversized_file` | warning | `re_decimate` | File > 20MB |
| `extremely_oversized` | critical | `re_decimate` | File > 30MB |
| `low_texture_res` | warning | `info_only` | Textures < 512×512 |
| `mask_too_thin` | warning | `regenerate_concept` | Enhanced mask too small |
| `colors_wrong` | critical | `redo_stage6` | Colors don't match concept |
| `missing_armature` | critical | `redo_stage6` | Character/creature missing skin |
| `no_vertex_weights` | critical | `redo_stage6` | No JOINTS_0/WEIGHTS_0 |
| `sheet_mesh` | critical | `regenerate_3d` | Solid rest view is slab/curtain |
| `stage6_mesh_damage` | critical | `redo_stage6` | Raw good, final shredded |
| `wrapping_failure` | critical | `redo_stage6` | Rest OK, posed explodes |
| `insufficient_bones` | warning | `redo_stage6` | Below min bones |
| `wrong_bone_names` | warning | `info_only` | Non-Godot naming |
| `over_vertex_budget` | warning | `re_decimate` | Over ASSET_TYPE target |
| `wrong_scale` | warning | `redo_stage6` | Height off target |
| `non_pot_textures` | warning | `redo_stage6` | Non-POT dimensions |
| `lod_over_budget` | warning | `redo_stage6` | LOD verts too high |
| `missing_lods` | info | `info_only` | No LOD files generated |
| `uniform_coloring` | critical | `regenerate_concept` | Creature: no color variation, groove artifacts visible |

## Report Templates

### JSON — `{asset_name}_validation.json`

```json
{
  "asset_name": "{asset_name}",
  "verdict": "PASS|WARN|FAIL",
  "score": 85,
  "metrics": {
    "vertices": 0, "faces": 0, "z_depth": 0.0,
    "file_size_mb": 0.0, "texture_count": 0,
    "texture_resolution": [2048, 2048],
    "uv_layers": 1, "materials": 1
  },
  "issues": [
    {"id": "issue_id", "severity": "critical|warning|info",
     "description": "...", "recommended_action": "action_name"}
  ],
  "visual_checks": {
    "concept_centered": true, "mask_complete": true,
    "shape_matches_concept": true, "textures_visible": true,
    "colors_match": true, "no_geometry_artifacts": true
  }
}
```

**Scoring:** Start at 100. Deduct per issue: critical = -30, warning = -10, info = 0.

### Markdown — `{asset_name}_validation.md`

```markdown
# {asset_name} — Validation Report

## Verdict: PASS / WARN / FAIL (Score: XX/100)

## Geometry
- Vertices: X / Faces: X / Z-depth: X / File size: X MB

## Textures
- Materials: X / Textures: X (dimensions) / UV layers: X

## Visual Checks
- [ ] Concept art: centered, detailed
- [ ] Mask: full foreground captured
- [ ] 3D shape: matches concept
- [ ] Textures visible (not black)
- [ ] Colors match concept

## Issues Found
- (list with severity)

## Recommendations
- (specific fixes if not PASS)
```

## Known Failure Modes

| Symptom | Cause | Severity |
|---------|-------|----------|
| Near-black render | Smart UV destroyed Trellis2 baked UVs | FAIL |
| Z-depth < 0.05 | Front-view concept → bas-relief | WARN |
| Groove artifacts (with color variation) | Trellis2 baked texture limitation | PASS (creature) |
| Uniform white/grey with grooves | Concept lacked color variation | FAIL (creature) |
| 130K+ verts after decimation | Organic shape resists decimation | PASS (creature), WARN (other) |
| Missing textures | GLTF import lost references | FAIL |
| Dark/blue glossy appearance | CHORD PBR roughness bleeding through | FAIL |

## Notes

- Trellis2 assets have 2 textures: base color + metallic/roughness (both 2048×2048)
- `to_geometry()` needed for trimesh Scene objects
- PBR maps in `~/assets/pbr_maps/` may not be applied if Trellis2 textures present
- Creature 100K–150K verts is expected — do NOT flag as over-budget
- Creature groove artifacts with good color variation = PASS
