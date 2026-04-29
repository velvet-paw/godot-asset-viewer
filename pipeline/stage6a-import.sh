#!/usr/bin/env bash
# stage6a-import.sh — Import, manifold repair, ground removal
# Steps 1, 1a, 1b of the Blender post-processing pipeline.
#
# Usage: ./stage6a-import.sh [glb_filename] [asset_name] [mcp_url]

set -euo pipefail

GLB_INPUT="${1:-${GLB_INPUT:-asset_00001_.glb}}"
ASSET_NAME="${2:-${ASSET_NAME:-asset}}"
MCP_URL="${3:-${MCP_URL:-http://localhost:8000}}"
export GLB_INPUT ASSET_NAME MCP_URL

source "$(dirname "$0")/stage6-common.sh"

# --- Step 1: Clear scene and import GLB ---

echo "── Step 1: Import raw GLB ──"

IMPORT_CODE=$(cat <<PYEOF
import bpy
import os

# Blender MCP sessions can persist mode/object state between calls and runs.
# Clear via data API so reruns do not depend on a valid VIEW_3D operator context.
try:
    active_obj = bpy.context.view_layer.objects.active
    if active_obj and active_obj.mode != 'OBJECT' and bpy.ops.object.mode_set.poll():
        bpy.ops.object.mode_set(mode='OBJECT')
except Exception:
    pass

for obj in list(bpy.data.objects):
    bpy.data.objects.remove(obj, do_unlink=True)

for block in list(bpy.data.meshes):
    if block.users == 0:
        bpy.data.meshes.remove(block)
for block in list(bpy.data.materials):
    if block.users == 0:
        bpy.data.materials.remove(block)
for block in list(bpy.data.armatures):
    if block.users == 0:
        bpy.data.armatures.remove(block)
for block in list(bpy.data.images):
    if block.users == 0:
        bpy.data.images.remove(block)

# Import the raw GLB
glb_path = "${RAW_3D_DIR}/${GLB_INPUT}"
if not os.path.exists(glb_path):
    raise FileNotFoundError(f"GLB not found: {glb_path}")

bpy.ops.import_scene.gltf(filepath=glb_path)

# Report what was imported
mesh_objects = [obj for obj in bpy.context.scene.objects if obj.type == 'MESH']
total_verts = sum(len(obj.data.vertices) for obj in mesh_objects)
total_faces = sum(len(obj.data.polygons) for obj in mesh_objects)
print(f"Imported {len(mesh_objects)} mesh(es): {total_verts} verts, {total_faces} faces")
PYEOF
)

RESP=$(run_blender_code "$IMPORT_CODE")
if ! check_mcp_error "$RESP" "Import"; then exit 1; fi
echo "  ✅ GLB imported"

# Check for over-target vertex count — indicates Trellis2 decimation_target failed.
# When this happens, baked textures will have fragmented UV islands with garbage
# pixels between them, causing "shiny" artifacts in Godot.
IMPORT_VERTS=$(echo "$RESP" | { grep -oP '(\d+) verts' | grep -oP '\d+' || echo "0"; })
if [[ -n "${TARGET_VERTS:-}" && "$IMPORT_VERTS" -gt 0 ]]; then
    OVER_RATIO=$(( IMPORT_VERTS / TARGET_VERTS ))
    if [[ "$OVER_RATIO" -ge 3 ]]; then
        echo "  ⚠ WARNING: Input mesh has ${IMPORT_VERTS} verts (${OVER_RATIO}x over TARGET_VERTS=${TARGET_VERTS})"
        echo "    Trellis2 decimation_target likely failed. Baked texture quality may be poor."
        echo "    Consider: regenerate with lower decimation_target, or set FORCE_PBR=1"
    fi
fi

# --- Step 1a: Manifold mesh repair ---
#
# Trellis2 meshes are often non-manifold (holes, internal faces, loose geometry).
# Repair before any other processing to improve decimation and rigging quality.

echo "── Step 1a: Manifold mesh repair ──"

