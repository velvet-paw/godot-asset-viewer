#!/usr/bin/env python3
"""Gate 6: Final game-ready GLB asset validation.

Validates a final GLB after Stage 6 Blender post-processing.
Checks geometry budget, material properties, texture quality,
armature/skeleton, scale, file size, and LOD consistency.
"""

import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))

import numpy as np
import trimesh
from PIL import Image
from pygltflib import GLTF2

from gate_common import (
    GateReport,
    STATUS_FAIL,
    STATUS_PASS,
    STATUS_WARN,
    base_arg_parser,
    finish,
    get_thresholds,
)

BRIGHT_OUTLIER_THRESHOLD = 250
BRIGHT_OUTLIER_MAX_RATIO = 0.02
MIN_VERTEX_COUNT = 100
METALLIC_MAX = 0.1
ROUGHNESS_MIN = 0.8
WEIGHT_COVERAGE_MIN = 0.95
EXPECTED_BONE_NAMES = {"head", "spine", "neck", "hips"}
NORMAL_SPLIT_WARN_THRESHOLD = 0.05  # WARN if >5% of shared positions have >120° splits
UV_ISLAND_FAIL_THRESHOLD = 2000
UV_ISLAND_WARN_THRESHOLD = 500
UV_COVERAGE_WARN_THRESHOLD = 0.50
METALLIC_GARBAGE_WARN_RATIO = 0.15
METALLIC_BRIGHTNESS_THRESHOLD = 120
METALLIC_SATURATION_THRESHOLD = 0.15


def _load_mesh(path: str) -> trimesh.Trimesh:
    """Load a GLB and return a single merged Trimesh."""
    scene = trimesh.load(path, force="scene")
    if isinstance(scene, trimesh.Scene):
        if hasattr(scene, "to_geometry"):
            return scene.to_geometry()
        meshes = list(scene.geometry.values())
        return trimesh.util.concatenate(meshes) if meshes else trimesh.Trimesh()
    return scene


def _is_pot(n: int) -> bool:
    return n > 0 and (n & (n - 1)) == 0


def _extract_texture_image(gltf: GLTF2, tex_index: int) -> Image.Image | None:
    """Extract a texture image from glTF binary buffer."""
    if tex_index is None or tex_index < 0:
        return None
    textures = gltf.textures or []
    if tex_index >= len(textures):
        return None
    tex = textures[tex_index]
    if tex.source is None:
        return None
    images = gltf.images or []
    if tex.source >= len(images):
        return None
    img_def = images[tex.source]

    if img_def.bufferView is not None:
        bv = gltf.bufferViews[img_def.bufferView]
        blob = gltf.binary_blob()
        if blob is None:
            return None
        offset = bv.byteOffset or 0
        data = blob[offset : offset + bv.byteLength]
        import io

        return Image.open(io.BytesIO(data))
    return None


def check_vertex_count(report: GateReport, mesh: trimesh.Trimesh, thresholds: dict):
    verts = len(mesh.vertices)
    max_verts = thresholds["max_verts"]

    if verts < MIN_VERTEX_COUNT:
        report.add_check(
            name="vertex_count",
            status=STATUS_FAIL,
            expected=f">={MIN_VERTEX_COUNT}",
            actual=str(verts),
            message=f"Degenerate mesh: only {verts} vertices",
            details={"vertices": verts},
        )
    elif verts > max_verts:
        report.add_check(
            name="vertex_count_exceeded",
            status=STATUS_WARN,
            expected=f"<={max_verts}",
            actual=str(verts),
            message=f"Vertex count {verts} exceeds budget of {max_verts}",
            details={"vertices": verts, "max_verts": max_verts},
        )
    else:
        report.add_check(
            name="vertex_count",
            status=STATUS_PASS,
            expected=f"{MIN_VERTEX_COUNT}–{max_verts}",
            actual=str(verts),
            message="Vertex count within budget",
            details={"vertices": verts},
        )


