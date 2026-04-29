#!/usr/bin/env python3
"""Gate 1: Concept art quality validation.

Validates a concept art PNG before sending to Trellis2.
Checks resolution, subject presence, background neutrality, and shadows.
"""

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "lib"))

import numpy as np
from PIL import Image

from gate_common import (
    GateReport,
    STATUS_FAIL,
    STATUS_PASS,
    STATUS_WARN,
    base_arg_parser,
    finish,
)

MIN_RESOLUTION = 512
SUBJECT_STD_THRESHOLD = 10
CORNER_LUM_LOW = 80
CORNER_LUM_HIGH = 200
SHADOW_LUM_THRESHOLD = 50
SHADOW_RATIO_THRESHOLD = 0.30
BOTTOM_FRACTION = 0.15
CORNER_FRACTION = 0.10


def check_resolution(report: GateReport, width: int, height: int):
    ok = width >= MIN_RESOLUTION and height >= MIN_RESOLUTION
    report.add_check(
        name="resolution_low" if not ok else "resolution",
        status=STATUS_PASS if ok else STATUS_FAIL,
        expected=f">={MIN_RESOLUTION}x{MIN_RESOLUTION}",
        actual=f"{width}x{height}",
        message="Resolution OK" if ok else "Image too small for Trellis2",
    )


def check_subject_detection(report: GateReport, pixels: np.ndarray):
    std = float(np.std(pixels))
    ok = std >= SUBJECT_STD_THRESHOLD
    report.add_check(
        name="blank_image" if not ok else "subject_detection",
        status=STATUS_PASS if ok else STATUS_FAIL,
        expected=f"std_dev>={SUBJECT_STD_THRESHOLD}",
        actual=f"std_dev={std:.1f}",
        message="Subject detected" if ok else "Image appears blank or solid",
    )


def check_background_neutrality(report: GateReport, grey: np.ndarray):
    h, w = grey.shape
    ch, cw = int(h * CORNER_FRACTION), int(w * CORNER_FRACTION)
    corners = [
        grey[:ch, :cw],
        grey[:ch, w - cw :],
        grey[h - ch :, :cw],
        grey[h - ch :, w - cw :],
    ]
    avg_lum = float(np.mean(np.concatenate([c.ravel() for c in corners])))
    ok = CORNER_LUM_LOW <= avg_lum <= CORNER_LUM_HIGH
    report.add_check(
        name="background_neutrality",
        status=STATUS_PASS if ok else STATUS_WARN,
        expected=f"corner_luminance {CORNER_LUM_LOW}-{CORNER_LUM_HIGH}",
        actual=f"corner_luminance={avg_lum:.0f}",
        message="Background neutral" if ok else "Background may not be neutral grey",
        details={"avg_corner_luminance": round(avg_lum, 1)},
    )


def check_shadow_detection(report: GateReport, grey: np.ndarray):
    h = grey.shape[0]
    bottom = grey[h - int(h * BOTTOM_FRACTION) :, :]
    dark_ratio = float(np.mean(bottom < SHADOW_LUM_THRESHOLD))
    ok = dark_ratio <= SHADOW_RATIO_THRESHOLD
    report.add_check(
        name="shadow_detected" if not ok else "shadow_detection",
        status=STATUS_PASS if ok else STATUS_WARN,
        expected=f"dark_ratio<={SHADOW_RATIO_THRESHOLD:.0%}",
        actual=f"dark_ratio={dark_ratio:.1%}",
        message="No problematic shadows" if ok else "Possible ground shadow detected",
        details={"dark_pixel_ratio": round(dark_ratio, 3)},
    )


def main():
    parser = base_arg_parser("Validate concept art image")
    args = parser.parse_args()

    img = Image.open(args.input).convert("RGB")
    pixels = np.asarray(img)
    grey = np.asarray(img.convert("L"))

    report = GateReport("concept_quality", args.asset_name)
    check_resolution(report, img.width, img.height)
    check_subject_detection(report, pixels)
    check_background_neutrality(report, grey)
    check_shadow_detection(report, grey)

    finish(report, "stage1", args)


if __name__ == "__main__":
    main()
