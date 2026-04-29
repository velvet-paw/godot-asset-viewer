#!/usr/bin/env python3
"""Gate 2 — Validate masked (background-removed) PNG for Trellis2 readiness.

Checks alpha coverage, edge quality, and background remnants on an RGBA image
produced by Stage 2 (BiRefNet background removal).
"""

import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))
from gate_common import (
    GateReport,
    STATUS_FAIL,
    STATUS_PASS,
    STATUS_WARN,
    base_arg_parser,
    finish,
)


def check_has_alpha(report: GateReport, img: Image.Image) -> bool:
    """Verify the image has an alpha channel. Returns True if RGBA."""
    if img.mode == "RGBA":
        report.add_check(
            name="has_alpha",
            status=STATUS_PASS,
            expected="RGBA image",
            actual=f"RGBA ({len(img.getbands())} channels)",
            message="Image has alpha channel",
        )
        return True

    report.add_check(
        name="has_alpha",
        status=STATUS_FAIL,
        expected="RGBA image",
        actual=f"{img.mode} ({len(img.getbands())} channels)",
        message=f"Image is {img.mode}, missing alpha channel",
    )
    return False


def check_alpha_coverage(report: GateReport, alpha: np.ndarray) -> None:
    """Check that the subject occupies a reasonable portion of the image."""
    total_pixels = alpha.size
    subject_pixels = int(np.count_nonzero(alpha >= 128))
    coverage = subject_pixels / total_pixels * 100

    if coverage < 15:
        status = STATUS_FAIL
        message = f"Subject covers only {coverage:.1f}% — too small or missing"
    elif coverage < 20:
        status = STATUS_WARN
        message = f"Subject covers {coverage:.1f}% — may be too small for Trellis2"
    elif coverage > 80:
        status = STATUS_WARN
        message = f"Subject covers {coverage:.1f}% — background may not be fully removed"
    else:
        status = STATUS_PASS
        message = f"Subject covers {coverage:.1f}% of image area"

    report.add_check(
        name="alpha_coverage",
        status=status,
        expected="20-80%",
        actual=f"{coverage:.1f}%",
        message=message,
        details={"subject_pixels": subject_pixels, "total_pixels": total_pixels},
    )


def check_edge_quality(report: GateReport, alpha: np.ndarray) -> None:
    """Detect jagged alpha transitions via gradient magnitude."""
    alpha_f = alpha.astype(np.float64)
    gx = ndimage.sobel(alpha_f, axis=1)
    gy = ndimage.sobel(alpha_f, axis=0)
    gradient = np.hypot(gx, gy)

    edge_mask = gradient > 0
    edge_count = int(np.count_nonzero(edge_mask))
    if edge_count == 0:
        report.add_check(
            name="edge_quality",
            status=STATUS_WARN,
            expected="Anti-aliased edges",
            actual="No edges detected",
            message="No alpha transitions found — image may be fully opaque or transparent",
        )
        return

    harsh_pixels = int(np.count_nonzero(gradient > 200))
    harsh_pct = harsh_pixels / edge_count * 100

    if harsh_pct > 5:
        status = STATUS_WARN
        message = (
            f"{harsh_pct:.1f}% of edge pixels have harsh transitions "
            f"(gradient > 200) — may cause Trellis2 artifacts"
        )
    else:
        status = STATUS_PASS
        message = f"Edge quality good — {harsh_pct:.1f}% harsh edge pixels"

    report.add_check(
        name="edge_quality",
        status=status,
        expected="≤5% harsh edge pixels",
        actual=f"{harsh_pct:.1f}%",
        message=message,
        details={"edge_pixels": edge_count, "harsh_pixels": harsh_pixels},
    )


def check_background_remnants(report: GateReport, img_array: np.ndarray) -> None:
    """Check for non-black RGB data in fully transparent regions."""
    alpha = img_array[:, :, 3]
    rgb = img_array[:, :, :3]

    transparent_mask = alpha == 0
    transparent_count = int(np.count_nonzero(transparent_mask))

    if transparent_count == 0:
        report.add_check(
            name="background_remnants",
            status=STATUS_WARN,
            expected="Some transparent pixels",
            actual="0 transparent pixels",
            message="No fully transparent pixels — background may not be removed",
        )
        return

    transparent_rgb = rgb[transparent_mask]
    luminance = (
        0.2126 * transparent_rgb[:, 0]
        + 0.7152 * transparent_rgb[:, 1]
        + 0.0722 * transparent_rgb[:, 2]
    )
    bright_pixels = int(np.count_nonzero(luminance > 30))
    bright_pct = bright_pixels / transparent_count * 100

    if bright_pct > 5:
        status = STATUS_WARN
        message = (
            f"{bright_pct:.1f}% of transparent pixels have luminance > 30 "
            f"— background color leaking through"
        )
    else:
        status = STATUS_PASS
        message = f"Transparent regions clean — {bright_pct:.1f}% bright pixels"

    report.add_check(
        name="background_remnants",
        status=status,
        expected="≤5% bright transparent pixels",
        actual=f"{bright_pct:.1f}%",
        message=message,
        details={
            "transparent_pixels": transparent_count,
            "bright_pixels": bright_pixels,
        },
    )


def main() -> None:
    parser = base_arg_parser("Validate masked image")
    args = parser.parse_args()

    if not os.path.isfile(args.input):
        print(f"Error: file not found: {args.input}", file=sys.stderr)
        sys.exit(2)

    img = Image.open(args.input)
    report = GateReport("mask_quality", args.asset_name)

    has_alpha = check_has_alpha(report, img)
    if not has_alpha:
        finish(report, "stage2", args)
        return

    img_array = np.array(img)
    alpha = img_array[:, :, 3]

    check_alpha_coverage(report, alpha)
    check_edge_quality(report, alpha)
    check_background_remnants(report, img_array)

    finish(report, "stage2", args)


if __name__ == "__main__":
    main()
