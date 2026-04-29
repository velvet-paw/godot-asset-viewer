---
name: validate-mesh
description: Validates raw 3D GLB meshes from Trellis2 — vertex count, UV island fragmentation, texture quality, bas-relief detection, manifold check. Run after Stage 3 to catch mesh issues before expensive Stage 6 processing.
allowed-tools: shell
---

# Validate Mesh (Gate 3)

## Purpose

Validates raw GLB meshes straight out of Trellis2 (Stage 3) **before** committing to the expensive Stage 6 Blender post-processing pipeline. This is the critical quality gate — it catches vertex count blowouts, UV fragmentation, and texture garbage that cause "shiny artifacts" in Godot.

The pit bull incident: Trellis2 output 335K vertices instead of the 25K `decimation_target`, producing catastrophically fragmented UV islands with garbage-colored pixels (bright pink, white, metallic silver) between them. Stage 6 mitigations (MR strip + texture padding) could not fix fundamentally fragmented textures. This gate would have caught it before wasting GPU time on Stage 6.

## Usage

```bash
python3 pipeline/gates/gate3_mesh.py <glb_path> \
  --asset-name <name> \
  --asset-type creature \
  --target-verts 25000
```

Arguments:
- `<glb_path>` — Path to raw GLB from Trellis2 (e.g., `~/assets/raw_3d/pitbull_00001_.glb`)
- `--asset-name` — Name for reports (default: `asset`)
- `--asset-type` — One of `creature`, `humanoid`, `prop`, `weapon` (default: `creature`)
- `--target-verts` — Override target vertex count (default: from gate_common thresholds)
- `--output` — Write JSON report to file instead of stdout
- `--log` — Custom validation log path

Exit codes: `0` = PASS, `1` = WARN, `2` = FAIL.

## Checks Performed

| Check | Threshold | Status | Description |
|-------|-----------|--------|-------------|
| `vertex_count` | > 3× target | FAIL | Trellis2 decimation completely failed |
| `vertex_count` | > 2× target | WARN | Vertex count higher than expected |
| `z_depth` | z < 5% of max(x,y) | FAIL | Bas-relief / flat mesh |
| `uv_island_count` | > threshold (500 creature) | WARN | Fragmented UVs → texture bleed |
| `uv_island_size` | median < 0.001 | WARN | Tiny islands → seam artifacts |
| `texture_alpha` | > 5% gap pixels | WARN | Alpha gaps in baked texture |
| `texture_garbage` | > 10% outliers | FAIL | Garbage-colored pixels dominate |
| `texture_garbage` | > 2% outliers | WARN | Some garbage pixels present |
| `manifold_check` | non-watertight | WARN | Non-manifold edges present |

## How UV Fragmentation Causes Shiny Artifacts

When Trellis2 fails to decimate to the target vertex count, it bakes textures onto a much denser mesh. The resulting UV layout has thousands of tiny disconnected islands instead of a few large coherent ones. The gaps between islands contain uninitialized pixels — bright pink, white, or metallic silver.

In Godot, bilinear texture filtering samples across UV island boundaries, bleeding these garbage pixels into the visible surface. The result is a "shiny brown" or "shiny silver" appearance — the Stage 6 MR strip removes metallic/roughness textures, but the garbage is baked into the base color texture itself.

**Key metric:** UV island count. A healthy 25K-vertex creature mesh has ~50–200 UV islands. A fragmented 335K mesh can have 5,000+.

## Common Failures and Remediation

| Failure | Cause | Remediation |
|---------|-------|-------------|
| `vertex_count` FAIL (>3× target) | Trellis2 decimation hit a floor | Lower `decimation_target` to 15K or 10K in workflow |
| `vertex_count` WARN (>2× target) | Organic shape resists decimation | May be acceptable for creatures; check UV quality |
| `z_depth` FAIL | Front-view concept → flat mesh | Regenerate concept with `three-quarter view, volumetric` |
| `uv_island_count` WARN | Vertex count blowout → fragmented UVs | Regenerate at lower `decimation_target` |
| `texture_garbage` FAIL | Garbage pixels between UV islands | Regenerate at lower `decimation_target`, or `FORCE_PBR=1` |
| `manifold_check` WARN | Open edges in mesh | Usually harmless; Stage 6 can handle |

## Example JSON Output

```json
{
  "gate": "mesh_quality",
  "asset": "pitbull",
  "verdict": "fail",
  "score": 42,
  "timestamp": "2025-01-15T12:00:00+00:00",
  "checks": [
    {
      "name": "vertex_count",
      "status": "FAIL",
      "expected": "<=75000",
      "actual": "335412",
      "message": "Vertex count 335412 exceeds 3x target (75000) — Trellis2 decimation failed"
    },
    {
      "name": "z_depth",
      "status": "PASS",
      "expected": "z_ratio>=0.05",
      "actual": "z_ratio=0.42",
      "message": "Mesh has adequate depth"
    },
    {
      "name": "uv_island_count",
      "status": "WARN",
      "expected": "<=500",
      "actual": "5234",
      "message": "UV island count 5234 exceeds threshold 500 — fragmented UVs"
    },
    {
      "name": "uv_island_size",
      "status": "WARN",
      "expected": "median>=0.001",
      "actual": "median=0.00003",
      "message": "Median UV island area 0.00003 — very small islands"
    },
    {
      "name": "texture_alpha",
      "status": "PASS",
      "expected": "gap_ratio<=0.05",
      "actual": "gap_ratio=0.01",
      "message": "Texture alpha coverage OK"
    },
    {
      "name": "texture_garbage",
      "status": "FAIL",
      "expected": "outlier_ratio<=0.10",
      "actual": "outlier_ratio=0.18",
      "message": "18.0% of texture pixels are bright outliers — garbage between UV islands"
    },
    {
      "name": "manifold_check",
      "status": "PASS",
      "expected": "watertight",
      "actual": "watertight",
      "message": "Mesh is watertight"
    }
  ],
  "remediation": {
    "action": "rerun_stage3",
    "reason": "Vertex count 335412 exceeds 3x target (75000) — Trellis2 decimation failed",
    "instructions": {
      "stage": "stage3",
      "message": "Lower decimation_target by 40% and regenerate"
    }
  }
}
```
