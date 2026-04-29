#!/usr/bin/env bash
# stage6b-geometry.sh — Decimate + scale
# Steps 2, 2b of the Blender post-processing pipeline.
#
# Usage: ./stage6b-geometry.sh [glb_filename] [asset_name] [mcp_url]
# Env: TARGET_VERTS, ASSET_TYPE, TARGET_HEIGHT

set -euo pipefail

GLB_INPUT="${1:-${GLB_INPUT:-asset_00001_.glb}}"
ASSET_NAME="${2:-${ASSET_NAME:-asset}}"
MCP_URL="${3:-${MCP_URL:-http://localhost:8000}}"
export GLB_INPUT ASSET_NAME MCP_URL

source "$(dirname "$0")/stage6-common.sh"

# --- Step 2: Decimate for game-ready poly count ---
#
# Vertex targets tuned for Trellis2 baked UV preservation (Godot 4 PC budget).
# Decimating below 50K destroys Trellis2 UV fidelity regardless of asset type.
#   creature: 150000 verts — high-detail baked textures, needs UV headroom
#   humanoid:  15000 verts — skeletal deformation with CHORD PBR (not baked UVs)
#   prop:     100000 verts — static/simple, baked textures
#   weapon:    50000 verts — static, minimum for UV fidelity
# Override with TARGET_VERTS env var.

ASSET_TYPE="${ASSET_TYPE:-creature}"

case "${ASSET_TYPE}" in
    humanoid) DEFAULT_TARGET=15000 ;;
    creature) DEFAULT_TARGET=150000 ;;
    prop)     DEFAULT_TARGET=100000 ;;
    weapon)   DEFAULT_TARGET=50000 ;;
    *)        DEFAULT_TARGET=150000 ;;
esac

DECIMATE_TARGET="${TARGET_VERTS:-$DEFAULT_TARGET}"

echo "── Step 2: Decimate mesh (target: ${DECIMATE_TARGET} verts, type: ${ASSET_TYPE}) ──"

