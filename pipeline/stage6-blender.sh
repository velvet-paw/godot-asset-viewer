#!/usr/bin/env bash
# test-stage6-blender.sh — Blender post-processing via MCP
#
# Imports a raw GLB, decimates, UV unwraps, applies PBR maps, and
# exports a final game-ready GLB — all via the Blender MCP server.
#
# Usage: ./test-stage6-blender.sh [glb_filename] [asset_name] [mcp_url]

set -euo pipefail

GLB_INPUT="${1:-asset_00001_.glb}"
ASSET_NAME="${2:-asset}"
MCP_URL="${3:-http://localhost:8000}"

RAW_3D_DIR="/assets/raw_3d"
PBR_DIR="/assets/pbr_maps"
FINAL_DIR="/assets/final_glb"

echo "=== Stage 6: Blender Post-Processing (MCP) ==="
echo "MCP:   $MCP_URL"
echo "Input: $GLB_INPUT"
echo "Asset: $ASSET_NAME"

MCP_SESSION_ID=""

# --- MCP helpers (same pattern as test-mcp-e2e.sh) ---

init_mcp_session() {
    local request_body
    request_body=$(cat <<EOF
{
  "jsonrpc": "2.0",
  "id": 0,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-03-26",
    "capabilities": {},
    "clientInfo": {
      "name": "stage6-test",
      "version": "1.0.0"
    }
  }
}
EOF
    )

    local tmpheaders
    tmpheaders=$(mktemp)

    curl -sf --max-time 10 \
        -D "$tmpheaders" \
        -o /dev/null \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d "$request_body" \
        "${MCP_URL}/mcp" 2>/dev/null || true

    MCP_SESSION_ID=$(grep -i 'mcp-session-id' "$tmpheaders" 2>/dev/null | tr -d '\r' | awk '{print $2}')
    rm -f "$tmpheaders"
}

call_mcp_tool() {
    local tool_name="$1"
    shift
    local arguments="${1:-\{\}}"

    local request_body
    request_body=$(cat <<EOF
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "${tool_name}",
    "arguments": ${arguments}
  }
}
EOF
    )

    local session_hdr=""
    if [[ -n "$MCP_SESSION_ID" ]]; then
        session_hdr="-H"
    fi

    local response
    response=$(curl -sf --max-time 120 \
        -X POST \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        ${session_hdr:+"$session_hdr"} ${MCP_SESSION_ID:+"Mcp-Session-Id: $MCP_SESSION_ID"} \
        -d "$request_body" \
        "${MCP_URL}/mcp" 2>/dev/null \
    | grep '^data: ' | sed 's/^data: //')

    echo "$response"
}

run_blender_code() {
    local code="$1"
    local arguments
    arguments="{\"code\": $(echo "$code" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}"
    call_mcp_tool "execute_blender_code" "$arguments"
}

check_mcp_error() {
    local response="$1"
    local step="$2"
    # Check both isError flag AND error text (MCP server often returns isError:false with error text)
    if echo "$response" | grep -qi '"isError":\s*true' || \
       echo "$response" | grep -qi 'Error executing code:'; then
        echo "  ❌ $step FAILED"
        echo "$response" | python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        data = json.loads(line)
        result = data.get('result', {})
        for item in result.get('content', []):
            print('    ', item.get('text', '')[:200])
    except: print('    ', line[:200])
" 2>/dev/null || echo "$response" | head -5
        return 1
    fi
    return 0
}

# --- Health check ---

echo ""
echo "── Checking Blender MCP server ──"
if curl -sf --max-time 30 "${MCP_URL}/mcp" -X POST \
     -H "Content-Type: application/json" \
     -H "Accept: application/json, text/event-stream" \
     -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
     2>/dev/null | grep -q '^data: '; then
    echo "  ✅ MCP server reachable"
else
    echo "  ❌ MCP server unreachable at $MCP_URL"
    exit 1
fi

init_mcp_session
echo ""

# --- Step 1: Clear scene and import GLB ---

echo "── Step 1: Import raw GLB ──"
T0=$(date +%s)

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

# --- Step 3 & 4: UV Unwrap + PBR ---
#
# Trellis2 GLBs include baked textures with matching UVs. Re-projecting UVs
# or applying CHORD PBR maps (which are in 2D concept-art space) destroys
# the Trellis2 texture alignment. We detect existing textures and skip both
# steps when they're present; otherwise we UV unwrap and apply full PBR.

