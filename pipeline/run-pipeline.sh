#!/usr/bin/env bash
# run-pipeline.sh — Full pipeline: concept → mask → 3D → PBR
# Usage: ./pipeline/run-pipeline.sh [prompt]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROMPT="${1:-a medieval sword with ornate crossguard, game asset, orthographic view, plain background}"
GPU_URL="${COMFYUI_URL:-http://localhost:8188}"

echo "╔══════════════════════════════════════════════════╗"
echo "║  ComfyUI Pipeline E2E Test                      ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "Prompt: $PROMPT"
echo "ComfyUI: $GPU_URL"
echo ""

# --- Health check ---
echo "── Checking ComfyUI container ──"
if curl -sf "$GPU_URL/system_stats" >/dev/null 2>&1; then
    echo "  ✅ $GPU_URL healthy"
else
    echo "  ❌ $GPU_URL unreachable"
    exit 1
fi
echo ""

PASSED=0
FAILED=0
TIMES=""

# --- Stage 1: Concept art ---
echo "── Stage 1: Concept Art (Flux.1 Dev) ──"
T0=$(date +%s)
if bash "$SCRIPT_DIR/stage1-concept.sh" "$PROMPT" "$GPU_URL" 2>&1; then
    T1=$(date +%s)
    DT=$((T1 - T0))
    TIMES="$TIMES Stage1:${DT}s"
    PASSED=$((PASSED + 1))
    echo "  ⏱ ${DT}s"
else
    FAILED=$((FAILED + 1))
    echo "  ❌ Stage 1 FAILED"
fi
echo ""

# Find the concept image
CONCEPT=$(ls -t ~/assets/concepts/concept_*.png 2>/dev/null | head -1)
if [ -z "$CONCEPT" ]; then
    echo "❌ No concept image found, cannot continue"
    exit 1
fi
CONCEPT_NAME=$(basename "$CONCEPT")

# --- Stage 2: Background removal ---
echo "── Stage 2: Background Removal (BiRefNet-HR) ──"
T0=$(date +%s)
if bash "$SCRIPT_DIR/stage2-mask.sh" "$CONCEPT_NAME" "$GPU_URL" 2>&1; then
    T1=$(date +%s)
    DT=$((T1 - T0))
    TIMES="$TIMES Stage2:${DT}s"
    PASSED=$((PASSED + 1))
    echo "  ⏱ ${DT}s"
else
    FAILED=$((FAILED + 1))
    echo "  ❌ Stage 2 FAILED"
fi
echo ""

# Find the masked image
MASKED=$(ls -t ~/assets/masked/masked_*.png 2>/dev/null | head -1)
MASKED_NAME=$(basename "$MASKED")

# --- Stage 3: Image to 3D ---
echo "── Stage 3: Image to 3D (Trellis2) ──"
T0=$(date +%s)
if bash "$SCRIPT_DIR/stage3-3d.sh" "$MASKED_NAME" "$GPU_URL" 2>&1; then
    T1=$(date +%s)
    DT=$((T1 - T0))
    TIMES="$TIMES Stage3:${DT}s"
    PASSED=$((PASSED + 1))
    echo "  ⏱ ${DT}s"
else
    FAILED=$((FAILED + 1))
    echo "  ❌ Stage 3 FAILED"
fi
echo ""

# --- Stage 4-5: PBR decomposition ---
echo "── Stage 4-5: PBR Decomposition (CHORD) ──"
T0=$(date +%s)
if bash "$SCRIPT_DIR/stage4-pbr.sh" "$CONCEPT_NAME" "$GPU_URL" 2>&1; then
    T1=$(date +%s)
    DT=$((T1 - T0))
    TIMES="$TIMES Stage4-5:${DT}s"
    PASSED=$((PASSED + 1))
    echo "  ⏱ ${DT}s"
else
    FAILED=$((FAILED + 1))
    echo "  ❌ Stage 4-5 FAILED"
fi
echo ""

# --- Summary ---
echo "╔══════════════════════════════════════════════════╗"
echo "║  Results: $PASSED passed, $FAILED failed              ║"
echo "╚══════════════════════════════════════════════════╝"
echo "Timing: $TIMES"
echo ""
echo "Outputs:"
ls -lh ~/assets/concepts/concept_*.png 2>/dev/null | tail -1
ls -lh ~/assets/masked/masked_*.png 2>/dev/null | tail -1
ls -lh ~/assets/raw_3d/*.glb 2>/dev/null | tail -1
ls -lh ~/assets/pbr_maps/pbr_*.png 2>/dev/null

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