DECIMATE_CODE=$(cat <<PYEOF
import bpy, bmesh
from mathutils import Vector

target_verts = ${DECIMATE_TARGET}
mesh_objects = [obj for obj in bpy.context.scene.objects if obj.type == 'MESH']

# Distribute target proportionally across meshes
total_verts_all = sum(len(obj.data.vertices) for obj in mesh_objects)
for obj in mesh_objects:
    bpy.context.view_layer.objects.active = obj

    verts_before = len(obj.data.vertices)
    # Each mesh gets a proportional share of the total target
    obj_target = max(500, int(target_verts * (verts_before / total_verts_all))) if total_verts_all > 0 else target_verts

    # Pre-pass: limited dissolve to collapse co-planar faces.
    # Collapse decimate alone hits a floor on Trellis2 triangle soups (~8% of original).
    # Limited dissolve merges flat regions while preserving UVs.
    if verts_before > obj_target * 2:
        bpy.ops.object.mode_set(mode='EDIT')
        bpy.ops.mesh.select_all(action='SELECT')
        bpy.ops.mesh.dissolve_limited(angle_limit=0.03)
        bpy.ops.object.mode_set(mode='OBJECT')
        after_dissolve = len(obj.data.vertices)
        if after_dissolve < verts_before:
            print(f"  dissolve_limited: {verts_before} -> {after_dissolve}")

    # Iterative collapse decimation
    max_passes = 10
    for pass_num in range(max_passes):
        current_verts = len(obj.data.vertices)
        if current_verts <= obj_target * 1.1:
            break
        # Trellis2 meshes shred if we collapse from ~300K verts straight to ~15K
        # in a single pass. Keep each pass relatively gentle, then iterate.
        target_ratio = min(0.95, float(obj_target) / current_verts)
        if current_verts > obj_target * 3.0:
            target_ratio = max(target_ratio, 0.45)
        elif current_verts > obj_target * 1.8:
            target_ratio = max(target_ratio, 0.35)
        else:
            target_ratio = max(target_ratio, 0.10)
        mod = obj.modifiers.new(name="Decimate", type='DECIMATE')
        mod.ratio = target_ratio
        bpy.ops.object.modifier_apply(modifier=mod.name)

    # Prune small disconnected debris (floating panels, floor chips) after decimation.
    # Keep the main island and any substantial nearby islands; drop tiny distant islands.
    bpy.ops.object.mode_set(mode='EDIT')
    bm = bmesh.from_edit_mesh(obj.data)
    bm.faces.ensure_lookup_table()
    all_faces = set(bm.faces)
    islands = []
    while all_faces:
        seed = all_faces.pop()
        stack = [seed]
        island = {seed}
        while stack:
            face = stack.pop()
            for edge in face.edges:
                for linked in edge.link_faces:
                    if linked in all_faces:
                        all_faces.remove(linked)
                        island.add(linked)
                        stack.append(linked)
        islands.append(island)

    if islands:
        island_stats = []
        for island in islands:
            centers = [face.calc_center_median() for face in island]
            cx = sum(c.x for c in centers) / len(centers)
            cy = sum(c.y for c in centers) / len(centers)
            cz = sum(c.z for c in centers) / len(centers)
            island_stats.append({
                'faces': island,
                'count': len(island),
                'center': Vector((cx, cy, cz)),
            })

        island_stats.sort(key=lambda entry: entry['count'], reverse=True)
        largest = island_stats[0]
        largest_count = largest['count']
        max_span = max(obj.dimensions.x, obj.dimensions.y, obj.dimensions.z, 0.001)
        min_keep_faces = max(100, int(largest_count * 0.04))
        max_keep_distance = max_span * 0.35

        delete_faces = []
        for entry in island_stats[1:]:
            center_dist = (entry['center'] - largest['center']).length
            if entry['count'] < min_keep_faces and center_dist > max_keep_distance:
                delete_faces.extend(entry['faces'])

        for face in bm.faces:
            face.select = False
        for face in delete_faces:
            if face.is_valid:
                face.select = True
        if delete_faces:
            bmesh.update_edit_mesh(obj.data)
            bpy.ops.mesh.delete(type='FACE')
    bpy.ops.object.mode_set(mode='OBJECT')

    verts_after = len(obj.data.vertices)
    print(f"  {obj.name}: {verts_before} → {verts_after} verts")

total_verts = sum(len(obj.data.vertices) for obj in mesh_objects)
print(f"Total after decimation: {total_verts} verts")
PYEOF
)

RESP=$(run_blender_code "$DECIMATE_CODE")
if ! check_mcp_error "$RESP" "Decimate"; then exit 1; fi
echo "  ✅ Decimated"

# --- Step 2b: Apply real-world scale ---
#
# Trellis2 normalizes all output to ~1 unit bounding box. Scale to real-world
# dimensions based on asset type for correct relative sizing in Godot.
# Override with TARGET_HEIGHT env var.

case "${ASSET_TYPE}" in
    humanoid) DEFAULT_HEIGHT=1.75 ;;
    creature) DEFAULT_HEIGHT=1.0 ;;
    prop)     DEFAULT_HEIGHT=0.8 ;;
    weapon)   DEFAULT_HEIGHT=1.0 ;;
    *)        DEFAULT_HEIGHT=1.0 ;;
esac

TARGET_HEIGHT="${TARGET_HEIGHT:-$DEFAULT_HEIGHT}"

echo "── Step 2b: Scale to real-world size (target: ${TARGET_HEIGHT}m) ──"

SCALE_CODE=$(cat <<PYEOF
import bpy

target_height = ${TARGET_HEIGHT}

mesh_objects = [obj for obj in bpy.context.scene.objects if obj.type == 'MESH']
if not mesh_objects:
    print("SCALE_SKIP=no_mesh")
else:
    # Find overall bounding box of all meshes
    all_z = []
    for obj in mesh_objects:
        mw = obj.matrix_world
        for v in obj.data.vertices:
            all_z.append((mw @ v.co).z)

    current_height = max(all_z) - min(all_z) if all_z else 1.0
    if current_height < 0.001:
        current_height = 1.0

    scale_factor = target_height / current_height

    # Scale all objects uniformly
    for obj in mesh_objects:
        obj.scale *= scale_factor
    for obj in mesh_objects:
        bpy.context.view_layer.objects.active = obj
        obj.select_set(True)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    for obj in mesh_objects:
        obj.select_set(False)

    print(f"SCALE_APPLIED factor={scale_factor:.4f} from={current_height:.4f} to={target_height:.4f}")
PYEOF
)

