#!/usr/bin/env bash
# optimize-for-web.sh — Optimize GLB assets for web/desktop using gltf-transform
#
# Godot 4.6 compatible: NO quantize, NO WebP-in-GLB, NO Draco, NO KTX2, NO meshopt
# Safe operations: resize textures (PNG), simplify mesh, dedup, prune
#
# Usage:
#   ./pipeline/optimize-for-web.sh <input.glb> [output.glb] [--quality web|desktop|source]
#
# Quality presets:
#   web      (default) — 512px textures, simplify 0.25, targets <2 MB
#   desktop  — 1024px textures, simplify 0.5, targets <5 MB
#   source   — no optimization (copy as-is)
#
# Requirements: npx, @gltf-transform/cli (v4+), sharp (npm)
#
# IMPORTANT: For best results, use LOD2 output from Stage 6 as input (already
# decimated by Blender). gltf-transform simplify cannot effectively reduce
# raw Trellis2 meshes below ~300K verts due to triangle-soup topology.

set -euo pipefail

# --- Defaults ---
QUALITY="${QUALITY:-web}"
INPUT=""
OUTPUT=""
TEXTURE_SIZE=""
SIMPLIFY_RATIO=""
VERBOSE="${VERBOSE:-0}"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quality)
            QUALITY="$2"
            shift 2
            ;;
        --texture-size)
            TEXTURE_SIZE="$2"
            shift 2
            ;;
        --simplify-ratio)
            SIMPLIFY_RATIO="$2"
            shift 2
            ;;
        --verbose|-v)
            VERBOSE=1
            shift
            ;;
        --help|-h)
            head -17 "$0" | tail -15
            echo ""
            echo "Environment variables:"
            echo "  QUALITY=web|desktop|source    Quality preset (default: web)"
            echo "  TEXTURE_SIZE=512              Override texture resize dimension"
            echo "  SIMPLIFY_RATIO=0.25           Override simplify ratio (0.0-1.0)"
            echo "  VERBOSE=1                     Show gltf-transform output"
            exit 0
            ;;
        -*)
            echo "ERROR: Unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [[ -z "$INPUT" ]]; then
                INPUT="$1"
            elif [[ -z "$OUTPUT" ]]; then
                OUTPUT="$1"
            else
                echo "ERROR: Unexpected argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# --- Validate ---
if [[ -z "$INPUT" ]]; then
    echo "ERROR: No input file specified" >&2
    echo "Usage: $0 <input.glb> [output.glb] [--quality web|desktop|source]" >&2
    exit 1
fi

if [[ ! -f "$INPUT" ]]; then
    echo "ERROR: Input file not found: $INPUT" >&2
    exit 1
fi

# Default output name
if [[ -z "$OUTPUT" ]]; then
    BASENAME=$(basename "$INPUT" .glb)
    OUTPUT="$(dirname "$INPUT")/${BASENAME}_${QUALITY}.glb"
fi

# --- Quality presets ---
case "$QUALITY" in
    web)
        TEXTURE_SIZE="${TEXTURE_SIZE:-512}"
        SIMPLIFY_RATIO="${SIMPLIFY_RATIO:-0.25}"
        ;;
    desktop)
        TEXTURE_SIZE="${TEXTURE_SIZE:-1024}"
        SIMPLIFY_RATIO="${SIMPLIFY_RATIO:-0.5}"
        ;;
    source)
        echo "Quality: source — copying as-is"
        cp "$INPUT" "$OUTPUT"
        echo "Output: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
        exit 0
        ;;
    *)
        echo "ERROR: Unknown quality preset: $QUALITY (use web|desktop|source)" >&2
        exit 1
        ;;
esac

# --- Check dependencies ---
if ! command -v npx &>/dev/null; then
    echo "ERROR: npx not found. Install Node.js" >&2
    exit 1
fi

GLTF_CMD="npx @gltf-transform/cli"
if ! $GLTF_CMD --version &>/dev/null; then
    echo "ERROR: @gltf-transform/cli not available. Run: npm install -g @gltf-transform/cli" >&2
    exit 1
fi

