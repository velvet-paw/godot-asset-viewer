#!/usr/bin/env bash
# stage6c-materials.sh — UV/PBR, MR strip, texture padding
# Steps 3&4, 4b, 4c of the Blender post-processing pipeline.
#
# Usage: ./stage6c-materials.sh [glb_filename] [asset_name] [mcp_url]
# Env: FORCE_PBR, UV_METHOD, PBR_CHANNELS, SKIP_MR_STRIP, TEXTURE_PADDING

set -euo pipefail

GLB_INPUT="${1:-${GLB_INPUT:-asset_00001_.glb}}"
ASSET_NAME="${2:-${ASSET_NAME:-asset}}"
MCP_URL="${3:-${MCP_URL:-http://localhost:8000}}"
export GLB_INPUT ASSET_NAME MCP_URL

source "$(dirname "$0")/stage6-common.sh"

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

# --- Step 4b: Strip metallic/roughness and set doubleSided ---
#
# Trellis2 bakes an MR texture that causes shiny artifacts in Godot.
# Remove it at the Blender level BEFORE export so GLBs are always clean.
# Also disable backface culling so GLB exports with doubleSided=true.
# Set SKIP_MR_STRIP=1 to keep MR textures (NOT recommended for Godot).

SKIP_MR_STRIP="${SKIP_MR_STRIP:-0}"
if [[ "$SKIP_MR_STRIP" == "1" ]]; then
    echo "── Step 4b: SKIPPED (SKIP_MR_STRIP=1) ──"
else
echo "── Step 4b: Strip metallic/roughness, set doubleSided ──"

STRIP_MR_CODE=$(cat <<'PYEOF'
import bpy

stripped = 0
for mat in bpy.data.materials:
    if not mat.use_nodes:
        continue
    tree = mat.node_tree
    bsdf = None
    for node in tree.nodes:
        if node.type == 'BSDF_PRINCIPLED':
            bsdf = node
            break
    if not bsdf:
        continue

    # Remove MR texture if connected
    mr_input = bsdf.inputs.get('Metallic')
    if mr_input and mr_input.is_linked:
        for link in list(mr_input.links):
            tex_node = link.from_node
            tree.links.remove(link)
            # Also disconnect roughness from same texture
            rough_input = bsdf.inputs.get('Roughness')
            if rough_input and rough_input.is_linked:
                for rlink in list(rough_input.links):
                    if rlink.from_node == tex_node:
                        tree.links.remove(rlink)
            # Remove the texture node and its image
            if tex_node.type == 'TEX_IMAGE' and tex_node.image:
                img = tex_node.image
                tree.nodes.remove(tex_node)
                bpy.data.images.remove(img)
            else:
                tree.nodes.remove(tex_node)
            stripped += 1

    # Also check if roughness has its own separate texture
    rough_input = bsdf.inputs.get('Roughness')
    if rough_input and rough_input.is_linked:
        for link in list(rough_input.links):
            tex_node = link.from_node
            tree.links.remove(link)
            if tex_node.type == 'TEX_IMAGE' and tex_node.image:
                img = tex_node.image
                tree.nodes.remove(tex_node)
                bpy.data.images.remove(img)
            else:
                tree.nodes.remove(tex_node)
            stripped += 1

    # Set constant values
    bsdf.inputs['Metallic'].default_value = 0.0
    bsdf.inputs['Roughness'].default_value = 1.0

    # Disable backface culling = doubleSided in glTF export
    mat.use_backface_culling = False

print(f"STRIP_MR_RESULT=stripped:{stripped}")
PYEOF
)

RESP=$(run_blender_code "$STRIP_MR_CODE")
if ! check_mcp_error "$RESP" "Strip MR"; then exit 1; fi
STRIPPED_COUNT=$(echo "$RESP" | { grep -oP 'stripped:\K[0-9]+' || echo "0"; })
echo "  ✅ Metallic/roughness removed (${STRIPPED_COUNT} textures), doubleSided enabled"
fi

# --- Step 4c: Texture padding (UV island dilation) ---
#
# Trellis2 baked textures have fragmented UV islands with garbage-colored
# pixels (bright pink, white, metallic) between them. Bilinear filtering
# samples these at UV seam boundaries, causing "shiny brown artifacts."
# Fix: use alpha channel to identify gap pixels (alpha < 0.5), then dilate
# nearest covered pixel colors outward by PADDING pixels via BFS.
# Also despeckle: replace bright outlier pixels (much brighter than their
# 4-neighbors) with the neighbor average to catch full-alpha garbage.

TEXTURE_PADDING="${TEXTURE_PADDING:-16}"
echo "── Step 4c: Texture padding (${TEXTURE_PADDING}px dilation) ──"

