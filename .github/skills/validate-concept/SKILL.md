---
name: validate-concept
description: Validates concept art images for 3D asset generation — resolution, subject detection, background neutrality, shadow detection. Run after Stage 1 (concept generation) to catch bad inputs early.
allowed-tools: shell
---

# Validate Concept Art

## Purpose

Validates concept art PNGs before sending to Trellis2 for 3D generation. Catches bad inputs early at Stage 1 so failed concepts don't waste GPU time in downstream stages (mask generation, 3D reconstruction, PBR texturing).

## Usage

```bash
python3 pipeline/gates/gate1_concept.py <image_path> --asset-name <name>
```

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `<image_path>` | Yes | Path to the concept art PNG |
| `--asset-name` | No | Asset name for reports (default: `asset`) |
| `--asset-type` | No | Asset type: creature, humanoid, prop, weapon (default: `creature`) |
| `--output` | No | Write JSON report to file (default: stdout) |
| `--log` | No | Validation log path (default: `~/assets/validation_log.txt`) |

**Examples:**

```bash
# Validate a concept and print JSON to stdout
python3 pipeline/gates/gate1_concept.py ~/assets/concepts/wolf_concept.png --asset-name wolf

# Save report to file
python3 pipeline/gates/gate1_concept.py ~/assets/concepts/wolf_concept.png \
  --asset-name wolf --output ~/assets/reports/wolf_concept.json
```

## Checks Performed

| Check | Status | Condition | Why It Matters |
|-------|--------|-----------|----------------|
| **resolution** | FAIL | Width or height < 512px | Trellis2 needs sufficient detail for 3D reconstruction |
| **subject_detection** | FAIL | Pixel std dev < 10 (blank/solid image) | No subject means nothing to reconstruct |
| **background_neutrality** | WARN | Corner luminance < 80 or > 200 | Non-neutral backgrounds leak into Trellis2 textures |
| **shadow_detection** | WARN | >30% of bottom 15% pixels have luminance < 50 | Shadows bake into Trellis2 mesh textures permanently |

## Interpreting JSON Output

```json
{
  "gate": "concept_quality",
  "asset": "wolf",
  "verdict": "warn",
  "score": 75,
  "timestamp": "2025-01-15T10:30:00+00:00",
  "checks": [
    {
      "name": "resolution",
      "status": "PASS",
      "expected": ">=512x512",
      "actual": "1024x1024",
      "message": "Resolution OK"
    }
  ]
}
```

**Verdicts and exit codes:**

| Verdict | Exit Code | Meaning |
|---------|-----------|---------|
| `pass` | 0 | All checks passed — safe to proceed to Stage 2 |
| `warn` | 1 | Warnings present — review before proceeding |
| `fail` | 2 | Critical issues — must regenerate concept |

**Score:** 100 = all checks pass. Each WARN halves that check's contribution; each FAIL zeroes it.

## Common Failures and Remediation

| Failure | Cause | Fix |
|---------|-------|-----|
| `resolution` FAIL | Image generated at low res | Regenerate concept at ≥512×512. Most pipelines use 1024×1024. |
| `subject_detection` FAIL | Prompt produced blank/solid output | Rewrite prompt with concrete subject description. Check ComfyUI workflow completed successfully. |
| `background_neutrality` WARN | Colored or dark background | Add `neutral grey background`, `studio lighting` to prompt. Avoid scene descriptions that generate environments. |
| `shadow_detection` WARN | Ground shadow or dark floor in concept | Add `no shadows`, `no ground shadow`, `floating` to prompt. Shadows bake permanently into Trellis2 textures. |

## Integration with Pipeline

This gate runs between Stage 1 (concept generation) and Stage 2 (mask/background removal). The orchestrator calls it automatically:

```
Stage 1 (Flux concept) → gate1_concept.py → Stage 2 (BiRefNet mask)
```

If the gate returns exit code 2 (FAIL), the orchestrator should retry Stage 1 with adjusted prompts before proceeding.