# --- Optimization pipeline ---
INPUT_SIZE=$(du -b "$INPUT" | cut -f1)
INPUT_SIZE_H=$(du -h "$INPUT" | cut -f1)
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Optimizing: $(basename "$INPUT") ($INPUT_SIZE_H)"
echo "Quality:    $QUALITY (tex=${TEXTURE_SIZE}px, simplify=${SIMPLIFY_RATIO})"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

REDIR="/dev/null"
[[ "$VERBOSE" == "1" ]] && REDIR="/dev/stderr"

CURRENT="$INPUT"

# Step 1: Strip metallicRoughness texture (prevents shiny artifacts from UV distortion)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRIP_SCRIPT="$SCRIPT_DIR/strip-metalrough.mjs"
if [[ -f "$STRIP_SCRIPT" ]]; then
    echo -n "  [1/4] Strip metallicRoughness... "
    NEXT="$TMPDIR/step1_strip.glb"
    node "$STRIP_SCRIPT" "$CURRENT" "$NEXT" > "$REDIR" 2>&1
    STEP1_SIZE=$(du -h "$NEXT" | cut -f1)
    echo "done ($STEP1_SIZE)"
    CURRENT="$NEXT"
else
    echo "  [1/4] Strip metallicRoughness... SKIP (script not found)"
fi

# Step 2: Resize textures
echo -n "  [2/4] Resize textures to ${TEXTURE_SIZE}px... "
NEXT="$TMPDIR/step2_resize.glb"
$GLTF_CMD resize --width "$TEXTURE_SIZE" --height "$TEXTURE_SIZE" "$CURRENT" "$NEXT" > "$REDIR" 2>&1
STEP2_SIZE=$(du -h "$NEXT" | cut -f1)
echo "done ($STEP2_SIZE)"
CURRENT="$NEXT"

# Step 3: Simplify mesh
echo -n "  [3/4] Simplify mesh (ratio=${SIMPLIFY_RATIO})... "
NEXT="$TMPDIR/step3_simplify.glb"
$GLTF_CMD simplify --ratio "$SIMPLIFY_RATIO" --error 1.0 "$CURRENT" "$NEXT" > "$REDIR" 2>&1
STEP3_SIZE=$(du -h "$NEXT" | cut -f1)
echo "done ($STEP3_SIZE)"
CURRENT="$NEXT"

# Step 4: Dedup + Prune
echo -n "  [4/4] Dedup + Prune... "
NEXT="$TMPDIR/step4_dedup.glb"
$GLTF_CMD dedup "$CURRENT" "$NEXT" > "$REDIR" 2>&1
CURRENT="$NEXT"
NEXT="$TMPDIR/step4_prune.glb"
$GLTF_CMD prune "$CURRENT" "$NEXT" > "$REDIR" 2>&1
STEP3_SIZE=$(du -h "$NEXT" | cut -f1)
echo "done ($STEP3_SIZE)"
CURRENT="$NEXT"

# Copy to output
cp "$CURRENT" "$OUTPUT"

# --- Report ---
OUTPUT_SIZE=$(du -b "$OUTPUT" | cut -f1)
OUTPUT_SIZE_H=$(du -h "$OUTPUT" | cut -f1)
REDUCTION=$(( (INPUT_SIZE - OUTPUT_SIZE) * 100 / INPUT_SIZE ))

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Output:     $OUTPUT ($OUTPUT_SIZE_H)"
echo "Reduction:  ${INPUT_SIZE_H} → ${OUTPUT_SIZE_H} (${REDUCTION}% smaller)"

# Size budget check
case "$QUALITY" in
    web)
        BUDGET=$((2 * 1024 * 1024))  # 2 MB
        BUDGET_H="2 MB"
        ;;
    desktop)
        BUDGET=$((5 * 1024 * 1024))  # 5 MB
        BUDGET_H="5 MB"
        ;;
esac

if [[ $OUTPUT_SIZE -le $BUDGET ]]; then
    echo "Budget:     ✅ PASS — under ${BUDGET_H} target"
else
    echo "Budget:     ⚠️  OVER — ${OUTPUT_SIZE_H} exceeds ${BUDGET_H} target"
    echo "            Tip: Use LOD2 as input for better mesh reduction"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