TEXTURE_CHECK_CODE=$(cat <<'PYEOF'
import bpy

mesh_objects = [obj for obj in bpy.context.scene.objects if obj.type == 'MESH']
has_textures = False
for obj in mesh_objects:
    for mat_slot in obj.material_slots:
        mat = mat_slot.material
        if mat and mat.use_nodes:
            for node in mat.node_tree.nodes:
                if node.type == 'TEX_IMAGE' and node.image:
                    has_textures = True
                    break

result = 'true' if has_textures else 'false'
print("HAS_TEXTURES=" + result)
PYEOF
)

RESP=$(run_blender_code "$TEXTURE_CHECK_CODE")
HAS_TEXTURES=$(echo "$RESP" | { grep -oiP 'HAS_TEXTURES=\K[a-zA-Z]+' || true; } | head -1 | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

FORCE_PBR="${FORCE_PBR:-0}"
if [[ "$HAS_TEXTURES" == "true" && "$FORCE_PBR" != "1" ]]; then
    echo "── Step 3: Smart UV Project ──"
    echo "  ⏭ Skipped (Trellis2 baked UVs preserved)"
    echo "── Step 4: Apply PBR maps ──"
    echo "  ⏭ Skipped (Trellis2 baked textures preserved)"
else
    if [[ "$HAS_TEXTURES" == "true" && "$FORCE_PBR" == "1" ]]; then
        echo "  ⚠ FORCE_PBR=1: stripping Trellis2 textures, applying fresh UV + CHORD PBR"
        STRIP_TEX_CODE=$(cat <<'PYEOF'
import bpy
for obj in bpy.context.scene.objects:
    if obj.type == 'MESH':
        for mat_slot in obj.material_slots:
            mat = mat_slot.material
            if mat and mat.use_nodes:
                for node in list(mat.node_tree.nodes):
                    if node.type == 'TEX_IMAGE':
                        mat.node_tree.nodes.remove(node)
print("Stripped baked textures from all meshes")
PYEOF
        )
        RESP=$(run_blender_code "$STRIP_TEX_CODE")
        echo "  ✅ Baked textures stripped"
    fi
    UV_METHOD="${UV_METHOD:-smart}"
    echo "── Step 3: UV Project (method: ${UV_METHOD}) ──"

    if [[ "$UV_METHOD" == "camera" ]]; then
        # Camera-based UV projection via math (works headless).
        # Projects UVs from a virtual camera matching the concept art's
        # three-quarter front view angle.
        UV_CODE=$(cat <<'PYEOF'
import bpy, math
from mathutils import Vector, Matrix

mesh_objects = [obj for obj in bpy.context.scene.objects if obj.type == 'MESH']
if not mesh_objects:
    print("No mesh objects found")
else:
    # Compute mesh bounds
    all_verts = []
    for obj in mesh_objects:
        for v in obj.data.vertices:
            all_verts.append(obj.matrix_world @ v.co)

    min_co = Vector((min(v[i] for v in all_verts) for i in range(3)))
    max_co = Vector((max(v[i] for v in all_verts) for i in range(3)))
    center = (min_co + max_co) / 2
    size = max_co - min_co
    max_dim = max(size)

    # Camera setup: three-quarter front-left, slight elevation
    azimuth = math.radians(30)
    elevation = math.radians(15)
    dist = max_dim * 5

    cam_pos = Vector((
        center.x + dist * math.sin(azimuth) * math.cos(elevation),
        center.y - dist * math.cos(azimuth) * math.cos(elevation),
        center.z + dist * math.sin(elevation)
    ))

    # Build view matrix (orthographic projection)
    forward = (center - cam_pos).normalized()
    right = forward.cross(Vector((0, 0, 1))).normalized()
    up = right.cross(forward).normalized()

    for obj in mesh_objects:
        mesh = obj.data
        if not mesh.uv_layers:
            mesh.uv_layers.new(name="CameraProjection")
        uv_layer = mesh.uv_layers.active

        for poly in mesh.polygons:
            for loop_idx in poly.loop_indices:
                vert = obj.matrix_world @ mesh.vertices[mesh.loops[loop_idx].vertex_index].co
                # Project vertex onto camera plane
                rel = vert - center
                u = rel.dot(right) / max_dim + 0.5
                v = rel.dot(up) / max_dim + 0.5
                # Clamp to 0-1
                u = max(0.0, min(1.0, u))
                v = max(0.0, min(1.0, v))
                uv_layer.data[loop_idx].uv = (u, v)

        print(f"  Camera-projected UV: {obj.name}")
    print(f"Camera-projected {len(mesh_objects)} mesh(es)")
PYEOF
        )
    else
        UV_CODE=$(cat <<'PYEOF'
import bpy

mesh_objects = [obj for obj in bpy.context.scene.objects if obj.type == 'MESH']
for obj in mesh_objects:
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)

    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=66, island_margin=0.02)
    bpy.ops.object.mode_set(mode='OBJECT')

    obj.select_set(False)
    print(f"  UV unwrapped: {obj.name}")

