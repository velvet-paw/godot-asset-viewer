---
name: validate-mask
description: Validates masked (background-removed) images for 3D asset generation — alpha coverage, edge quality, remnant detection. Run after Stage 2 (mask/background removal) to catch bad masks early.
allowed-tools: shell
---

# Validate Mask

## Purpose

Validates masked PNG images (RGBA with alpha channel) produced by Stage 2 (BiRefNet background removal) before they are sent to Trellis2 for 3D generation. Catching bad masks early prevents wasted GPU time on 3D generation from images with missing subjects, harsh edges, or incomplete background removal.

## Usage

```bash
python3 pipeline/gates/gate2_mask.py <image_path> --asset-name <name>
```

### Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `<image_path>` | Yes | Path to the masked PNG file (must be RGBA) |
| `--asset-name` | No | Asset name for report metadata (default: `asset`) |
| `--asset-type` | No | Asset type: creature, humanoid, prop, weapon (default: `creature`) |
| `--output` | No | Write JSON report to file instead of stdout |
| `--log` | No | Validation log path (default: `~/assets/validation_log.txt`) |

### Examples

```bash
# Validate a masked image, print JSON to stdout
python3 pipeline/gates/gate2_mask.py ~/assets/masked/goblin_masked.png --asset-name goblin

# Write report to file
python3 pipeline/gates/gate2_mask.py ~/assets/masked/sword_masked.png \
  --asset-name sword --asset-type weapon \
  --output ~/assets/reports/sword_mask_report.json
```

## Checks Performed

| Check | Status | Condition | Description |
|-------|--------|-----------|-------------|
| `has_alpha` | FAIL | Image has no alpha channel | Image must be RGBA. An RGB-only image has no mask. |
| `alpha_coverage` | FAIL | Coverage < 15% | Subject is tiny or missing entirely. |
| `alpha_coverage` | WARN | Coverage < 20% or > 80% | Subject may be too small or background not fully removed. |
| `alpha_coverage` | PASS | 20–80% | Healthy subject-to-background ratio. |
| `edge_quality` | WARN | > 5% of edge pixels have gradient > 200 | Harsh, jagged alpha transitions with no anti-aliasing. Trellis2 may produce artifacts along edges. |
| `edge_quality` | PASS | ≤ 5% harsh edge pixels | Smooth alpha transitions. |
| `background_remnants` | WARN | > 5% of transparent pixels have luminance > 30 | RGB data leaking through transparent regions. Indicates incomplete background removal. |
| `background_remnants` | PASS | ≤ 5% bright transparent pixels | Clean transparent regions. |

## Interpreting the JSON Output

```json
{
  "gate": "mask_quality",
  "asset": "goblin",
  "verdict": "pass",
  "score": 100,
  "timestamp": "2025-01-15T12:00:00+00:00",
  "checks": [
    {
      "name": "has_alpha",
      "status": "PASS",
      "expected": "RGBA image",
      "actual": "RGBA (4 channels)",
      "message": "Image has alpha channel"
    },
    {
      "name": "alpha_coverage",
      "status": "PASS",
      "expected": "20-80%",
      "actual": "42.3%",
      "message": "Subject covers 42.3% of image area"
    }
  ]
}
```

| Field | Description |
|-------|-------------|
| `verdict` | Overall result: `pass`, `warn`, or `fail` |
| `score` | 0–100 quality score (FAIL=0, WARN=50, PASS=100 per check) |
| `checks` | Array of individual check results with status, expected/actual values |
| `remediation` | Present only on FAIL — suggests which pipeline stage to re-run |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | PASS — mask is ready for Trellis2 |
| 1 | WARN — mask may produce suboptimal results |
| 2 | FAIL — mask must be regenerated before proceeding |

## Common Failures and Remediation

| Failure | Likely Cause | Fix |
|---------|-------------|-----|
| `has_alpha` FAIL | Input is a JPEG or RGB PNG | Re-run Stage 2 (BiRefNet) — ensure output format is RGBA PNG |
| `alpha_coverage` FAIL (< 15%) | BiRefNet failed to detect the subject, or concept image has a tiny subject | Re-run Stage 1 with a centered, larger subject in the prompt; then re-run Stage 2 |
| `alpha_coverage` WARN (> 80%) | Background removal was too conservative | Re-run Stage 2 with a lower mask threshold |
| `edge_quality` WARN | BiRefNet produced a binary mask without feathering | Re-run Stage 2 with anti-aliased output; or apply a 1px Gaussian blur to the alpha channel |
| `background_remnants` WARN | Background color bleeding into transparent areas | Re-run Stage 2 with stricter thresholds; or post-process with alpha premultiplication |
