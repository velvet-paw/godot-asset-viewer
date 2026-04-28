#!/usr/bin/env bash
# generate-asset-tiers.sh — Generate source, desktop, and web GLBs from a raw Trellis2 asset
#
# Runs Stage 6 three times with different vertex targets, then optimizes each tier.
# Produces three files ready for game use.
#
# Usage:
#   ./pipeline/generate-asset-tiers.sh <input_glb> <asset_name> [asset_type]
#
# Example:
#   ./pipeline/generate-asset-tiers.sh wild_boar_00001_.glb wild_boar creature
#
# Outputs:
#   ~/assets/final_glb/{asset}_source.glb    — High-res archival (150K verts, original textures)
#   ~/assets/final_glb/{asset}_desktop.glb   — Desktop game (50K verts, 1024px textures, <5 MB target)
#   ~/assets/final_glb/{asset}_web.glb       — Web game (20K verts, 512px textures, <2 MB target)
#
# Environment:
#   MCP_URL       — Blender MCP URL (default: http://localhost:8000)
#   SKIP_RIGGING  — Set 1 to skip auto-rigging (saves file size)
#   SOURCE_VERTS  — Override source tier verts (default: 150000)
#   DESKTOP_VERTS — Override desktop tier verts (default: 50000)
#   WEB_VERTS     — Override web tier verts (default: 20000)

set -euo pipefail

GLB_INPUT="${1:?Usage: generate-asset-tiers.sh <input_glb> <asset_name> [asset_type]}"
ASSET_NAME="${2:?Usage: generate-asset-tiers.sh <input_glb> <asset_name> [asset_type]}"
ASSET_TYPE="${3:-creature}"
MCP_URL="${MCP_URL:-http://localhost:8000}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FINAL_DIR="${HOME}/assets/final_glb"

# Vertex targets per tier
SOURCE_VERTS="${SOURCE_VERTS:-150000}"
DESKTOP_VERTS="${DESKTOP_VERTS:-30000}"
WEB_VERTS="${WEB_VERTS:-15000}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Generating 3-tier asset: ${ASSET_NAME}"
echo "Input:  ${GLB_INPUT}"
echo "Type:   ${ASSET_TYPE}"
echo "Tiers:  source=${SOURCE_VERTS} | desktop=${DESKTOP_VERTS} | web=${WEB_VERTS}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

FAILED=0

# --- Tier 1: Source (high-res archival) ---
echo ""
echo "╭─── Tier 1: SOURCE (${SOURCE_VERTS} verts) ───╮"
if ASSET_TYPE="${ASSET_TYPE}" TARGET_VERTS="${SOURCE_VERTS}" \
   "${SCRIPT_DIR}/stage6-blender.sh" "${GLB_INPUT}" "${ASSET_NAME}" "${MCP_URL}"; then
    mv "${FINAL_DIR}/${ASSET_NAME}_final.glb" "${FINAL_DIR}/${ASSET_NAME}_source.glb"
    SOURCE_SIZE=$(stat -c%s "${FINAL_DIR}/${ASSET_NAME}_source.glb" 2>/dev/null || echo 0)
    echo "╰─── ✅ Source: $(numfmt --to=iec ${SOURCE_SIZE}) ───╯"
else
    echo "╰─── ❌ Source tier FAILED ───╯"
    FAILED=$((FAILED + 1))
fi

# --- Tier 2: Desktop ---
echo ""
echo "╭─── Tier 2: DESKTOP (${DESKTOP_VERTS} verts, 1024px) ───╮"
if ASSET_TYPE="${ASSET_TYPE}" TARGET_VERTS="${DESKTOP_VERTS}" \
   "${SCRIPT_DIR}/stage6-blender.sh" "${GLB_INPUT}" "${ASSET_NAME}" "${MCP_URL}"; then
    # Optimize textures for desktop
    QUALITY=desktop "${SCRIPT_DIR}/optimize-for-web.sh" \
        "${FINAL_DIR}/${ASSET_NAME}_final.glb" \
        "${FINAL_DIR}/${ASSET_NAME}_desktop.glb"
    rm -f "${FINAL_DIR}/${ASSET_NAME}_final.glb"
    DESKTOP_SIZE=$(stat -c%s "${FINAL_DIR}/${ASSET_NAME}_desktop.glb" 2>/dev/null || echo 0)
    echo "╰─── ✅ Desktop: $(numfmt --to=iec ${DESKTOP_SIZE}) (target <5 MB) ───╯"
else
    echo "╰─── ❌ Desktop tier FAILED ───╯"
    FAILED=$((FAILED + 1))
fi

# --- Tier 3: Web ---
echo ""
echo "╭─── Tier 3: WEB (${WEB_VERTS} verts, 512px, no rigging) ───╮"
if ASSET_TYPE="${ASSET_TYPE}" TARGET_VERTS="${WEB_VERTS}" SKIP_RIGGING=1 \
   "${SCRIPT_DIR}/stage6-blender.sh" "${GLB_INPUT}" "${ASSET_NAME}" "${MCP_URL}"; then
    # Optimize textures for web
    QUALITY=web "${SCRIPT_DIR}/optimize-for-web.sh" \
        "${FINAL_DIR}/${ASSET_NAME}_final.glb" \
        "${FINAL_DIR}/${ASSET_NAME}_web.glb"
    rm -f "${FINAL_DIR}/${ASSET_NAME}_final.glb"
    WEB_SIZE=$(stat -c%s "${FINAL_DIR}/${ASSET_NAME}_web.glb" 2>/dev/null || echo 0)
    echo "╰─── ✅ Web: $(numfmt --to=iec ${WEB_SIZE}) (target <2 MB) ───╯"
else
    echo "╰─── ❌ Web tier FAILED ───╯"
    FAILED=$((FAILED + 1))
fi

# --- Summary ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Results:"
for tier in source desktop web; do
    FILE="${FINAL_DIR}/${ASSET_NAME}_${tier}.glb"
    if [[ -f "$FILE" ]]; then
        SIZE=$(stat -c%s "$FILE")
        printf "  %-8s  %s  (%s)\n" "${tier}" "$(numfmt --to=iec ${SIZE})" "${FILE}"
    else
        printf "  %-8s  ❌ MISSING\n" "${tier}"
    fi
done
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $FAILED -gt 0 ]]; then
    echo "⚠ ${FAILED} tier(s) failed"
    exit 1
fi
echo "✅ All tiers generated successfully"
