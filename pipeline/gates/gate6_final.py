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
    check_armature(report, gltf, args.asset_type, thresholds)
    check_weight_coverage(report, gltf)
    check_scale(report, mesh, thresholds)
    check_file_size(report, glb_path, thresholds)
    check_lods(report, glb_path, len(mesh.vertices))

    finish(report, "stage6-final", args)


if __name__ == "__main__":
    main()