def check_material_metallic(report: GateReport, gltf: GLTF2):
    materials = gltf.materials or []
    if not materials:
        report.add_check(
            name="material_metallic",
            status=STATUS_PASS,
            expected="metallic=0",
            actual="no materials",
            message="No materials to check",
        )
        return

    for mat in materials:
        mat_name = mat.name or "unnamed"
        pbr = mat.pbrMetallicRoughness
        if pbr is None:
            continue

        metallic_val = pbr.metallicFactor if pbr.metallicFactor is not None else 1.0
        has_metallic_tex = (
            pbr.metallicRoughnessTexture is not None
        )

        if metallic_val > METALLIC_MAX or has_metallic_tex:
            details = {"material": mat_name, "metallic_factor": metallic_val}
            if has_metallic_tex:
                details["has_metallic_texture"] = True
            report.add_check(
                name="material_metallic",
                status=STATUS_FAIL,
                expected=f"metallic<={METALLIC_MAX}, no metallic texture",
                actual=f"metallic={metallic_val}, texture={'yes' if has_metallic_tex else 'no'}",
                message=f"Material '{mat_name}' has metallic > {METALLIC_MAX} or metallic texture",
                details=details,
            )
            return

    report.add_check(
        name="material_metallic",
        status=STATUS_PASS,
        expected=f"metallic<={METALLIC_MAX}",
        actual="all materials non-metallic",
        message="All materials have metallic=0 and no metallic texture",
    )


def check_material_roughness(report: GateReport, gltf: GLTF2):
    materials = gltf.materials or []
    if not materials:
        report.add_check(
            name="material_roughness",
            status=STATUS_PASS,
            expected=f"roughness>={ROUGHNESS_MIN}",
            actual="no materials",
            message="No materials to check",
        )
        return

    for mat in materials:
        mat_name = mat.name or "unnamed"
        pbr = mat.pbrMetallicRoughness
        if pbr is None:
            continue

        roughness = pbr.roughnessFactor if pbr.roughnessFactor is not None else 1.0
        if roughness < ROUGHNESS_MIN:
            report.add_check(
                name="material_roughness",
                status=STATUS_WARN,
                expected=f"roughness>={ROUGHNESS_MIN}",
                actual=f"roughness={roughness}",
                message=f"Material '{mat_name}' roughness {roughness} < {ROUGHNESS_MIN}",
                details={"material": mat_name, "roughness": roughness},
            )
            return

    report.add_check(
        name="material_roughness",
        status=STATUS_PASS,
        expected=f"roughness>={ROUGHNESS_MIN}",
        actual="all materials sufficiently rough",
        message="All materials have roughness >= threshold",
    )


def check_double_sided(report: GateReport, gltf: GLTF2):
    materials = gltf.materials or []
    if not materials:
        report.add_check(
            name="double_sided_missing",
            status=STATUS_PASS,
            expected="doubleSided=true",
            actual="no materials",
            message="No materials to check",
        )
        return

    single_sided = [
        m.name or "unnamed" for m in materials if not getattr(m, "doubleSided", False)
    ]
    if single_sided:
        report.add_check(
            name="double_sided_missing",
            status=STATUS_WARN,
            expected="doubleSided=true on all materials",
            actual=f"{len(single_sided)} single-sided material(s)",
            message=f"Single-sided materials: {', '.join(single_sided[:3])}",
            details={"single_sided_materials": single_sided},
        )
    else:
        report.add_check(
            name="double_sided_missing",
            status=STATUS_PASS,
            expected="doubleSided=true",
            actual="all materials double-sided",
            message="All materials are double-sided",
        )


def check_texture_pot(report: GateReport, gltf: GLTF2):
    """Check that all embedded textures have power-of-two dimensions."""
    images = gltf.images or []
    if not images:
        report.add_check(
            name="texture_pot",
            status=STATUS_PASS,
            expected="POT dimensions",
            actual="no textures",
            message="No embedded textures to check",
        )
        return

    non_pot = []
    for i, img_def in enumerate(images):
        img = _extract_texture_image(gltf, _find_texture_for_image(gltf, i))
        if img is None:
            continue
        w, h = img.size
        if not _is_pot(w) or not _is_pot(h):
            non_pot.append({"name": img_def.name or f"image_{i}", "width": w, "height": h})

    if non_pot:
        names = [t["name"] for t in non_pot[:3]]
        report.add_check(
            name="not_pot",
            status=STATUS_WARN,
            expected="all textures POT",
            actual=f"{len(non_pot)} non-POT texture(s)",
            message=f"Non-POT textures: {', '.join(names)}",
            details={"non_pot_textures": non_pot},
        )
    else:
        report.add_check(
            name="texture_pot",
            status=STATUS_PASS,
            expected="POT dimensions",
            actual="all textures POT",
            message="All textures have power-of-two dimensions",
        )