RESP=$(run_blender_code "$SCALE_CODE")
if ! check_mcp_error "$RESP" "Scale"; then
    echo "  ⚠ Scale application failed (non-fatal, continuing)"
else
    echo "  ✅ Scaled to ${TARGET_HEIGHT}m"
fi

# --- Step 2c: Normal smoothing ---
#
# Trellis2 meshes have fragmented UV islands with independently calculated vertex
# normals. At UV seam boundaries, vertices sharing a position but belonging to
# different islands get divergent normals (up to 180° apart). This causes visible
# shading discontinuities ("blotchy overlay") that shift with lighting/animation.
#
# Fix: clear any custom split normals, apply smooth shading, then explicitly
# average normals at shared vertex positions so normals are continuous across
# UV seams. Applied AFTER decimation+scaling since both operations change geometry.

echo "── Step 2c: Normal smoothing (cross-seam averaging) ──"

SMOOTH_CODE=$(cat <<PYEOF
import bpy
import numpy as np
from collections import defaultdict

mesh_objects = [obj for obj in bpy.context.scene.objects if obj.type == 'MESH']

for obj in mesh_objects:
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    mesh = obj.data

    # Clear custom split normals from Trellis2
    if mesh.has_custom_normals:
        bpy.ops.mesh.customdata_custom_splitnormals_clear()

    bpy.ops.object.shade_smooth()

    # Compute area-weighted face normals per vertex
    verts = np.array([v.co[:] for v in mesh.vertices])
    face_normals = np.array([p.normal[:] for p in mesh.polygons])
    face_areas = np.array([p.area for p in mesh.polygons])

    vert_face_map = defaultdict(list)
    for fi, poly in enumerate(mesh.polygons):
        for vi in poly.vertices:
            vert_face_map[vi].append(fi)

    avg_normals = np.zeros((len(verts), 3), dtype=np.float64)
    for vi in range(len(verts)):
        faces = vert_face_map[vi]
        if faces:
            weights = face_areas[faces]
            weighted = face_normals[faces] * weights[:, np.newaxis]
            avg = weighted.sum(axis=0)
            length = np.linalg.norm(avg)
            avg_normals[vi] = avg / length if length > 1e-8 else np.array([0, 0, 1])

    # Average normals across shared positions (the key fix for UV seam boundaries)
    pos_rounded = np.round(verts, 5)
    pos_to_indices = defaultdict(list)
    for idx in range(len(verts)):
        pos_to_indices[tuple(pos_rounded[idx])].append(idx)

    shared_count = 0
    for indices in pos_to_indices.values():
        if len(indices) > 1:
            combined = avg_normals[indices].mean(axis=0)
            length = np.linalg.norm(combined)
            if length > 1e-8:
                combined /= length
            for idx in indices:
                avg_normals[idx] = combined
            shared_count += 1

    # Apply as custom split normals
    loop_normals = [tuple(avg_normals[loop.vertex_index]) for loop in mesh.loops]
    mesh.normals_split_custom_set(loop_normals)
    mesh.update()

    obj.select_set(False)
    print(f"SMOOTH {obj.name}: {len(verts)} verts, {shared_count} positions averaged, {len(loop_normals)} loops")

print("SMOOTH_DONE")
PYEOF
)

RESP=$(run_blender_code "$SMOOTH_CODE")
if ! check_mcp_error "$RESP" "Normal smoothing"; then
    echo "  ⚠ Normal smoothing failed (non-fatal, continuing)"
else
    echo "  ✅ Normals smoothed (cross-seam averaged)"
fi
