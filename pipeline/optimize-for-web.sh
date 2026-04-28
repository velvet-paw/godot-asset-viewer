#!/usr/bin/env bash
# optimize-for-web.sh — Optimize GLB assets for web/desktop using gltf-transform
#
# Godot 4.6 compatible: NO quantize, NO WebP-in-GLB, NO Draco, NO KTX2, NO meshopt
# Safe operations: resize textures (PNG), dedup, prune
#
# IMPORTANT: All mesh decimation must be done in Blender BEFORE this script.
# gltf-transform simplify destroys normals on Trellis2 meshes, causing shiny
# artifacts. Use Blender collapse decimation (preserves UVs and normals).
#
# Usage:
#   ./pipeline/optimize-for-web.sh <input.glb> [output.glb] [--quality web|desktop|source]
#
# Quality presets:
#   web      (default) — 512px textures, targets <2 MB
#   desktop  — 1024px textures, targets <5 MB
#   source   — no optimization (copy as-is)
#
# Requirements: npx, @gltf-transform/cli (v4+)

set -euo pipefail

# --- Defaults ---
QUALITY="${QUALITY:-web}"
INPUT=""
OUTPUT=""
TEXTURE_SIZE=""
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
            echo "  STRIP_METALROUGH=0            Keep metallicRoughness texture (default: strip)"
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
        ;;
    desktop)
        TEXTURE_SIZE="${TEXTURE_SIZE:-1024}"
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
echo "Quality:    $QUALITY (tex=${TEXTURE_SIZE}px)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

REDIR="/dev/null"
[[ "$VERBOSE" == "1" ]] && REDIR="/dev/stderr"

CURRENT="$INPUT"

# Step 1: Resize textures
echo -n "  [1/4] Resize textures to ${TEXTURE_SIZE}px... "
NEXT="$TMPDIR/step1_resize.glb"
$GLTF_CMD resize --width "$TEXTURE_SIZE" --height "$TEXTURE_SIZE" "$CURRENT" "$NEXT" > "$REDIR" 2>&1
STEP1_SIZE=$(du -h "$NEXT" | cut -f1)
echo "done ($STEP1_SIZE)"
CURRENT="$NEXT"

# Step 2: Dedup + Prune
echo -n "  [2/4] Dedup + Prune... "
NEXT="$TMPDIR/step2_dedup.glb"
$GLTF_CMD dedup "$CURRENT" "$NEXT" > "$REDIR" 2>&1
CURRENT="$NEXT"
NEXT="$TMPDIR/step2_prune.glb"
$GLTF_CMD prune "$CURRENT" "$NEXT" > "$REDIR" 2>&1
STEP2_SIZE=$(du -h "$NEXT" | cut -f1)
echo "done ($STEP2_SIZE)"
CURRENT="$NEXT"

# Step 3: Strip metallicRoughness (default ON for web/desktop)
# Decimation distorts UVs enough that MR texture causes shiny brown artifacts.
# Set STRIP_METALROUGH=0 to keep the MR texture (only for undecimated meshes).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRIP_SCRIPT="$SCRIPT_DIR/strip-metalrough.mjs"
if [[ "${STRIP_METALROUGH:-1}" == "1" && -f "$STRIP_SCRIPT" ]]; then
    echo -n "  [3/4] Strip metallicRoughness + doubleSided... "
    NEXT="$TMPDIR/step3_strip.glb"
    node "$STRIP_SCRIPT" "$CURRENT" "$NEXT" > "$REDIR" 2>&1
    STEP3_SIZE=$(du -h "$NEXT" | cut -f1)
    echo "done ($STEP3_SIZE)"
    CURRENT="$NEXT"
else
    echo "  [3/4] Strip metallicRoughness... SKIP (STRIP_METALROUGH=0)"
fi

# Step 4: Set doubleSided on all materials
# Trellis2 triangle-soup meshes have gaps between disconnected triangles after
# decimation. doubleSided renders back faces, visually filling the gaps at zero
# file-size cost. Step 3 already sets this when MR stripping is on; this step
# catches the STRIP_METALROUGH=0 case.
DOUBLESIDED_SCRIPT="$SCRIPT_DIR/set-doublesided.mjs"
if [[ "${STRIP_METALROUGH:-1}" != "1" && -f "$DOUBLESIDED_SCRIPT" ]]; then
    echo -n "  [4/4] Set doubleSided... "
    NEXT="$TMPDIR/step4_doublesided.glb"
    node "$DOUBLESIDED_SCRIPT" "$CURRENT" "$NEXT" > "$REDIR" 2>&1
    echo "done"
    CURRENT="$NEXT"
else
    echo "  [4/4] Set doubleSided... (included in step 3)"
fi

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
    echo "            Tip: Use Blender collapse-decimated GLB as input"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