print(f"UV unwrapped {len(mesh_objects)} mesh(es)")
PYEOF
        )
    fi

    RESP=$(run_blender_code "$UV_CODE")
    if ! check_mcp_error "$RESP" "UV Unwrap"; then exit 1; fi
    echo "  ✅ UV projected"

    echo "── Step 4: Apply PBR maps ──"

    PBR_CHANNELS="${PBR_CHANNELS:-all}"  # Comma-separated list: albedo,normal,roughness,metallic,height or "all"

    PBR_CODE=$(cat <<PYEOF
import bpy
import os

pbr_dir = "${PBR_DIR}"
asset_name = "${ASSET_NAME}"
pbr_channels_filter = "${PBR_CHANNELS}"

mesh_objects = [obj for obj in bpy.context.scene.objects if obj.type == 'MESH']

channels = {
    'albedo': ['basecolor', 'albedo', 'diffuse', 'base_color'],
    'normal': ['normal'],
    'roughness': ['roughness'],
    'metallic': ['metalness', 'metallic', 'metal'],
    'height': ['height', 'displacement', 'bump'],
}

# Filter channels if PBR_CHANNELS is specified
if pbr_channels_filter != "all":
    allowed = [c.strip() for c in pbr_channels_filter.split(',')]
    channels = {k: v for k, v in channels.items() if k in allowed}
    print(f"Filtered PBR channels to: {list(channels.keys())}")

pbr_files = {}
available = os.listdir(pbr_dir) if os.path.isdir(pbr_dir) else []

for channel, keywords in channels.items():
    for f in available:
        if not f.endswith('.png'):
            continue
        f_lower = f.lower()
        if any(kw in f_lower for kw in keywords):
            pbr_files[channel] = os.path.join(pbr_dir, f)
            break

print(f"Found PBR maps: {list(pbr_files.keys())}")

if not pbr_files:
    print("No PBR maps found, keeping existing materials")
else:
    mat = bpy.data.materials.new(name=f"{asset_name}_PBR")
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    links = mat.node_tree.links

    bsdf = nodes.get("Principled BSDF")
    if not bsdf:
        bsdf = nodes.new(type='ShaderNodeBsdfPrincipled')

    tex_y = 300
    for channel, filepath in pbr_files.items():
        tex_node = nodes.new(type='ShaderNodeTexImage')
        tex_node.location = (-400, tex_y)
        tex_y -= 300

        img = bpy.data.images.load(filepath)
        tex_node.image = img

        if channel == 'albedo':
            links.new(tex_node.outputs['Color'], bsdf.inputs['Base Color'])
        elif channel == 'normal':
            img.colorspace_settings.name = 'Non-Color'
            normal_map = nodes.new(type='ShaderNodeNormalMap')
            normal_map.location = (-200, tex_node.location.y)
            links.new(tex_node.outputs['Color'], normal_map.inputs['Color'])
            links.new(normal_map.outputs['Normal'], bsdf.inputs['Normal'])
        elif channel == 'roughness':
            img.colorspace_settings.name = 'Non-Color'
            links.new(tex_node.outputs['Color'], bsdf.inputs['Roughness'])
        elif channel == 'metallic':
            img.colorspace_settings.name = 'Non-Color'
            links.new(tex_node.outputs['Color'], bsdf.inputs['Metallic'])
        elif channel == 'height':
            img.colorspace_settings.name = 'Non-Color'
            disp_node = nodes.new(type='ShaderNodeDisplacement')
            disp_node.location = (-200, tex_node.location.y)
            disp_node.inputs['Scale'].default_value = 0.05
            links.new(tex_node.outputs['Color'], disp_node.inputs['Height'])
            output_node = nodes.get("Material Output")
            if output_node:
                links.new(disp_node.outputs['Displacement'], output_node.inputs['Displacement'])

        print(f"  Loaded {channel}: {os.path.basename(filepath)}")

    for obj in mesh_objects:
        obj.data.materials.clear()
        obj.data.materials.append(mat)

    print(f"Applied full PBR material to {len(mesh_objects)} mesh(es)")
PYEOF
    )

    RESP=$(run_blender_code "$PBR_CODE")
    if ! check_mcp_error "$RESP" "PBR Maps"; then exit 1; fi
    echo "  ✅ PBR maps applied"
fi

# --- Step 5: Auto-rigging for animation (Godot-compatible) ---
#
# Creates a skeleton armature for characters/creatures with Godot-compatible
# bone naming. Uses mesh bounding box analysis for bone placement and
# automatic weights for skinning. Skip for props/weapons or with SKIP_RIGGING=1.