def _find_texture_for_image(gltf: GLTF2, image_index: int) -> int | None:
    """Find a texture index that references the given image."""
    for i, tex in enumerate(gltf.textures or []):
        if tex.source == image_index:
            return i
    return image_index  # fallback: treat image index as texture index


def check_texture_quality(report: GateReport, gltf: GLTF2):
    """Check for garbage/corrupted textures via bright outlier detection."""
    images = gltf.images or []
    if not images:
        report.add_check(
            name="texture_quality",
            status=STATUS_PASS,
            expected=f"bright_outliers<={BRIGHT_OUTLIER_MAX_RATIO:.0%}",
            actual="no textures",
            message="No textures to check",
        )
        return

    for i, img_def in enumerate(images):
        img = _extract_texture_image(gltf, _find_texture_for_image(gltf, i))
        if img is None:
            continue
        pixels = np.asarray(img.convert("RGB"))
        bright_mask = np.all(pixels > BRIGHT_OUTLIER_THRESHOLD, axis=-1)
        ratio = float(np.mean(bright_mask))
        if ratio > BRIGHT_OUTLIER_MAX_RATIO:
            tex_name = img_def.name or f"image_{i}"
            report.add_check(
                name="texture_quality",
                status=STATUS_WARN,
                expected=f"bright_outliers<={BRIGHT_OUTLIER_MAX_RATIO:.0%}",
                actual=f"bright_outliers={ratio:.1%} in {tex_name}",
                message=f"Texture '{tex_name}' has {ratio:.1%} bright outliers (possible garbage)",
                details={"texture": tex_name, "bright_outlier_ratio": round(ratio, 4)},
            )
            return

    report.add_check(
        name="texture_quality",
        status=STATUS_PASS,
        expected=f"bright_outliers<={BRIGHT_OUTLIER_MAX_RATIO:.0%}",
        actual="all textures clean",
        message="No texture quality issues detected",
    )


def check_armature(report: GateReport, gltf: GLTF2, asset_type: str, thresholds: dict):
    min_bones = thresholds["min_bones"]
    requires_armature = asset_type in ("creature", "humanoid")

    skins = gltf.skins or []
    if not skins:
        if requires_armature:
            report.add_check(
                name="armature_check",
                status=STATUS_FAIL,
                expected=f"armature with >={min_bones} bones",
                actual="no armature",
                message=f"Asset type '{asset_type}' requires an armature but none found",
            )
        else:
            report.add_check(
                name="armature_check",
                status=STATUS_PASS,
                expected="no armature required",
                actual="no armature",
                message=f"Asset type '{asset_type}' does not require an armature",
            )
        return

    joints = skins[0].joints or []
    bone_count = len(joints)
    bone_names = []
    for j in joints:
        node = gltf.nodes[j] if j < len(gltf.nodes or []) else None
        if node and node.name:
            bone_names.append(node.name.lower())

    if bone_count < min_bones:
        report.add_check(
            name="armature_check",
            status=STATUS_FAIL,
            expected=f">={min_bones} bones",
            actual=f"{bone_count} bones",
            message=f"Armature has {bone_count} bones, need >={min_bones}",
            details={"bone_count": bone_count, "bone_names": bone_names},
        )
        return

    # Check for expected bone names
    found_expected = set()
    for name in bone_names:
        for expected in EXPECTED_BONE_NAMES:
            if expected in name:
                found_expected.add(expected)

    missing = EXPECTED_BONE_NAMES - found_expected
    if missing and requires_armature:
        report.add_check(
            name="armature_check",
            status=STATUS_WARN,
            expected=f"bones containing: {', '.join(sorted(EXPECTED_BONE_NAMES))}",
            actual=f"missing: {', '.join(sorted(missing))}",
            message=f"Armature missing expected bone names: {', '.join(sorted(missing))}",
            details={
                "bone_count": bone_count,
                "missing_names": sorted(missing),
                "bone_names": bone_names,
            },
        )
    else:
        report.add_check(
            name="armature_check",
            status=STATUS_PASS,
            expected=f">={min_bones} bones",
            actual=f"{bone_count} bones",
            message="Armature present with expected bone structure",
            details={"bone_count": bone_count, "bone_names": bone_names},
        )


