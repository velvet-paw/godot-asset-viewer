#!/usr/bin/env bash
# stage6e-export.sh — Export final GLB, LODs, collision
# Steps 6, 7, 8 of the Blender post-processing pipeline.
#
# Usage: ./stage6e-export.sh [glb_filename] [asset_name] [mcp_url]
# Env: GENERATE_LODS, GENERATE_COLLISION, ASSET_TYPE, T0 (start time for timing)

set -euo pipefail

GLB_INPUT="${1:-${GLB_INPUT:-asset_00001_.glb}}"
ASSET_NAME="${2:-${ASSET_NAME:-asset}}"
MCP_URL="${3:-${MCP_URL:-http://localhost:8000}}"
export GLB_INPUT ASSET_NAME MCP_URL

source "$(dirname "$0")/stage6-common.sh"

# --- Step 6: Apply transforms and export final GLB ---

echo "── Step 6: Export final GLB ──"

EXPORT_CODE=$(cat <<PYEOF
import bpy
import os

output_dir = "${FINAL_DIR}"
asset_name = "${ASSET_NAME}"
output_path = os.path.join(output_dir, f"{asset_name}_final.glb")

os.makedirs(output_dir, exist_ok=True)

# Pre-export cleanup: remove orphan objects (only keep main mesh + armature)
armatures = [obj for obj in bpy.context.scene.objects if obj.type == 'ARMATURE']
mesh_objects = [obj for obj in bpy.context.scene.objects if obj.type == 'MESH']

main_mesh = None
if armatures:
    for m in mesh_objects:
        if m.parent and m.parent.type == 'ARMATURE':
            main_mesh = m
            break
if main_mesh is None and mesh_objects:
    main_mesh = max(mesh_objects, key=lambda o: len(o.data.vertices))

keep = set()
if main_mesh:
    keep.add(main_mesh.name)
    if main_mesh.parent:
        keep.add(main_mesh.parent.name)
if armatures and not any(a.name in keep for a in armatures):
    keep.add(armatures[0].name)

for obj in list(bpy.context.scene.objects):
    if obj.name not in keep:
        bpy.data.objects.remove(obj, do_unlink=True)

# Select everything remaining for export
bpy.ops.object.select_all(action='SELECT')
armatures = [obj for obj in bpy.context.scene.objects if obj.type == 'ARMATURE']

if armatures:
    bpy.ops.export_scene.gltf(
        filepath=output_path,
        export_format='GLB',
        use_selection=True,
        export_apply=False,
        export_skins=True,
        export_animations=True,
        export_rest_position_armature=True,
    )
else:
    mesh_objects = [obj for obj in bpy.context.scene.objects if obj.type == 'MESH']
    for obj in mesh_objects:
        bpy.context.view_layer.objects.active = obj
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    bpy.ops.export_scene.gltf(
        filepath=output_path,
        export_format='GLB',
        use_selection=True,
        export_apply=True,
    )

size = os.path.getsize(output_path)
has_skin = "rigged" if armatures else "static"
obj_count = len(bpy.context.scene.objects)
print(f"Exported: {output_path} ({size} bytes, {has_skin}, {obj_count} objects)")
PYEOF
)

RESP=$(run_blender_code "$EXPORT_CODE")
if ! check_mcp_error "$RESP" "Export"; then exit 1; fi

T1=$(date +%s)
DT=$((T1 - ${T0:-$T1}))

# Validate output exists on host
HOST_OUTPUT="$HOME/assets/final_glb/${ASSET_NAME}_final.glb"
if [ -f "$HOST_OUTPUT" ]; then
    SIZE=$(stat -c%s "$HOST_OUTPUT" 2>/dev/null || echo "0")
    echo "  ✅ ${HOST_OUTPUT} (${SIZE} bytes)"
    echo "Stage 6 PASSED (${DT}s)"
else
    echo "  ❌ Output GLB not found at ${HOST_OUTPUT}"
    exit 1
fi

# --- Step 7: LOD chain generation (optional) ---
#
# Produce LOD1 and LOD2 meshes at lower vertex counts for Godot LODGroup.
# Enabled with GENERATE_LODS=1. Exports {asset}_lod1.glb and {asset}_lod2.glb.

