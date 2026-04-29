#!/usr/bin/env bash
# stage6d-rig.sh — Rigging, weight painting, weight cleanup, POT resize
# Steps 5, 5b, 5c of the Blender post-processing pipeline.
#
# Usage: ./stage6d-rig.sh [glb_filename] [asset_name] [mcp_url]
# Env: SKIP_RIGGING, ASSET_TYPE, FACE_Z_THRESHOLD, WEIGHT_CLEAN_THRESHOLD, MAX_BONE_INFLUENCES

set -euo pipefail

GLB_INPUT="${1:-${GLB_INPUT:-asset_00001_.glb}}"
ASSET_NAME="${2:-${ASSET_NAME:-asset}}"
MCP_URL="${3:-${MCP_URL:-http://localhost:8000}}"
export GLB_INPUT ASSET_NAME MCP_URL

source "$(dirname "$0")/stage6-common.sh"

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

    # ── Weight cleanup pass ──
    # Auto-weights and distance-based both produce bleed on Trellis2 meshes.
    # Face vertices can get 60%+ leg weight, causing animation tearing.
    face_z_pct = max(float("${FACE_Z_THRESHOLD:-0.80}"), 0.71)
    clean_threshold = float("${WEIGHT_CLEAN_THRESHOLD:-0.02}")
    max_influences = int("${MAX_BONE_INFLUENCES:-4}")

    verts_world = [obj.matrix_world @ v.co for v in obj.data.vertices]
    zs = [v.z for v in verts_world]
    z_min_v, z_max_v = min(zs), max(zs)
    v_height = max(z_max_v - z_min_v, 0.001)

    leg_bones = {b.name for b in arm_obj.data.bones if "leg" in b.name or "foot" in b.name or "toe" in b.name}

    if asset_type == "creature":
        head_vg = obj.vertex_groups.get("head")
        neck_vg = obj.vertex_groups.get("neck")
        chest_vg = obj.vertex_groups.get("chest")
        spine_vg = obj.vertex_groups.get("spine")
        if head_vg:
            cleaned_face = 0
            cleaned_legs = 0
            leg_fade_lo = 0.50
            leg_fade_hi = 0.65

            for i, v in enumerate(obj.data.vertices):
                z_rel = (verts_world[i].z - z_min_v) / v_height

                if z_rel >= face_z_pct:
                    # Face region: force 100% head
                    for g in list(v.groups):
                        gname = obj.vertex_groups[g.group].name
                        if gname != "head":
                            obj.vertex_groups[gname].remove([v.index])
                    head_vg.add([v.index], 1.0, 'REPLACE')
                    cleaned_face += 1

                elif z_rel >= 0.70:
                    # Neck transition: only head + neck allowed
                    t = (z_rel - 0.70) / (face_z_pct - 0.70)
                    for g in list(v.groups):
                        gname = obj.vertex_groups[g.group].name
                        if gname not in ("head", "neck"):
                            obj.vertex_groups[gname].remove([v.index])
                    if neck_vg:
                        neck_vg.add([v.index], 1.0 - t, 'REPLACE')
                    head_vg.add([v.index], t, 'REPLACE')
                    cleaned_face += 1

                elif z_rel >= leg_fade_lo:
                    # Torso region: fade out leg influence gradually
                    fade_t = min(1.0, (z_rel - leg_fade_lo) / max(0.001, leg_fade_hi - leg_fade_lo))
                    for g in list(v.groups):
                        gname = obj.vertex_groups[g.group].name
                        if gname in leg_bones and g.weight > 0.001:
                            reduced = g.weight * (1.0 - fade_t)
                            if reduced < 0.01:
                                obj.vertex_groups[gname].remove([v.index])
                                cleaned_legs += 1
                            else:
                                obj.vertex_groups[gname].add([v.index], reduced, 'REPLACE')
                                cleaned_legs += 1
                    # Ensure vertex still has weight after leg removal
                    remaining = sum(g.weight for g in v.groups)
                    if remaining < 0.01:
                        nearest_torso = chest_vg or spine_vg or neck_vg
                        if nearest_torso:
                            nearest_torso.add([v.index], 1.0, 'REPLACE')

            print(f"WEIGHT_CLEANUP face_locked={cleaned_face} legs_faded={cleaned_legs}")

    # Clean stray weights, limit influences, normalize — all asset types
    bpy.ops.object.select_all(action='DESELECT')
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj

    bpy.ops.object.mode_set(mode='WEIGHT_PAINT')
    bpy.ops.object.vertex_group_clean(group_select_mode='ALL', limit=clean_threshold)
    bpy.ops.object.vertex_group_limit_total(group_select_mode='ALL', limit=max_influences)
    bpy.ops.object.vertex_group_normalize_all(group_select_mode='ALL', lock_active=False)
    bpy.ops.object.mode_set(mode='OBJECT')
    print(f"WEIGHT_POST_CLEAN threshold={clean_threshold} max_influences={max_influences}")

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