def check_weight_coverage(report: GateReport, gltf: GLTF2):
    """Check that vertices have non-zero skin weights if armature present."""
    skins = gltf.skins or []
    if not skins:
        return  # no armature → skip weight check

    meshes = gltf.meshes or []
    has_weights_attr = False
    total_verts = 0
    weighted_verts = 0

    blob = gltf.binary_blob()
    if blob is None:
        report.add_check(
            name="weight_coverage",
            status=STATUS_WARN,
            expected=f">={WEIGHT_COVERAGE_MIN:.0%} weighted",
            actual="no binary data",
            message="Cannot read vertex weights: no binary blob",
        )
        return

    accessors = gltf.accessors or []
    buffer_views = gltf.bufferViews or []

    for mesh in meshes:
        for prim in mesh.primitives:
            weights_idx = getattr(prim.attributes, "WEIGHTS_0", None)
            if weights_idx is None:
                continue
            has_weights_attr = True

            if weights_idx >= len(accessors):
                continue
            acc = accessors[weights_idx]
            if acc.bufferView is None or acc.bufferView >= len(buffer_views):
                continue

            bv = buffer_views[acc.bufferView]
            offset = (bv.byteOffset or 0) + (acc.byteOffset or 0)
            count = acc.count
            stride = bv.byteStride

            # VEC4 float weights
            if acc.componentType == 5126:  # FLOAT
                comp_size = 4
                fmt = "<4f"
            elif acc.componentType == 5121:  # UNSIGNED_BYTE (normalized)
                comp_size = 1
                fmt = "<4B"
            elif acc.componentType == 5123:  # UNSIGNED_SHORT (normalized)
                comp_size = 2
                fmt = "<4H"
            else:
                continue

            element_size = comp_size * 4
            actual_stride = stride if stride else element_size

            for v in range(count):
                pos = offset + v * actual_stride
                if pos + element_size > len(blob):
                    break
                w = struct.unpack_from(fmt, blob, pos)
                total_verts += 1
                if sum(w) > 0:
                    weighted_verts += 1

    if not has_weights_attr:
        report.add_check(
            name="weight_coverage",
            status=STATUS_WARN,
            expected="WEIGHTS_0 attribute present",
            actual="no weight attributes",
            message="Armature present but no vertex weights found",
        )
        return

    if total_verts == 0:
        report.add_check(
            name="weight_coverage",
            status=STATUS_WARN,
            expected=f">={WEIGHT_COVERAGE_MIN:.0%} weighted",
            actual="0 vertices analyzed",
            message="Could not analyze vertex weights",
        )
        return

    coverage = weighted_verts / total_verts
    ok = coverage >= WEIGHT_COVERAGE_MIN
    report.add_check(
        name="weight_coverage",
        status=STATUS_PASS if ok else STATUS_WARN,
        expected=f">={WEIGHT_COVERAGE_MIN:.0%} weighted",
        actual=f"{coverage:.1%} ({weighted_verts}/{total_verts})",
        message="Weight coverage OK" if ok else f"Only {coverage:.1%} vertices have weights",
        details={"coverage": round(coverage, 4), "weighted": weighted_verts, "total": total_verts},
    )


def check_scale(report: GateReport, mesh: trimesh.Trimesh, thresholds: dict):
    target = thresholds["target_height"]
    tolerance = thresholds["height_tolerance"]

    bounds = mesh.bounds
    # glTF uses Y-up; trimesh preserves this
    height = float(bounds[1][1] - bounds[0][1])

    low = target - tolerance
    high = target + tolerance
    ok = low <= height <= high

    report.add_check(
        name="scale_check",
        status=STATUS_PASS if ok else STATUS_WARN,
        expected=f"{low:.2f}–{high:.2f}m",
        actual=f"{height:.3f}m",
        message="Scale within target range" if ok else f"Height {height:.3f}m outside target {target}±{tolerance}m",
        details={"height": round(height, 3), "target": target, "tolerance": tolerance},
    )