if [[ "${SKIP_RIGGING:-0}" != "1" && ("${ASSET_TYPE}" == "humanoid" || "${ASSET_TYPE}" == "creature") ]]; then
    echo "── Step 5: Auto-rigging (${ASSET_TYPE}) ──"

# Step 5a: Mesh analysis + armature + bone creation
RIG_ARMATURE_CODE=$(cat <<PYEOF
import bpy
from mathutils import Vector

asset_type = "${ASSET_TYPE}"

mesh_objects = [obj for obj in bpy.context.scene.objects if obj.type == 'MESH']
if not mesh_objects:
    print("RIG_SKIP=no_mesh")
else:
    if len(mesh_objects) > 1:
        bpy.ops.object.select_all(action='DESELECT')
        for obj in mesh_objects:
            obj.select_set(True)
        bpy.context.view_layer.objects.active = mesh_objects[0]
        bpy.ops.object.join()
        mesh_objects = [bpy.context.active_object]

    obj = mesh_objects[0]
    bpy.context.view_layer.objects.active = obj

    mw = obj.matrix_world
    verts_world = [mw @ v.co for v in obj.data.vertices]
    xs = [v.x for v in verts_world]
    ys = [v.y for v in verts_world]
    zs = [v.z for v in verts_world]

    z_min, z_max = min(zs), max(zs)
    x_min, x_max = min(xs), max(xs)
    y_min, y_max = min(ys), max(ys)
    height = z_max - z_min
    width = x_max - x_min
    depth = y_max - y_min
    cx = (x_min + x_max) / 2
    cy = (y_min + y_max) / 2
    margin = 0.02

    def clamp(pos):
        return (
            max(x_min - margin, min(x_max + margin, pos[0])),
            max(y_min - margin, min(y_max + margin, pos[1])),
            max(z_min - margin, min(z_max + margin, pos[2])),
        )

    arm_data = bpy.data.armatures.new(name="Armature")
    arm_obj = bpy.data.objects.new("Armature", arm_data)
    bpy.context.scene.collection.objects.link(arm_obj)
    bpy.context.view_layer.objects.active = arm_obj
    bpy.ops.object.mode_set(mode='EDIT')

    if asset_type == "humanoid":
        bone_defs = [
            ("hips",           clamp((cx, cy, z_min + height*0.45)), clamp((cx, cy, z_min + height*0.50))),
            ("spine",          clamp((cx, cy, z_min + height*0.50)), clamp((cx, cy, z_min + height*0.60))),
            ("chest",          clamp((cx, cy, z_min + height*0.60)), clamp((cx, cy, z_min + height*0.72))),
            ("neck",           clamp((cx, cy, z_min + height*0.72)), clamp((cx, cy, z_min + height*0.82))),
            ("head",           clamp((cx, cy, z_min + height*0.82)), clamp((cx, cy, z_min + height*0.98))),
            ("left_shoulder",  clamp((cx + width*0.08, cy, z_min + height*0.71)), clamp((cx + width*0.20, cy, z_min + height*0.70))),
            ("left_upper_arm", clamp((cx + width*0.20, cy, z_min + height*0.70)), clamp((cx + width*0.35, cy, z_min + height*0.65))),
            ("left_lower_arm", clamp((cx + width*0.35, cy, z_min + height*0.65)), clamp((cx + width*0.45, cy, z_min + height*0.55))),
            ("left_hand",      clamp((cx + width*0.45, cy, z_min + height*0.55)), clamp((cx + width*0.50, cy, z_min + height*0.50))),
            ("right_shoulder", clamp((cx - width*0.08, cy, z_min + height*0.71)), clamp((cx - width*0.20, cy, z_min + height*0.70))),
            ("right_upper_arm",clamp((cx - width*0.20, cy, z_min + height*0.70)), clamp((cx - width*0.35, cy, z_min + height*0.65))),
            ("right_lower_arm",clamp((cx - width*0.35, cy, z_min + height*0.65)), clamp((cx - width*0.45, cy, z_min + height*0.55))),
            ("right_hand",     clamp((cx - width*0.45, cy, z_min + height*0.55)), clamp((cx - width*0.50, cy, z_min + height*0.50))),
            ("left_upper_leg", clamp((cx + width*0.10, cy, z_min + height*0.45)), clamp((cx + width*0.10, cy, z_min + height*0.25))),
            ("left_lower_leg", clamp((cx + width*0.10, cy, z_min + height*0.25)), clamp((cx + width*0.10, cy, z_min + height*0.05))),
            ("left_foot",      clamp((cx + width*0.10, cy, z_min + height*0.05)), clamp((cx + width*0.10, cy - depth*0.15, z_min))),
            ("left_toe",       clamp((cx + width*0.10, cy - depth*0.15, z_min)), clamp((cx + width*0.10, cy - depth*0.25, z_min))),
            ("right_upper_leg",clamp((cx - width*0.10, cy, z_min + height*0.45)), clamp((cx - width*0.10, cy, z_min + height*0.25))),
            ("right_lower_leg",clamp((cx - width*0.10, cy, z_min + height*0.25)), clamp((cx - width*0.10, cy, z_min + height*0.05))),
            ("right_foot",     clamp((cx - width*0.10, cy, z_min + height*0.05)), clamp((cx - width*0.10, cy - depth*0.15, z_min))),
            ("right_toe",      clamp((cx - width*0.10, cy - depth*0.15, z_min)), clamp((cx - width*0.10, cy - depth*0.25, z_min))),
        ]
        parents = {
            "spine": "hips", "chest": "spine", "neck": "chest", "head": "neck",
            "left_shoulder": "chest", "left_upper_arm": "left_shoulder", "left_lower_arm": "left_upper_arm", "left_hand": "left_lower_arm",
            "right_shoulder": "chest", "right_upper_arm": "right_shoulder", "right_lower_arm": "right_upper_arm", "right_hand": "right_lower_arm",
            "left_upper_leg": "hips", "left_lower_leg": "left_upper_leg", "left_foot": "left_lower_leg", "left_toe": "left_foot",
            "right_upper_leg": "hips", "right_lower_leg": "right_upper_leg", "right_foot": "right_lower_leg", "right_toe": "right_foot",
        }
    else:
        bone_defs = [
            ("hips",           clamp((cx, cy, z_min + height*0.45)), clamp((cx, cy, z_min + height*0.55))),
            ("spine",          clamp((cx, cy, z_min + height*0.55)), clamp((cx, cy, z_min + height*0.65))),
            ("chest",          clamp((cx, cy, z_min + height*0.65)), clamp((cx, cy, z_min + height*0.75))),
            ("neck",           clamp((cx, cy, z_min + height*0.75)), clamp((cx, cy, z_min + height*0.85))),
            ("head",           clamp((cx, cy, z_min + height*0.85)), clamp((cx, cy, z_min + height*0.98))),
            ("tail_base",      clamp((cx, cy + depth*0.15, z_min + height*0.40)), clamp((cx, cy + depth*0.30, z_min + height*0.35))),
            ("tail_mid",       clamp((cx, cy + depth*0.30, z_min + height*0.35)), clamp((cx, cy + depth*0.40, z_min + height*0.30))),
            ("tail_tip",       clamp((cx, cy + depth*0.40, z_min + height*0.30)), clamp((cx, cy + depth*0.50, z_min + height*0.25))),
            ("left_front_leg", clamp((cx + width*0.15, cy - depth*0.10, z_min + height*0.55)), clamp((cx + width*0.15, cy - depth*0.10, z_min + height*0.05))),
            ("right_front_leg",clamp((cx - width*0.15, cy - depth*0.10, z_min + height*0.55)), clamp((cx - width*0.15, cy - depth*0.10, z_min + height*0.05))),
            ("left_back_leg",  clamp((cx + width*0.15, cy + depth*0.10, z_min + height*0.45)), clamp((cx + width*0.15, cy + depth*0.10, z_min + height*0.05))),
            ("right_back_leg", clamp((cx - width*0.15, cy + depth*0.10, z_min + height*0.45)), clamp((cx - width*0.15, cy + depth*0.10, z_min + height*0.05))),
        ]
        parents = {
            "spine": "hips", "chest": "spine", "neck": "chest", "head": "neck",
            "tail_base": "hips", "tail_mid": "tail_base", "tail_tip": "tail_mid",
            "left_front_leg": "chest", "right_front_leg": "chest",
            "left_back_leg": "hips", "right_back_leg": "hips",
        }

    bone_map = {}
    for bname, head_pos, tail_pos in bone_defs:
        bone = arm_data.edit_bones.new(bname)
        bone.head = Vector(head_pos)
        bone.tail = Vector(tail_pos)
        if (bone.tail - bone.head).length < 0.01:
            bone.tail = bone.head + Vector((0, 0, 0.02))
        bone_map[bname] = bone

    # Remove any default bones Blender auto-creates
    for bone in list(arm_data.edit_bones):
        if bone.name not in bone_map:
            arm_data.edit_bones.remove(bone)

    for child, parent in parents.items():
        if child in bone_map and parent in bone_map:
            bone_map[child].parent = bone_map[parent]

    bpy.ops.object.mode_set(mode='OBJECT')
    bone_count = len(arm_data.bones)
    print(f"ARMATURE_CREATED bones={bone_count}")
PYEOF
)

    RESP=$(run_blender_code "$RIG_ARMATURE_CODE")
    if ! check_mcp_error "$RESP" "Armature creation"; then
        echo "  ⚠ Armature creation failed (non-fatal, exporting without armature)"
    else
        BONE_COUNT=$(echo "$RESP" | { grep -oP 'bones=\K[0-9]+' || true; } | head -1)
        echo "  Armature: $BONE_COUNT bones created"