MANIFOLD_CODE=$(cat <<'PYEOF'
import bpy

mesh_objects = [obj for obj in bpy.context.scene.objects if obj.type == 'MESH']
total_fixed = 0
for obj in mesh_objects:
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')

    # Merge duplicate vertices
    bpy.ops.mesh.remove_doubles(threshold=0.0005)

    # Remove zero-area faces and degenerate geometry
    bpy.ops.mesh.dissolve_degenerate(threshold=0.0001)

    # Remove isolated vertices and edges with no faces
    bpy.ops.mesh.delete_loose(use_verts=True, use_edges=True, use_faces=False)

    # Fill small holes (≤4 sides)
    bpy.ops.mesh.select_all(action='DESELECT')
    bpy.ops.mesh.select_non_manifold(extend=False)
    try:
        bpy.ops.mesh.fill_holes(sides=4)
    except RuntimeError:
        pass

    # Recalculate normals
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.normals_make_consistent(inside=False)

    bpy.ops.object.mode_set(mode='OBJECT')
    obj.select_set(False)
    total_fixed += 1

print(f"MANIFOLD_REPAIRED={total_fixed} meshes")
PYEOF
)

RESP=$(run_blender_code "$MANIFOLD_CODE")
if ! check_mcp_error "$RESP" "Manifold repair"; then
    echo "  ⚠ Manifold repair failed (non-fatal, continuing)"
else
    echo "  ✅ Manifold repair complete"
fi

# --- Step 1b: Ground plane removal ---
#
# Trellis2 frequently generates flat ground plane artifacts underneath characters
# (up to 42% of mesh vertices). Detect and remove them before decimation.
# Skip with SKIP_GROUND_REMOVAL=1 if the asset intentionally has a base.

if [[ "${SKIP_GROUND_REMOVAL:-0}" != "1" ]]; then
    echo "── Step 1b: Ground plane detection ──"