def check_file_size(report: GateReport, path: str, thresholds: dict):
    max_mb = thresholds["max_file_mb"]
    size_bytes = os.path.getsize(path)
    size_mb = size_bytes / (1024 * 1024)
    ok = size_mb <= max_mb

    report.add_check(
        name="file_size" if ok else "file_size_exceeded",
        status=STATUS_PASS if ok else STATUS_WARN,
        expected=f"<={max_mb}MB",
        actual=f"{size_mb:.1f}MB",
        message="File size OK" if ok else f"File size {size_mb:.1f}MB exceeds {max_mb}MB limit",
        details={"size_mb": round(size_mb, 2), "max_mb": max_mb},
    )


def check_lods(report: GateReport, path: str, main_verts: int):
    """Check LOD files in the same directory for vertex budget consistency."""
    base, ext = os.path.splitext(path)
    # Strip common suffixes (_final) so we find sibling LOD files
    for strip_suffix in ("_final",):
        if base.endswith(strip_suffix):
            base = base[: -len(strip_suffix)]
            break
    lod_issues = []
    lods_found = 0

    for suffix in ("_lod1", "_lod2"):
        lod_path = f"{base}{suffix}{ext}"
        if not os.path.exists(lod_path):
            continue
        lods_found += 1
        try:
            lod_mesh = _load_mesh(lod_path)
            lod_verts = len(lod_mesh.vertices)
            if lod_verts >= main_verts:
                lod_issues.append(
                    {"lod": suffix.strip("_"), "verts": lod_verts, "main_verts": main_verts}
                )
        except Exception as e:
            lod_issues.append({"lod": suffix.strip("_"), "error": str(e)})

    if lods_found == 0:
        # No LODs to check — not an error
        return

    if lod_issues:
        report.add_check(
            name="lod_check",
            status=STATUS_WARN,
            expected="LOD verts < main mesh verts",
            actual=f"{len(lod_issues)} LOD issue(s)",
            message="LOD mesh has more vertices than main mesh",
            details={"issues": lod_issues},
        )
    else:
        report.add_check(
            name="lod_check",
            status=STATUS_PASS,
            expected="LOD verts < main mesh verts",
            actual=f"{lods_found} LOD(s) valid",
            message="All LODs have fewer vertices than main mesh",
        )


def check_shadow_geometry(report: GateReport, path: str):
    """Check for shadow/occlusion meshes (Icospheres, flat discs) that envelop the model.

    Trellis2 sometimes generates Icosphere shells or flat ground-shadow discs
    alongside the primary mesh. These cause blotchy overlay artifacts in-game.
    """
    scene = trimesh.load(path, force="scene")
    if not isinstance(scene, trimesh.Scene) or not scene.geometry:
        report.add_check(
            name="shadow_geometry",
            status=STATUS_PASS,
            expected="single primary mesh",
            actual="no scene geometry",
            message="No scene to check",
        )
        return

    geometries = list(scene.geometry.items())
    if len(geometries) <= 1:
        # Single mesh — check for enveloping sub-geometry is not needed
        report.add_check(
            name="shadow_geometry",
            status=STATUS_PASS,
            expected="single primary mesh",
            actual=f"1 geometry ({len(geometries[0][1].vertices)} verts)",
            message="No shadow geometry detected",
        )
        return

    # Multiple geometries — flag non-primary meshes as potential shadows
    # Primary mesh is the one with the most vertices
    sorted_geoms = sorted(geometries, key=lambda g: len(g[1].vertices), reverse=True)
    primary_name, primary_mesh = sorted_geoms[0]
    shadow_meshes = []

    for name, geom in sorted_geoms[1:]:
        # Heuristic: shadow meshes are small (<500 verts) or envelop the primary
        verts = len(geom.vertices)
        bounds = geom.bounds
        primary_bounds = primary_mesh.bounds
        # Check if this mesh envelops the primary (larger bounding box on all axes)
        envelops = all(
            bounds[0][i] <= primary_bounds[0][i] and bounds[1][i] >= primary_bounds[1][i]
            for i in range(3)
        )
        is_small = verts < 500
        if envelops or is_small:
            shadow_meshes.append({"name": name, "verts": verts, "envelops": envelops})

    if shadow_meshes:
        names = [s["name"] for s in shadow_meshes]
        report.add_check(
            name="shadow_geometry",
            status=STATUS_FAIL,
            expected="single primary mesh",
            actual=f"{len(shadow_meshes)} shadow mesh(es): {', '.join(names)}",
            message="Shadow/occlusion geometry detected — causes blotchy overlay artifacts. "
            "Remove via Blender: delete non-primary objects before export.",
            details={"shadow_meshes": shadow_meshes, "primary": primary_name},
        )
    else:
        report.add_check(
            name="shadow_geometry",
            status=STATUS_PASS,
            expected="single primary mesh",
            actual=f"{len(geometries)} geometries, none are shadows",
            message="No shadow geometry detected",
        )