PAD_TEX_CODE=$(cat <<PYEOF
import bpy
import numpy as np
from collections import deque

padding = ${TEXTURE_PADDING}
processed = 0

for img in bpy.data.images:
    if not img.has_data or img.size[0] < 4 or img.size[1] < 4:
        continue
    # Skip non-color images (normal maps, etc.)
    if any(kw in img.name.lower() for kw in ['normal', 'roughness', 'metallic', 'height']):
        continue

    w, h = img.size
    px = np.array(img.pixels[:]).reshape(h, w, 4)

    # Alpha-based gap detection: pixels with alpha < 0.5 are UV gaps
    covered = px[:,:,3] >= 0.5
    gap_count = np.sum(~covered)
    total = w * h

    if gap_count == 0:
        print(f"TEXTURE_PAD image={img.name} size={w}x{h} no_gaps")
        continue

    # BFS dilation from boundary of covered region into gaps
    dist = np.full((h, w), -1, dtype=np.int32)
    queue = deque()

    # Fast boundary detection with numpy padding
    padded_covered = np.pad(covered, 1, mode='constant', constant_values=False)
    has_uncovered_neighbor = (
        (~padded_covered[:-2, 1:-1]) |
        (~padded_covered[2:, 1:-1]) |
        (~padded_covered[1:-1, :-2]) |
        (~padded_covered[1:-1, 2:])
    )
    boundary = covered & has_uncovered_neighbor
    boundary_ys, boundary_xs = np.where(boundary)

    for y, x in zip(boundary_ys, boundary_xs):
        dist[y, x] = 0
        queue.append((y, x))

    padded_px = 0
    while queue:
        y, x = queue.popleft()
        d = dist[y, x]
        for dy, dx in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and not covered[ny, nx] and dist[ny, nx] < 0:
                nd = d + 1
                if nd > padding:
                    continue
                px[ny, nx] = px[y, x]
                covered[ny, nx] = True
                dist[ny, nx] = nd
                queue.append((ny, nx))
                padded_px += 1

    # Despeckle: replace bright outlier pixels with neighbor average
    r, g, b = px[:,:,0], px[:,:,1], px[:,:,2]
    luminance = 0.299 * r + 0.587 * g + 0.114 * b
    lum_pad = np.pad(luminance, 1, mode='edge')
    neighbor_avg = (lum_pad[:-2, 1:-1] + lum_pad[2:, 1:-1] +
                    lum_pad[1:-1, :-2] + lum_pad[1:-1, 2:]) / 4
    outliers = (luminance - neighbor_avg) > 0.15
    despeckled = int(np.sum(outliers))
    for c in range(3):
        ch = px[:,:,c].copy()
        ch_pad = np.pad(ch, 1, mode='edge')
        ch_avg = (ch_pad[:-2, 1:-1] + ch_pad[2:, 1:-1] +
                  ch_pad[1:-1, :-2] + ch_pad[1:-1, 2:]) / 4
        px[:,:,c] = np.where(outliers, ch_avg, ch)

    img.pixels[:] = px.flatten().tolist()
    img.update()
    cov_pct = 100 * np.sum(covered) / total
    print(f"TEXTURE_PAD image={img.name} size={w}x{h} gaps={gap_count} padded={padded_px} despeckled={despeckled} coverage={cov_pct:.1f}%")
    processed += 1

# --- Flatten alpha to 1.0 for OPAQUE materials ---
# Trellis2 textures often have semi-transparent alpha (200-254) on valid UV island
# pixels. For OPAQUE materials, alpha is meaningless and the semi-transparency
# wastes texture bits while confusing some import pipelines.
import bpy
for mat in bpy.data.materials:
    # glTF OPAQUE = no alpha usage
    if mat.blend_method in ('OPAQUE', 'CLIP') or not mat.use_backface_culling:
        for img in bpy.data.images:
            if not img.has_data or img.size[0] < 4:
                continue
            if any(kw in img.name.lower() for kw in ['normal', 'roughness', 'metallic', 'height']):
                continue
            w2, h2 = img.size
            px2 = np.array(img.pixels[:]).reshape(h2, w2, 4)
            non_opaque = np.sum(px2[:,:,3] < 1.0)
            if non_opaque > 0:
                px2[:,:,3] = 1.0
                img.pixels[:] = px2.flatten().tolist()
                img.update()
                print(f"ALPHA_FLATTEN image={img.name} fixed={non_opaque} pixels")
        break  # only need to process once

print(f"TEXTURE_PAD_DONE processed={processed}")
PYEOF
)

RESP=$(run_blender_code "$PAD_TEX_CODE")
if ! check_mcp_error "$RESP" "Texture padding"; then
    echo "  ⚠ Texture padding failed (non-fatal)"
else
    PAD_COUNT=$(echo "$RESP" | { grep -oP 'processed=\K[0-9]+' || echo "0"; })
    echo "  ✅ Texture padding applied (${TEXTURE_PADDING}px dilation, ${PAD_COUNT} textures)"
fi