if [[ "${GENERATE_LODS:-0}" == "1" ]]; then
    echo ""
    echo "── Step 7: LOD chain generation ──"

    case "${ASSET_TYPE}" in
        humanoid) LOD1_TARGET=7500; LOD2_TARGET=3750 ;;
        creature) LOD1_TARGET=75000; LOD2_TARGET=37500 ;;
        prop)     LOD1_TARGET=50000; LOD2_TARGET=25000 ;;
        weapon)   LOD1_TARGET=25000; LOD2_TARGET=12500 ;;
        *)        LOD1_TARGET=75000; LOD2_TARGET=37500 ;;
    esac

    LOD_CODE=$(cat <<PYEOF
import bpy, os

output_dir = "${FINAL_DIR}"
asset_name = "${ASSET_NAME}"
lod_targets = [(1, ${LOD1_TARGET}), (2, ${LOD2_TARGET})]

# Work on a copy of the scene for each LOD
mesh_objects = [obj for obj in bpy.context.scene.objects if obj.type == 'MESH']
if not mesh_objects:
    print("LOD_SKIP=no_mesh")
else:
    main_mesh = mesh_objects[0]
    for lod_level, lod_target in lod_targets:
        # Duplicate the main mesh
        bpy.ops.object.select_all(action='DESELECT')
        main_mesh.select_set(True)
        bpy.context.view_layer.objects.active = main_mesh
        bpy.ops.object.duplicate()
        lod_obj = bpy.context.active_object
        lod_obj.name = f"{asset_name}_lod{lod_level}"

        # Remove armature parent and modifiers from LOD copy
        lod_obj.parent = None
        for mod in list(lod_obj.modifiers):
            lod_obj.modifiers.remove(mod)

        # Decimate LOD via collapse decimation (preserves UV mapping).
        # Voxel remesh was previously used but destroys UVs, causing shiny
        # metallic artifacts when the metallicRoughness texture is sampled
        # from incorrect UV coordinates on the simplified mesh.
        bpy.context.view_layer.objects.active = lod_obj
        current_verts = len(lod_obj.data.vertices)
        if current_verts > lod_target * 1.1:
            ratio = float(lod_target) / current_verts
            mod = lod_obj.modifiers.new(name="Decimate", type='DECIMATE')
            mod.ratio = max(0.05, ratio)
            bpy.ops.object.modifier_apply(modifier=mod.name)

        final_verts = len(lod_obj.data.vertices)

        # Export LOD
        lod_path = os.path.join(output_dir, f"{asset_name}_lod{lod_level}.glb")
        bpy.ops.object.select_all(action='DESELECT')
        lod_obj.select_set(True)
        bpy.ops.export_scene.gltf(
            filepath=lod_path,
            export_format='GLB',
            use_selection=True,
            export_apply=True,
        )

        # Remove the LOD copy from the scene
        bpy.data.objects.remove(lod_obj, do_unlink=True)
        print(f"  LOD{lod_level}: {final_verts} verts → {lod_path}")

    print("LOD_GENERATED=2")
PYEOF
    )

    RESP=$(run_blender_code "$LOD_CODE")
    if ! check_mcp_error "$RESP" "LOD generation"; then
        echo "  ⚠ LOD generation failed (non-fatal)"
    else
        echo "  ✅ LOD1 (${LOD1_TARGET}v) + LOD2 (${LOD2_TARGET}v) exported"
    fi
fi

# --- Step 8: Collision mesh generation (optional) ---
#
# Produce a convex hull collision mesh with Godot's -col suffix.
# Enabled with GENERATE_COLLISION=1. Exports inside the main GLB or as separate.

if [[ "${GENERATE_COLLISION:-0}" == "1" ]]; then
    echo ""
    echo "── Step 8: Collision mesh generation ──"

    COLLISION_CODE=$(cat <<PYEOF
import bpy, bmesh, os

output_dir = "${FINAL_DIR}"
asset_name = "${ASSET_NAME}"

mesh_objects = [obj for obj in bpy.context.scene.objects if obj.type == 'MESH']
if not mesh_objects:
    print("COLLISION_SKIP=no_mesh")
else:
    main_mesh = mesh_objects[0]

    # Duplicate for collision
    bpy.ops.object.select_all(action='DESELECT')
    main_mesh.select_set(True)
    bpy.context.view_layer.objects.active = main_mesh
    bpy.ops.object.duplicate()
    col_obj = bpy.context.active_object
    col_obj.name = f"{asset_name}-col"

    # Remove parent and modifiers
    col_obj.parent = None
    for mod in list(col_obj.modifiers):
        col_obj.modifiers.remove(mod)

    # Remove all materials (collision doesn't need them)
    col_obj.data.materials.clear()

    # Aggressive decimation first
    current_verts = len(col_obj.data.vertices)
    if current_verts > 500:
        mod = col_obj.modifiers.new(name="Decimate", type='DECIMATE')
        mod.ratio = max(0.02, 500.0 / current_verts)
        bpy.context.view_layer.objects.active = col_obj
        bpy.ops.object.modifier_apply(modifier=mod.name)

    # Convex hull
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.convex_hull()
    bpy.ops.object.mode_set(mode='OBJECT')

    final_verts = len(col_obj.data.vertices)

    # Export collision mesh
    col_path = os.path.join(output_dir, f"{asset_name}-col.glb")
    bpy.ops.object.select_all(action='DESELECT')
    col_obj.select_set(True)
    bpy.ops.export_scene.gltf(
        filepath=col_path,
        export_format='GLB',
        use_selection=True,
        export_apply=True,
    )

    # Remove collision copy from scene
    bpy.data.objects.remove(col_obj, do_unlink=True)
    print(f"COLLISION_GENERATED verts={final_verts} path={col_path}")
PYEOF
    )

    RESP=$(run_blender_code "$COLLISION_CODE")
    if ! check_mcp_error "$RESP" "Collision mesh"; then
        echo "  ⚠ Collision mesh generation failed (non-fatal)"
    else
        echo "  ✅ Collision mesh exported (convex hull)"
    fi
fi