def check_normal_consistency(report: GateReport, path: str):
    """Check for split normals at shared vertex positions (UV seam artifacts).

    Uses raw scene geometry (not ``to_geometry()``) so that scene-graph
    transforms do not distort the vertex normals.
    """
    from collections import defaultdict

    scene = trimesh.load(path, force="scene")
    if isinstance(scene, trimesh.Scene):
        geom = list(scene.geometry.values())[0] if scene.geometry else None
    elif isinstance(scene, trimesh.Trimesh):
        geom = scene
    else:
        geom = None

    if geom is None or len(geom.vertices) == 0:
        report.add_check(
            name="normal_consistency",
            status=STATUS_PASS,
            expected="no split normals",
            actual="no geometry",
            message="No geometry to check",
        )
        return

    verts = geom.vertices
    normals = geom.vertex_normals
    pos_rounded = np.round(verts, 5)

    pos_to_normals = defaultdict(list)
    for i in range(len(verts)):
        pos_to_normals[tuple(pos_rounded[i])].append(normals[i])

    shared_positions = 0
    extreme_splits = 0  # >120° difference
    for norms in pos_to_normals.values():
        if len(norms) <= 1:
            continue
        shared_positions += 1
        arr = np.array(norms)
        dots = np.clip(arr @ arr.T, -1, 1)
        min_dot = dots[np.triu_indices(len(arr), k=1)].min()
        if min_dot < -0.5:  # cos(120°) = -0.5
            extreme_splits += 1

    if shared_positions == 0:
        report.add_check(
            name="normal_consistency",
            status=STATUS_PASS,
            expected="no split normals",
            actual="no shared positions",
            message="No shared vertex positions to check",
        )
        return

    ratio = extreme_splits / shared_positions
    ok = ratio <= NORMAL_SPLIT_WARN_THRESHOLD

    report.add_check(
        name="normal_consistency",
        status=STATUS_PASS if ok else STATUS_WARN,
        expected=f"<={NORMAL_SPLIT_WARN_THRESHOLD:.0%} positions with >120° splits",
        actual=f"{ratio:.1%} ({extreme_splits}/{shared_positions})",
        message="Normals consistent across UV seams"
        if ok
        else f"{extreme_splits} positions have extreme normal splits (blotchy shading risk)",
        details={
            "shared_positions": shared_positions,
            "extreme_splits": extreme_splits,
            "ratio": round(ratio, 4),
        },
    )