GROUND_PLANE_CODE=$(cat <<'PYEOF'
import bpy, bmesh
from mathutils import Vector

mesh_objects = [obj for obj in bpy.context.scene.objects if obj.type == 'MESH']
if not mesh_objects:
    print("GROUND_REMOVED=0")

else:
    # Collect all vertex world-space Z coords
    all_z = []
    for obj in mesh_objects:
        mw = obj.matrix_world
        for v in obj.data.vertices:
            all_z.append((mw @ v.co).z)

    z_min, z_max = min(all_z), max(all_z)
    z_range = z_max - z_min

    # Safety: skip if mesh is very short (flat prop, coin, etc.)
    if z_range < 0.15:
        print(f"GROUND_SKIP=short_mesh z_range={z_range:.4f}")
        print("GROUND_REMOVED=0")
    else:
        # Bin vertices into Z bands (2% of height each)
        band_size = z_range * 0.02
        num_bands = int(z_range / band_size) + 1

        # For each band, compute XY footprint area (x_span * y_span)
        band_footprints = {}
        band_counts = {}
        for obj in mesh_objects:
            mw = obj.matrix_world
            for v in obj.data.vertices:
                wco = mw @ v.co
                band_idx = int((wco.z - z_min) / band_size)
                band_idx = min(band_idx, num_bands - 1)
                if band_idx not in band_footprints:
                    band_footprints[band_idx] = {'x_min': wco.x, 'x_max': wco.x, 'y_min': wco.y, 'y_max': wco.y}
                    band_counts[band_idx] = 0
                else:
                    fp = band_footprints[band_idx]
                    fp['x_min'] = min(fp['x_min'], wco.x)
                    fp['x_max'] = max(fp['x_max'], wco.x)
                    fp['y_min'] = min(fp['y_min'], wco.y)
                    fp['y_max'] = max(fp['y_max'], wco.y)
                band_counts[band_idx] = band_counts.get(band_idx, 0) + 1

        def footprint_area(fp):
            return (fp['x_max'] - fp['x_min']) * (fp['y_max'] - fp['y_min'])

        # Bottom 3 bands = candidate ground plane
        bottom_bands = sorted(band_footprints.keys())[:3]
        if not bottom_bands:
            print("GROUND_REMOVED=0")
        else:
            bottom_area = max(footprint_area(band_footprints[b]) for b in bottom_bands if b in band_footprints)

            # Scan upward to find where footprint shrinks significantly
            boundary_band = None
            sorted_bands = sorted(band_footprints.keys())
            for i, b in enumerate(sorted_bands):
                if b <= max(bottom_bands):
                    continue
                area = footprint_area(band_footprints[b])
                if bottom_area > 0 and area / bottom_area < 0.5:
                    boundary_band = b
                    break

            if boundary_band is None:
                print("GROUND_SKIP=no_footprint_drop")
                print("GROUND_REMOVED=0")
            else:
                boundary_z = z_min + boundary_band * band_size
                slab_height = boundary_z - z_min
                slab_pct = slab_height / z_range

                # Safety caps: slab must be thin (< 10% of height)
                if slab_pct > 0.10:
                    print(f"GROUND_SKIP=slab_too_tall pct={slab_pct:.1%}")
                    print("GROUND_REMOVED=0")
                else:
                    # Count vertices that would be removed
                    remove_count = sum(band_counts.get(b, 0) for b in sorted_bands if b < boundary_band)
                    total_verts = len(all_z)
                    remove_pct = remove_count / total_verts if total_verts > 0 else 0

                    # Safety: don't remove more than 50% of mesh
                    if remove_pct > 0.50:
                        print(f"GROUND_SKIP=too_many_verts pct={remove_pct:.1%}")
                        print("GROUND_REMOVED=0")
                    else:
                        # Also verify bottom faces are mostly horizontal (normal.z > 0.8)
                        horiz_faces = 0
                        total_bottom_faces = 0
                        for obj in mesh_objects:
                            mw = obj.matrix_world
                            nm = mw.to_3x3().inverted().transposed()
                            for poly in obj.data.polygons:
                                avg_z = sum((mw @ obj.data.vertices[vi].co).z for vi in poly.vertices) / len(poly.vertices)
                                if avg_z < boundary_z:
                                    total_bottom_faces += 1
                                    world_normal = (nm @ poly.normal).normalized()
                                    if abs(world_normal.z) > 0.7:
                                        horiz_faces += 1

                        horiz_ratio = horiz_faces / total_bottom_faces if total_bottom_faces > 0 else 0
                        if horiz_ratio < 0.3:
                            print(f"GROUND_SKIP=not_horizontal ratio={horiz_ratio:.1%}")
                            print("GROUND_REMOVED=0")
                        else:
                            print(f"GROUND_DETECT: boundary_z={boundary_z:.4f} slab={slab_pct:.1%} "
                                  f"verts={remove_count}/{total_verts} ({remove_pct:.0%}) "
                                  f"horiz={horiz_ratio:.0%} footprint_ratio={footprint_area(band_footprints[boundary_band])/bottom_area:.2f}")

                            # Delete ground plane vertices
                            removed = 0
                            for obj in mesh_objects:
                                mw = obj.matrix_world
                                bpy.context.view_layer.objects.active = obj
                                bpy.ops.object.mode_set(mode='EDIT')
                                bm = bmesh.from_edit_mesh(obj.data)
                                bm.verts.ensure_lookup_table()

                                for v in bm.verts:
                                    wz = (mw @ v.co).z
                                    v.select = wz < boundary_z

                                sel_count = sum(1 for v in bm.verts if v.select)
                                removed += sel_count

                                if sel_count > 0:
                                    bpy.ops.mesh.delete(type='VERT')
                                    bpy.ops.mesh.select_all(action='SELECT')
                                    bpy.ops.mesh.delete_loose(use_verts=True, use_edges=True, use_faces=False)
                                    bpy.ops.mesh.normals_make_consistent(inside=False)

                                bpy.ops.object.mode_set(mode='OBJECT')

                            total_after = sum(len(obj.data.vertices) for obj in mesh_objects)
                            print(f"GROUND_REMOVED={removed} remaining={total_after}")
PYEOF
)

    RESP=$(run_blender_code "$GROUND_PLANE_CODE")
    if ! check_mcp_error "$RESP" "Ground plane"; then
        echo "  ⚠ Ground plane detection failed (non-fatal, continuing)"
    else
        REMOVED=$(echo "$RESP" | { grep -oP 'GROUND_REMOVED=\K[0-9]+' || true; } | head -1)
        if [[ -n "$REMOVED" && "$REMOVED" -gt 0 ]]; then
            echo "  ✅ Removed $REMOVED ground plane vertices"
        else
            SKIP_REASON=$(echo "$RESP" | { grep -oP 'GROUND_SKIP=\K\S+' || true; } | head -1)
            if [[ -n "$SKIP_REASON" ]]; then
                echo "  ⏭ No ground plane detected ($SKIP_REASON)"
            else
                echo "  ⏭ No ground plane detected"
            fi
        fi
    fi
else
    echo "── Step 1b: Ground plane detection ──"
    echo "  ⏭ Skipped (SKIP_GROUND_REMOVAL=1)"
fi