# Step 5b: Weight painting (region-aware fallback for reliability with Trellis2 meshes)
RIG_WEIGHTS_CODE=$(cat <<PYEOF
import bpy

asset_type = "${ASSET_TYPE}"

mesh_objects = [obj for obj in bpy.context.scene.objects if obj.type == 'MESH']
arm_objects = [obj for obj in bpy.context.scene.objects if obj.type == 'ARMATURE']
if not mesh_objects or not arm_objects:
    print("WEIGHT_SKIP=no_objects")
else:
    obj = mesh_objects[0]
    arm_obj = arm_objects[0]

    def segment_distance(point, head, tail):
        seg = tail - head
        seg_len_sq = seg.length_squared
        if seg_len_sq < 1e-6:
            return (point - head).length
        t = max(0.0, min(1.0, (point - head).dot(seg) / seg_len_sq))
        closest = head + (seg * t)
        return (point - closest).length

    # Clean mesh for better weight painting
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.mesh.remove_doubles(threshold=0.001)
    bpy.ops.mesh.normals_make_consistent(inside=False)
    bpy.ops.object.mode_set(mode='OBJECT')

    # Try automatic weights first
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    arm_obj.select_set(True)
    bpy.context.view_layer.objects.active = arm_obj

    auto_ok = False
    try:
        bpy.ops.object.parent_set(type='ARMATURE_AUTO')
        group_counts = {}
        total_weighted = 0
        for v in obj.data.vertices:
            if v.groups:
                best = max(v.groups, key=lambda g: g.weight)
                if best.weight > 0.01:
                    total_weighted += 1
                    gname = obj.vertex_groups[best.group].name
                    group_counts[gname] = group_counts.get(gname, 0) + 1
        total = len(obj.data.vertices)
        max_count = max(group_counts.values()) if group_counts else 0
        max_pct = max_count / total if total > 0 else 0
        weighted_pct = total_weighted / total if total > 0 else 0
        if weighted_pct < 0.5:
            print(f"SKIN_AUTO_FAILED=low_coverage weighted={total_weighted}/{total} ({weighted_pct:.2f})")
        elif max_pct < 0.40:
            auto_ok = True
            print(f"SKIN_METHOD=automatic max_pct={max_pct:.2f} coverage={weighted_pct:.2f}")
        else:
            top = max(group_counts, key=group_counts.get)
            print(f"SKIN_AUTO_CONCENTRATED top={top} pct={max_pct:.2f}")
    except RuntimeError as e:
        print(f"SKIN_AUTO_FAILED={e}")

    if not auto_ok:
        # Region-aware fallback for non-manifold Trellis2 meshes.
        # Global nearest-bone assignment makes torso/helmet geometry collapse onto
        # forearm bones, so we constrain each vertex to a coarse humanoid region first.
        for mod in list(obj.modifiers):
            if mod.type == 'ARMATURE':
                obj.modifiers.remove(mod)
        for vg in list(obj.vertex_groups):
            obj.vertex_groups.remove(vg)

        verts_world = [obj.matrix_world @ v.co for v in obj.data.vertices]
        xs = [v.x for v in verts_world]
        zs = [v.z for v in verts_world]
        x_min, x_max = min(xs), max(xs)
        z_min, z_max = min(zs), max(zs)
        width = max(x_max - x_min, 0.001)
        height = max(z_max - z_min, 0.001)
        cx = (x_min + x_max) / 2.0
        arm_side_split = max(width * 0.30, 0.10)
        arm_far_split = max(width * 0.36, 0.12)
        leg_side_split = max(width * 0.18, 0.06)
        torso_core = max(width * 0.14, 0.05)

        bone_segs = []
        bone_map = {}
        for bone in arm_obj.data.bones:
            head = arm_obj.matrix_world @ bone.head_local
            tail = arm_obj.matrix_world @ bone.tail_local
            bone_segs.append((bone.name, head, tail))
            bone_map[bone.name] = (head, tail)

        for bname, _, _ in bone_segs:
            obj.vertex_groups.new(name=bname)

        def normalized_t(value, start, end):
            span = end - start
            if span <= 1e-6:
                return 0.0
            return max(0.0, min(1.0, (value - start) / span))

        def chain_weights(t, names, first_split=0.5):
            t = max(0.0, min(1.0, t))
            if len(names) == 2:
                return [(names[0], 1.0 - t), (names[1], t)]
            if t < first_split:
                local = t / first_split
                return [(names[0], 1.0 - local), (names[1], local)]
            local = (t - first_split) / max(1e-6, 1.0 - first_split)
            return [(names[1], 1.0 - local), (names[2], local)]

        def apply_weights(vertex_index, pairs):
            total = sum(weight for _, weight in pairs if weight > 0.0)
            if total <= 1e-6:
                return
            for bname, weight in pairs:
                if weight <= 0.01:
                    continue
                vg = obj.vertex_groups.get(bname)
                if vg:
                    vg.add([vertex_index], weight / total, 'REPLACE')

        def candidate_bones(v_pos):
            return [name for name, _, _ in bone_segs]

        for v in obj.data.vertices:
            v_pos = obj.matrix_world @ v.co
            if asset_type == "humanoid":
                x_off = v_pos.x - cx
                abs_x = abs(x_off)
                z_rel = (v_pos.z - z_min) / height
                side = "left" if x_off >= 0 else "right"

                shoulder = f"{side}_shoulder"
                upper_arm = f"{side}_upper_arm"
                lower_arm = f"{side}_lower_arm"
                hand = f"{side}_hand"
                upper_leg = f"{side}_upper_leg"
                lower_leg = f"{side}_lower_leg"
                foot = f"{side}_foot"
                toe = f"{side}_toe"

                if z_rel >= 0.80:
                    apply_weights(v.index, chain_weights(normalized_t(z_rel, 0.80, 1.0), ["neck", "head"]))
                    continue

                if z_rel >= 0.62 and abs_x >= arm_side_split and upper_arm in bone_map and hand in bone_map:
                    start = bone_map[shoulder][0] if shoulder in bone_map else bone_map[upper_arm][0]
                    end = bone_map[hand][1]
                    t = normalized_t((v_pos - start).dot(end - start), 0.0, (end - start).length_squared)
                    if t < 0.10:
                        apply_weights(v.index, [("chest", 1.0 - (t / 0.10)), (shoulder, t / 0.10)])
                    elif t < 0.20:
                        local_t = (t - 0.10) / 0.10
                        apply_weights(v.index, [(shoulder, 1.0 - local_t), (upper_arm, local_t)])
                    else:
                        apply_weights(v.index, chain_weights(t, [upper_arm, lower_arm, hand], first_split=0.55))
                    continue

                if (z_rel < 0.30 or (z_rel < 0.45 and abs_x >= leg_side_split)) and upper_leg in bone_map and foot in bone_map:
                    start = bone_map[upper_leg][0]
                    end = bone_map[toe][1] if toe in bone_map else bone_map[foot][1]
                    t = normalized_t((v_pos - start).dot(end - start), 0.0, (end - start).length_squared)
                    if t < 0.15:
                        apply_weights(v.index, [("hips", 1.0 - (t / 0.15)), (upper_leg, t / 0.15)])
                    elif t > 0.90 and toe in bone_map:
                        local_t = (t - 0.90) / 0.10
                        apply_weights(v.index, [(foot, 1.0 - local_t), (toe, local_t)])
                    else:
                        apply_weights(v.index, chain_weights(t, [upper_leg, lower_leg, foot], first_split=0.55))
                    continue

                torso_t = normalized_t(z_rel, 0.30, 0.80)
                torso_pairs = chain_weights(torso_t, ["hips", "spine", "chest"], first_split=0.45)
                if z_rel >= 0.58 and abs_x >= torso_core and shoulder in bone_map:
                    shoulder_bias = min(0.20, max(0.0, (abs_x - torso_core) / max(1e-6, arm_side_split - torso_core)) * 0.20)
                    adjusted = []
                    for name, weight in torso_pairs:
                        if name == "chest":
                            adjusted.append((name, max(0.0, weight - shoulder_bias)))
                        else:
                            adjusted.append((name, weight))
                    adjusted.append((shoulder, shoulder_bias))
                    torso_pairs = adjusted
                apply_weights(v.index, torso_pairs)
                continue

            candidates = candidate_bones(v_pos)
            dists = []
            for bname in candidates:
                if bname not in bone_map:
                    continue
                head, tail = bone_map[bname]
                d = segment_distance(v_pos, head, tail)
                dists.append((d, bname))
            if not dists:
                for bname, head, tail in bone_segs:
                    dists.append((segment_distance(v_pos, head, tail), bname))
            dists.sort()
            top3 = dists[:3]
            inv = [1.0 / max(d, 0.001) for d, _ in top3]
            total_inv = sum(inv)
            apply_weights(v.index, [(bname, w / total_inv) for (d, bname), w in zip(top3, inv)])

        obj.parent = arm_obj
        obj.parent_type = 'ARMATURE'
        mod = obj.modifiers.new(name='Armature', type='ARMATURE')
        mod.object = arm_obj

        dominant = {}
        for v in obj.data.vertices:
            strong = [g for g in v.groups if g.weight > 0.01]
            if strong:
                best = max(strong, key=lambda g: g.weight)
                gname = obj.vertex_groups[best.group].name
                dominant[gname] = dominant.get(gname, 0) + 1
        total = len(obj.data.vertices)
        top_name = max(dominant, key=dominant.get) if dominant else "none"
        top_pct = (dominant[top_name] / total) if dominant and total > 0 else 0.0
        method = "region_aware" if asset_type == "humanoid" else "distance_based"
        print(f"SKIN_METHOD={method} dominant={top_name} pct={top_pct:.2f}")

    bone_count = len(arm_obj.data.bones)
    has_mod = any(m.type == 'ARMATURE' for m in obj.modifiers)
    has_vg = len(obj.vertex_groups) > 0
    print(f"RIG_OK bones={bone_count} armature_mod={has_mod} vertex_groups={has_vg}")
PYEOF
)

        RESP=$(run_blender_code "$RIG_WEIGHTS_CODE")
        if ! check_mcp_error "$RESP" "Weight painting"; then
            echo "  ⚠ Weight painting failed (non-fatal)"
        else
            SKIN_METHOD=$(echo "$RESP" | { grep -oP 'SKIN_METHOD=\K\w+' || true; } | head -1)
            RIG_BONE_COUNT=$(echo "$RESP" | { grep -oP 'bones=\K[0-9]+' || true; } | head -1)
            if [[ -n "$RIG_BONE_COUNT" && "$RIG_BONE_COUNT" -gt 0 ]]; then
                echo "  ✅ Rigged with $RIG_BONE_COUNT bones (${ASSET_TYPE}, weights: ${SKIN_METHOD:-unknown})"
            else
                echo "  ⚠ Rigging produced no bones (exporting without armature)"
            fi
        fi
    fi