def check_uv_fragmentation(report: GateReport, mesh: trimesh.Trimesh):
    """Detect excessive UV island count and low UV coverage."""
    from collections import defaultdict, deque

    if not hasattr(mesh.visual, "uv") or mesh.visual.uv is None:
        report.add_check(
            name="uv_fragmentation",
            status=STATUS_PASS,
            expected=f"islands<={UV_ISLAND_WARN_THRESHOLD}",
            actual="no UVs",
            message="No UV data to check",
        )
        return

    uvs = mesh.visual.uv
    faces = mesh.faces

    if len(faces) == 0:
        report.add_check(
            name="uv_fragmentation",
            status=STATUS_PASS,
            expected=f"islands<={UV_ISLAND_WARN_THRESHOLD}",
            actual="no faces",
            message="No faces to check",
        )
        return

    # Build face adjacency by shared vertices
    vert_to_faces: dict[int, list[int]] = defaultdict(list)
    for fi, face in enumerate(faces):
        for vi in face:
            vert_to_faces[int(vi)].append(fi)

    # BFS to find connected components (UV islands)
    visited: set[int] = set()
    islands = 0
    for fi in range(len(faces)):
        if fi in visited:
            continue
        islands += 1
        queue = deque([fi])
        while queue:
            cur = queue.popleft()
            if cur in visited:
                continue
            visited.add(cur)
            for vi in faces[cur]:
                for adj in vert_to_faces[int(vi)]:
                    if adj not in visited:
                        queue.append(adj)

    # UV coverage: sum of UV triangle areas (vectorized)
    uv0 = uvs[faces[:, 0]]
    uv1 = uvs[faces[:, 1]]
    uv2 = uvs[faces[:, 2]]
    uv_area = float(0.5 * np.sum(np.abs(
        (uv1[:, 0] - uv0[:, 0]) * (uv2[:, 1] - uv0[:, 1])
        - (uv2[:, 0] - uv0[:, 0]) * (uv1[:, 1] - uv0[:, 1])
    )))

    # Determine status for island count
    if islands > UV_ISLAND_FAIL_THRESHOLD:
        report.add_check(
            name="uv_fragmentation",
            status=STATUS_FAIL,
            expected=f"islands<={UV_ISLAND_FAIL_THRESHOLD}",
            actual=f"{islands} islands",
            message=f"Extreme UV fragmentation: {islands} islands (texture will have garbage)",
            details={"islands": islands, "uv_coverage": round(uv_area, 4)},
        )
    elif islands > UV_ISLAND_WARN_THRESHOLD:
        report.add_check(
            name="uv_fragmentation",
            status=STATUS_WARN,
            expected=f"islands<={UV_ISLAND_WARN_THRESHOLD}",
            actual=f"{islands} islands",
            message=f"Moderate UV fragmentation: {islands} islands",
            details={"islands": islands, "uv_coverage": round(uv_area, 4)},
        )
    else:
        report.add_check(
            name="uv_fragmentation",
            status=STATUS_PASS,
            expected=f"islands<={UV_ISLAND_WARN_THRESHOLD}",
            actual=f"{islands} islands",
            message=f"UV island count acceptable ({islands})",
            details={"islands": islands, "uv_coverage": round(uv_area, 4)},
        )

    # UV coverage check
    if uv_area < UV_COVERAGE_WARN_THRESHOLD:
        report.add_check(
            name="uv_coverage",
            status=STATUS_WARN,
            expected=f">={UV_COVERAGE_WARN_THRESHOLD:.0%}",
            actual=f"{uv_area:.1%}",
            message=f"Low UV coverage ({uv_area:.1%}) — too much wasted texture space",
            details={"uv_coverage": round(uv_area, 4)},
        )
    else:
        report.add_check(
            name="uv_coverage",
            status=STATUS_PASS,
            expected=f">={UV_COVERAGE_WARN_THRESHOLD:.0%}",
            actual=f"{uv_area:.1%}",
            message=f"UV coverage adequate ({uv_area:.1%})",
            details={"uv_coverage": round(uv_area, 4)},
        )


