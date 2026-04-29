#!/usr/bin/env python3
"""Gate 3: Raw 3D mesh quality validation.

Validates a raw GLB from Trellis2 before expensive Stage 6 processing.
Checks vertex count, depth ratio, UV island fragmentation, texture quality,
and manifold integrity. This is the critical gate — catches vertex count
blowouts and UV fragmentation that cause "shiny artifacts" in Godot.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))

from collections import defaultdict

import numpy as np
import trimesh
from PIL import Image

from gate_common import (
    GateReport,
    STATUS_FAIL,
    STATUS_PASS,
    STATUS_WARN,
    base_arg_parser,
    finish,
    get_thresholds,
)

# Texture garbage detection thresholds
GARBAGE_WARN_RATIO = 0.02
GARBAGE_FAIL_RATIO = 0.10
LUMINANCE_DIFF_THRESHOLD = 0.15

# UV island size threshold (fraction of total UV space)
UV_ISLAND_MEDIAN_THRESHOLD = 0.001

# Alpha gap threshold
ALPHA_GAP_THRESHOLD = 0.05
ALPHA_GAP_VALUE = 0.5

# Bas-relief depth threshold
Z_DEPTH_THRESHOLD = 0.05


# ---------------------------------------------------------------------------
# Mesh helpers
# ---------------------------------------------------------------------------

def load_mesh(path: str) -> trimesh.Trimesh:
    """Load GLB and return a single merged Trimesh."""
    scene = trimesh.load(path)
    if isinstance(scene, trimesh.Trimesh):
        return scene
    if isinstance(scene, trimesh.Scene):
        if hasattr(scene, "to_geometry"):
            return scene.to_geometry()
        meshes = list(scene.geometry.values())
        if meshes:
            return trimesh.util.concatenate(meshes)
    raise ValueError(f"Could not load mesh from {path}")


# ---------------------------------------------------------------------------
# UV island counting via union-find on shared UV edges
# ---------------------------------------------------------------------------

class UnionFind:
    """Weighted quick-union with path compression."""

    def __init__(self, n: int):
        self.parent = list(range(n))
        self.rank = [0] * n

    def find(self, x: int) -> int:
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def union(self, a: int, b: int):
        ra, rb = self.find(a), self.find(b)
        if ra == rb:
            return
        if self.rank[ra] < self.rank[rb]:
            ra, rb = rb, ra
        self.parent[rb] = ra
        if self.rank[ra] == self.rank[rb]:
            self.rank[ra] += 1

    def components(self) -> int:
        return len({self.find(i) for i in range(len(self.parent))})


def _uv_key(uv: np.ndarray) -> tuple:
    """Quantize a UV coordinate to ~16-bit precision for hashing."""
    return (round(float(uv[0]), 5), round(float(uv[1]), 5))


def count_uv_islands(mesh: trimesh.Trimesh) -> tuple[int, float]:
    """Count UV islands and compute median island area in UV space.

    Two faces share a UV edge only if their shared mesh edge has identical
    UV coordinates at both endpoints. This detects fragmentation that pure
    mesh-topology adjacency would miss.

    Returns (island_count, median_island_area).
    """
    if not hasattr(mesh.visual, "uv") or mesh.visual.uv is None:
        return 0, 0.0

    uv = mesh.visual.uv
    faces = mesh.faces
    n_faces = len(faces)

    if n_faces == 0:
        return 0, 0.0

    # Build edge→face mapping using UV-space edge keys.
    # An edge key is (min_uv, max_uv) of the two UV coords at the endpoints.
    edge_to_faces: dict[tuple, list[int]] = defaultdict(list)
    for fi, face in enumerate(faces):
        for i in range(3):
            vi_a, vi_b = int(face[i]), int(face[(i + 1) % 3])
            uv_a = _uv_key(uv[vi_a])
            uv_b = _uv_key(uv[vi_b])
            edge = (min(uv_a, uv_b), max(uv_a, uv_b))
            edge_to_faces[edge].append(fi)

    # Union faces that share a UV edge
    uf = UnionFind(n_faces)
    for face_list in edge_to_faces.values():
        for i in range(1, len(face_list)):
            uf.union(face_list[0], face_list[i])

    island_count = uf.components()

    # Compute per-island UV area
    island_areas: dict[int, float] = defaultdict(float)
    for fi, face in enumerate(faces):
        a, b, c = uv[face[0]], uv[face[1]], uv[face[2]]
        area = 0.5 * abs(float(
            (b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1])
        ))
        island_areas[uf.find(fi)] += area

    areas = list(island_areas.values())
    median_area = float(np.median(areas)) if areas else 0.0

    return island_count, median_area


# ---------------------------------------------------------------------------
# Texture extraction
# ---------------------------------------------------------------------------

def extract_texture(mesh: trimesh.Trimesh) -> Image.Image | None:
    """Extract the base color texture from a mesh, if present."""
    visual = mesh.visual
    if hasattr(visual, "material"):
        mat = visual.material
        # SimpleMaterial / PBRMaterial
        if hasattr(mat, "image") and mat.image is not None:
            return mat.image
        # Try baseColorTexture for PBR
        if hasattr(mat, "baseColorTexture") and mat.baseColorTexture is not None:
            return mat.baseColorTexture
    # TextureVisuals may wrap a material
    if hasattr(visual, "material") and hasattr(visual.material, "image"):
        img = visual.material.image
        if img is not None:
            return img
    return None


# ---------------------------------------------------------------------------
# Individual checks
# ---------------------------------------------------------------------------

def check_vertex_count(report: GateReport, mesh: trimesh.Trimesh,
                       target_verts: int):
    """Check vertex count against target thresholds."""
    actual = len(mesh.vertices)
    fail_limit = target_verts * 3
    warn_limit = target_verts * 2

    if actual > fail_limit:
        status = STATUS_FAIL
        msg = (f"Vertex count {actual} exceeds 3x target ({fail_limit}) "
               f"— Trellis2 decimation failed")
    elif actual > warn_limit:
        status = STATUS_WARN
        msg = (f"Vertex count {actual} exceeds 2x target ({warn_limit}) "
               f"— higher than expected")
    else:
        status = STATUS_PASS
        msg = f"Vertex count {actual} within target range"

    report.add_check(
        name="vertex_count" if status == STATUS_PASS else "vertex_count_exceeded",
        status=status,
        expected=f"<={fail_limit}",
        actual=str(actual),
        message=msg,
        details={"vertices": actual, "target": target_verts,
                 "warn_limit": warn_limit, "fail_limit": fail_limit},
    )


def check_z_depth(report: GateReport, mesh: trimesh.Trimesh):
    """Check Z-depth ratio to detect bas-relief / flat meshes."""
    bounds = mesh.bounds
    ranges = bounds[1] - bounds[0]
    x_range, y_range, z_range = float(ranges[0]), float(ranges[1]), float(ranges[2])
    max_xy = max(x_range, y_range)

    if max_xy < 1e-6:
        report.add_check(
            name="bas_relief",
            status=STATUS_FAIL,
            expected="z_ratio>=0.05",
            actual="degenerate_bounds",
            message="Mesh has degenerate bounding box",
        )
        return

    z_ratio = z_range / max_xy

    if z_ratio < Z_DEPTH_THRESHOLD:
        status = STATUS_FAIL
        msg = f"Z-depth ratio {z_ratio:.3f} — mesh is flat (bas-relief)"
        name = "bas_relief"
    else:
        status = STATUS_PASS
        msg = "Mesh has adequate depth"
        name = "z_depth"

    report.add_check(
        name=name,
        status=status,
        expected=f"z_ratio>={Z_DEPTH_THRESHOLD}",
        actual=f"z_ratio={z_ratio:.3f}",
        message=msg,
        details={"z_range": round(z_range, 4), "max_xy": round(max_xy, 4),
                 "z_ratio": round(z_ratio, 4)},
    )


def check_uv_islands(report: GateReport, mesh: trimesh.Trimesh,
                     island_warn_threshold: int):
    """Check UV island count and median island size."""
    island_count, median_area = count_uv_islands(mesh)

    # Island count check
    if island_count == 0:
        report.add_check(
            name="uv_island_count",
            status=STATUS_WARN,
            expected=f"<={island_warn_threshold}",
            actual="0",
            message="No UV data found on mesh",
        )
        report.add_check(
            name="uv_island_size",
            status=STATUS_WARN,
            expected=f"median>={UV_ISLAND_MEDIAN_THRESHOLD}",
            actual="N/A",
            message="No UV data — cannot measure island size",
        )
        return

    if island_count > island_warn_threshold:
        status = STATUS_WARN
        msg = (f"UV island count {island_count} exceeds threshold "
               f"{island_warn_threshold} — fragmented UVs")
        name = "uv_fragmentation"
    else:
        status = STATUS_PASS
        msg = f"UV island count {island_count} within threshold"
        name = "uv_island_count"

    report.add_check(
        name=name,
        status=status,
        expected=f"<={island_warn_threshold}",
        actual=str(island_count),
        message=msg,
        details={"island_count": island_count,
                 "threshold": island_warn_threshold},
    )

    # Median island size check
    if median_area < UV_ISLAND_MEDIAN_THRESHOLD:
        size_status = STATUS_WARN
        size_msg = (f"Median UV island area {median_area:.5f} "
                    f"— very small islands")
    else:
        size_status = STATUS_PASS
        size_msg = f"Median UV island area {median_area:.5f} OK"

    report.add_check(
        name="uv_island_size",
        status=size_status,
        expected=f"median>={UV_ISLAND_MEDIAN_THRESHOLD}",
        actual=f"median={median_area:.5f}",
        message=size_msg,
        details={"median_area": round(median_area, 6)},
    )


def check_texture_alpha(report: GateReport, texture: Image.Image | None):
    """Check texture alpha coverage for gap pixels."""
    if texture is None:
        report.add_check(
            name="texture_alpha",
            status=STATUS_PASS,
            expected=f"gap_ratio<={ALPHA_GAP_THRESHOLD}",
            actual="no_texture",
            message="No texture found — alpha check skipped",
        )
        return

    if texture.mode != "RGBA":
        report.add_check(
            name="texture_alpha",
            status=STATUS_PASS,
            expected=f"gap_ratio<={ALPHA_GAP_THRESHOLD}",
            actual="no_alpha_channel",
            message="Texture has no alpha channel — no gaps",
        )
        return

    alpha = np.asarray(texture)[:, :, 3].astype(np.float32) / 255.0
    gap_ratio = float(np.mean(alpha < ALPHA_GAP_VALUE))

    if gap_ratio > ALPHA_GAP_THRESHOLD:
        status = STATUS_WARN
        msg = (f"{gap_ratio:.1%} of pixels have alpha < {ALPHA_GAP_VALUE} "
               f"— texture has gap pixels")
    else:
        status = STATUS_PASS
        msg = "Texture alpha coverage OK"

    report.add_check(
        name="texture_alpha",
        status=status,
        expected=f"gap_ratio<={ALPHA_GAP_THRESHOLD}",
        actual=f"gap_ratio={gap_ratio:.3f}",
        message=msg,
        details={"gap_ratio": round(gap_ratio, 4)},
    )


def check_texture_garbage(report: GateReport, texture: Image.Image | None):
    """Detect bright outlier pixels that indicate garbage between UV islands.

    For each pixel, compare its luminance to the average of its 4 neighbours.
    Pixels where the difference exceeds LUMINANCE_DIFF_THRESHOLD are outliers.
    A high outlier ratio means the texture is full of garbage-colored pixels
    from uninitialized UV space — the root cause of shiny artifacts.
    """
    if texture is None:
        report.add_check(
            name="texture_garbage",
            status=STATUS_PASS,
            expected=f"outlier_ratio<={GARBAGE_FAIL_RATIO}",
            actual="no_texture",
            message="No texture found — garbage check skipped",
        )
        return

    rgb = np.asarray(texture.convert("RGB")).astype(np.float32) / 255.0
    # Luminance: standard Rec. 709
    lum = 0.2126 * rgb[:, :, 0] + 0.7152 * rgb[:, :, 1] + 0.0722 * rgb[:, :, 2]

    h, w = lum.shape
    if h < 3 or w < 3:
        report.add_check(
            name="texture_garbage",
            status=STATUS_PASS,
            expected=f"outlier_ratio<={GARBAGE_FAIL_RATIO}",
            actual="texture_too_small",
            message="Texture too small for garbage detection",
        )
        return

    # 4-neighbour average (interior pixels only)
    interior = lum[1:-1, 1:-1]
    avg_neighbours = (
        lum[:-2, 1:-1] +   # top
        lum[2:, 1:-1] +    # bottom
        lum[1:-1, :-2] +   # left
        lum[1:-1, 2:]      # right
    ) / 4.0

    diff = np.abs(interior - avg_neighbours)
    outlier_count = int(np.sum(diff > LUMINANCE_DIFF_THRESHOLD))
    total_interior = interior.size
    outlier_ratio = outlier_count / total_interior if total_interior > 0 else 0.0

    if outlier_ratio > GARBAGE_FAIL_RATIO:
        status = STATUS_FAIL
        msg = (f"{outlier_ratio:.1%} of texture pixels are bright outliers "
               f"— garbage between UV islands")
        name = "texture_garbage"
    elif outlier_ratio > GARBAGE_WARN_RATIO:
        status = STATUS_WARN
        msg = (f"{outlier_ratio:.1%} of texture pixels are outliers "
               f"— some garbage present")
        name = "texture_garbage"
    else:
        status = STATUS_PASS
        msg = "Texture pixel quality OK"
        name = "texture_garbage"

    report.add_check(
        name=name,
        status=status,
        expected=f"outlier_ratio<={GARBAGE_FAIL_RATIO}",
        actual=f"outlier_ratio={outlier_ratio:.4f}",
        message=msg,
        details={"outlier_ratio": round(outlier_ratio, 5),
                 "outlier_pixels": outlier_count,
                 "total_interior_pixels": total_interior},
    )


def check_manifold(report: GateReport, mesh: trimesh.Trimesh):
    """Check if mesh is watertight (manifold)."""
    is_watertight = bool(mesh.is_watertight)

    report.add_check(
        name="manifold_check",
        status=STATUS_PASS if is_watertight else STATUS_WARN,
        expected="watertight",
        actual="watertight" if is_watertight else "non-manifold",
        message="Mesh is watertight" if is_watertight else "Mesh has non-manifold edges",
        details={"is_watertight": is_watertight},
    )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = base_arg_parser("Validate raw 3D mesh")
    args = parser.parse_args()

    if not os.path.isfile(args.input):
        print(f"Error: file not found: {args.input}", file=sys.stderr)
        sys.exit(2)

    thresholds = get_thresholds(args.asset_type)
    target_verts = args.target_verts or thresholds["target_verts"]
    island_warn = thresholds.get("uv_island_warn", 500)

    mesh = load_mesh(args.input)
    texture = extract_texture(mesh)

    report = GateReport("mesh_quality", args.asset_name)

    check_vertex_count(report, mesh, target_verts)
    check_z_depth(report, mesh)
    check_uv_islands(report, mesh, island_warn)
    check_texture_alpha(report, texture)
    check_texture_garbage(report, texture)
    check_manifold(report, mesh)

    finish(report, "stage3", args)


if __name__ == "__main__":
    main()