else
    echo "── Step 5: Auto-rigging ──"
    if [[ "${SKIP_RIGGING:-0}" == "1" ]]; then
        echo "  ⏭ Skipped (SKIP_RIGGING=1)"
    else
        echo "  ⏭ Skipped (asset type: ${ASSET_TYPE} — no armature needed)"
    fi
fi

# --- Step 5c: Power-of-two texture resize ---
#
# Godot performs best with power-of-two textures. Trellis2 bakes at arbitrary
# resolutions. Resize to nearest POT for better GPU memory usage.

echo "── Step 5c: Texture resize (power-of-two) ──"

TEXTURE_RESIZE_CODE=$(cat <<'PYEOF'
import bpy
import math

def nearest_pot(n):
    if n <= 0:
        return 1
    p = 1
    while p < n:
        p *= 2
    # Choose nearest: p or p//2
    if p - n > n - p//2 and p//2 >= 64:
        return p // 2
    return p

resized = 0
for img in bpy.data.images:
    if not img.has_data or img.size[0] == 0 or img.size[1] == 0:
        continue
    if img.name.startswith('.') or 'Viewer' in img.name:
        continue
    w, h = img.size
    new_w = min(nearest_pot(w), 2048)
    new_h = min(nearest_pot(h), 2048)
    if (new_w, new_h) != (w, h):
        img.scale(new_w, new_h)
        resized += 1
        print(f"  Resized {img.name}: {w}x{h} → {new_w}x{new_h}")

print(f"TEXTURES_RESIZED={resized}")
PYEOF
)

RESP=$(run_blender_code "$TEXTURE_RESIZE_CODE")
if ! check_mcp_error "$RESP" "Texture resize"; then
    echo "  ⚠ Texture resize failed (non-fatal, continuing)"
else
    RESIZED=$(echo "$RESP" | { grep -oP 'TEXTURES_RESIZED=\K[0-9]+' || true; } | head -1)
    if [[ -n "$RESIZED" && "$RESIZED" -gt 0 ]]; then
        echo "  ✅ Resized $RESIZED texture(s) to power-of-two"
    else
        echo "  ⏭ All textures already power-of-two (or none present)"
    fi
fi

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
DT=$((T1 - T0))

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