def check_texture_desaturation(report: GateReport, gltf: GLTF2, mesh: trimesh.Trimesh):
    """Detect metallic-looking garbage pixels outside UV islands."""
    # Need base color texture
    materials = gltf.materials or []
    tex_index = None
    for mat in materials:
        pbr = getattr(mat, "pbrMetallicRoughness", None)
        if pbr and pbr.baseColorTexture is not None:
            tex_index = pbr.baseColorTexture.index
            break

    if tex_index is None:
        report.add_check(
            name="texture_desaturation",
            status=STATUS_PASS,
            expected=f"metallic_gap_ratio<={METALLIC_GARBAGE_WARN_RATIO:.0%}",
            actual="no base color texture",
            message="No base color texture to check",
        )
        return

    img = _extract_texture_image(gltf, tex_index)
    if img is None:
        report.add_check(
            name="texture_desaturation",
            status=STATUS_PASS,
            expected=f"metallic_gap_ratio<={METALLIC_GARBAGE_WARN_RATIO:.0%}",
            actual="texture not extractable",
            message="Could not extract base color texture",
        )
        return

    if not hasattr(mesh.visual, "uv") or mesh.visual.uv is None:
        report.add_check(
            name="texture_desaturation",
            status=STATUS_PASS,
            expected=f"metallic_gap_ratio<={METALLIC_GARBAGE_WARN_RATIO:.0%}",
            actual="no UVs",
            message="No UV data for rasterization",
        )
        return

    img_rgb = img.convert("RGB")
    w, h = img_rgb.size
    uvs = mesh.visual.uv
    faces = mesh.faces

    # Rasterize UV triangles to build coverage mask (PIL polygon fill — fast C impl)
    from PIL import Image as PILImage, ImageDraw
    mask_img = PILImage.new("L", (w, h), 0)
    draw = ImageDraw.Draw(mask_img)
    for face in faces:
        pts = [
            (float(uvs[vi][0]) * (w - 1), (1.0 - float(uvs[vi][1])) * (h - 1))
            for vi in face
        ]
        draw.polygon(pts, fill=255)
    uv_mask = np.asarray(mask_img) > 0

    # Get pixels outside UV islands
    gap_mask = ~uv_mask
    gap_count = int(np.sum(gap_mask))

    if gap_count == 0:
        report.add_check(
            name="texture_desaturation",
            status=STATUS_PASS,
            expected=f"metallic_gap_ratio<={METALLIC_GARBAGE_WARN_RATIO:.0%}",
            actual="no gap pixels",
            message="Full UV coverage, no gap pixels to check",
        )
        return

    pixels = np.asarray(img_rgb)
    # Convert to HSV for saturation check
    img_hsv = np.asarray(img.convert("HSV"))
    saturation = img_hsv[:, :, 1] / 255.0  # Normalize to [0, 1]
    brightness = np.max(pixels, axis=-1)  # Max channel as brightness

    # Bright + desaturated pixels in gap areas
    bright = brightness > METALLIC_BRIGHTNESS_THRESHOLD
    desat = saturation < METALLIC_SATURATION_THRESHOLD
    metallic_gap = gap_mask & bright & desat
    metallic_count = int(np.sum(metallic_gap))
    ratio = metallic_count / gap_count

    if ratio > METALLIC_GARBAGE_WARN_RATIO:
        report.add_check(
            name="texture_desaturation",
            status=STATUS_WARN,
            expected=f"metallic_gap_ratio<={METALLIC_GARBAGE_WARN_RATIO:.0%}",
            actual=f"{ratio:.1%} ({metallic_count}/{gap_count} gap pixels)",
            message=f"Metallic-looking garbage in texture gaps: {ratio:.1%} of gap pixels are bright+desaturated",
            details={
                "metallic_gap_ratio": round(ratio, 4),
                "metallic_pixels": metallic_count,
                "gap_pixels": gap_count,
            },
        )
    else:
        report.add_check(
            name="texture_desaturation",
            status=STATUS_PASS,
            expected=f"metallic_gap_ratio<={METALLIC_GARBAGE_WARN_RATIO:.0%}",
            actual=f"{ratio:.1%}",
            message="No significant metallic garbage in texture gaps",
            details={
                "metallic_gap_ratio": round(ratio, 4),
                "metallic_pixels": metallic_count,
                "gap_pixels": gap_count,
            },
        )


def main():
    parser = base_arg_parser("Validate final GLB asset")
    args = parser.parse_args()

    glb_path = args.input
    if not os.path.exists(glb_path):
        print(f"Error: file not found: {glb_path}", file=sys.stderr)
        sys.exit(2)

    thresholds = get_thresholds(args.asset_type)
    if args.target_verts is not None:
        thresholds = dict(thresholds)
        thresholds["target_verts"] = args.target_verts
    if args.target_height is not None:
        thresholds = dict(thresholds) if not isinstance(thresholds, dict) else thresholds
        thresholds["target_height"] = args.target_height

    # Load with both trimesh (geometry) and pygltflib (materials)
    mesh = _load_mesh(glb_path)
    gltf = GLTF2().load(glb_path)

    report = GateReport("final_asset", args.asset_name)

    check_vertex_count(report, mesh, thresholds)
    check_material_metallic(report, gltf)
    check_material_roughness(report, gltf)
    check_double_sided(report, gltf)
    check_texture_pot(report, gltf)
    check_texture_quality(report, gltf)
    check_uv_fragmentation(report, mesh)
    check_texture_desaturation(report, gltf, mesh)
    check_armature(report, gltf, args.asset_type, thresholds)
    check_weight_coverage(report, gltf)
    check_scale(report, mesh, thresholds)
    check_file_size(report, glb_path, thresholds)
    check_lods(report, glb_path, len(mesh.vertices))
    check_shadow_geometry(report, glb_path)
    check_normal_consistency(report, glb_path)

    finish(report, "stage6-final", args)


if __name__ == "__main__":
    main()
