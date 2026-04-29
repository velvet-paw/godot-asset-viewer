---
name: validate-final
description: Validates final game-ready GLB assets — geometry budget, material properties, texture quality, armature/skeleton, scale, file size, LODs. Run after Stage 6 (Blender post-processing) as the final quality gate.
allowed-tools: shell
---

# Validate Final GLB Asset

## Purpose

Final quality gate after Stage 6 Blender post-processing. Validates that a GLB asset is game-ready before importing into the Godot AssetViewer. Checks geometry budget, material correctness, texture quality, armature/skeleton integrity, world-space scale, file size, and LOD chain consistency.

This gate runs at the end of the pipeline:

```
Stage 6 (Blender post-processing) → gate6_final.py → Import into Godot
```

If the gate returns exit code 2 (FAIL), the orchestrator should re-run the failed stage with adjusted parameters before proceeding.

## Usage

```bash
python3 pipeline/gates/gate6_final.py <glb_path> --asset-name <name> --asset-type creature --target-verts 25000
```

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `<glb_path>` | Yes | Path to the final GLB file |
| `--asset-name` | No | Asset name for reports (default: `asset`) |
| `--asset-type` | No | Asset type: creature, humanoid, prop, weapon (default: `creature`) |
| `--target-verts` | No | Override target vertex count from thresholds |
| `--output` | No | Write JSON report to file (default: stdout) |
| `--log` | No | Validation log path (default: `~/assets/validation_log.txt`) |

**Examples:**

```bash
# Validate a creature and print JSON to stdout
python3 pipeline/gates/gate6_final.py ~/assets/final_glb/wolf_final.glb --asset-name wolf

# Validate a humanoid with custom vertex target
python3 pipeline/gates/gate6_final.py ~/assets/final_glb/knight_final.glb \
  --asset-name knight --asset-type humanoid --target-verts 15000

# Save report to file
python3 pipeline/gates/gate6_final.py ~/assets/final_glb/wolf_final.glb \
  --asset-name wolf --output ~/assets/reports/wolf_final.json
```

## Checks Performed

| Check | Status | Condition | Why It Matters |
|-------|--------|-----------|----------------|
| **vertex_count** | FAIL | < 100 vertices (degenerate mesh) | Mesh is empty or broken |
| **vertex_count** | WARN | > max_verts for asset type | Over geometry budget; impacts GPU performance |
| **material_metallic** | FAIL | Any material has metallic > 0.1 or metallic texture | Stylized assets must be non-metallic; metallic causes unwanted reflections |
| **material_roughness** | WARN | Roughness < 0.8 on any material | Low roughness causes glossy appearance that clashes with art style |
| **double_sided_missing** | WARN | Any material has doubleSided = false | Single-sided faces cause invisible geometry from certain angles |
| **texture_pot** | WARN | Texture dimensions not power-of-two | Non-POT textures waste VRAM and prevent mip-mapping on some GPUs |
| **texture_quality** | WARN | > 2% bright outlier pixels in any texture | Garbage/corrupted texture data from pipeline failures |
| **armature_check** | FAIL | Creature/humanoid missing armature or too few bones | Characters require skeletons for animation |
| **weight_coverage** | WARN | < 95% vertices with non-zero weights | Unweighted vertices won't follow skeleton during animation |
| **scale_check** | WARN | Bounding box height outside ±tolerance of target | Wrong scale causes mismatched assets in-game |
| **file_size** | WARN | GLB file exceeds max_file_mb | Oversized files increase load times and memory usage |
| **lod_check** | WARN | LOD mesh has more vertices than main mesh | LODs must be progressively simpler |

## Thresholds by Asset Type

| Parameter | creature | humanoid | prop | weapon |
|-----------|----------|----------|------|--------|
| max_verts | 75,000 | 50,000 | 75,000 | 50,000 |
| target_verts | 25,000 | 15,000 | 25,000 | 15,000 |
| max_file_mb | 15 | 15 | 10 | 8 |
| target_height | 1.0m | 1.75m | 0.8m | 1.0m |
| height_tolerance | ±0.2m | ±0.2m | ±0.3m | ±0.3m |
| min_bones | 10 | 18 | 0 | 0 |

## Interpreting JSON Output

```json
{
  "gate": "final_asset",
  "asset": "wolf",
  "verdict": "warn",
  "score": 75,
  "timestamp": "2025-01-15T10:30:00+00:00",
  "checks": [
    {
      "name": "vertex_count",
      "status": "PASS",
      "expected": "100–75000",
      "actual": "24350",
      "message": "Vertex count within budget"
    }
  ]
}
```

**Verdicts and exit codes:**

| Verdict | Exit Code | Meaning |
|---------|-----------|---------|
| `pass` | 0 | All checks passed — asset is game-ready |
| `warn` | 1 | Warnings present — review before importing |
| `fail` | 2 | Critical issues — must fix and re-run Stage 6 |

**Score:** 100 = all checks pass. Each WARN halves that check's contribution; each FAIL zeroes it.

## Common Failures and Remediation

| Failure | Cause | Fix |
|---------|-------|-----|
| `material_metallic` FAIL | CHORD PBR left metallic values or metallic texture | Re-run Stage 6c with `SKIP_MR_STRIP=0` to strip metallic; set metallic=0 |
| `vertex_count` FAIL (degenerate) | Blender export produced empty mesh | Re-run Stage 6 export; check Blender scene has geometry |
| `vertex_count` WARN (over budget) | Decimation insufficient | Lower `decimation_target` by 40% in Stage 3 and regenerate |
| `armature_check` FAIL | Rigging step skipped or failed | Re-run Stage 6d rigging with correct asset type |
| `weight_coverage` WARN | Auto-weights didn't cover all vertices | Re-run Stage 6d with adjusted weight thresholds |
| `scale_check` WARN | Blender scaling not applied | Re-run Stage 6b with correct `TARGET_HEIGHT` |
| `double_sided_missing` WARN | Material export defaults | Re-run Stage 6c to set doubleSided=true on all materials |
| `texture_pot` WARN | Texture resized to non-POT dimensions | Resize textures to nearest power of two in Stage 6d |
| `texture_quality` WARN | Pipeline corruption or bad source texture | Re-run Stage 6c with `FORCE_PBR=1` to replace fragmented texture |
| `file_size` WARN | Too many vertices or uncompressed textures | Lower `decimation_target` and `texture_size` |
| `lod_check` WARN | LOD generation produced larger mesh | Re-run LOD generation with lower target vertex count |
| `material_roughness` WARN | CHORD PBR roughness too low | Re-run Stage 6c; ensure roughness >= 0.8 |

## Integration with Pipeline

This is the final validation gate before Godot import:

```
Stage 1 (Flux) → Stage 2 (BiRefNet) → Stage 3 (Trellis2) → Stage 4 (CHORD PBR) → Stage 5 (assembly) → Stage 6 (Blender) → gate6_final.py → Godot
```

The orchestrator should call this gate after every Stage 6 completion. On FAIL, retry the failed sub-stage. On WARN, log for review but allow import if score >= 50.
