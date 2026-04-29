#!/usr/bin/env bash
# stage6-blender.sh — Blender post-processing via MCP (thin wrapper)
#
# Imports a raw GLB, decimates, UV unwraps, applies PBR maps, and
# exports a final game-ready GLB — all via the Blender MCP server.
#
# Usage: ./stage6-blender.sh [glb_filename] [asset_name] [mcp_url]

set -euo pipefail

export GLB_INPUT="${1:-asset_00001_.glb}"
export ASSET_NAME="${2:-asset}"
export MCP_URL="${3:-http://localhost:8000}"

SCRIPT_DIR="$(dirname "$0")"

echo "=== Stage 6: Blender Post-Processing (MCP) ==="
echo "MCP:   $MCP_URL"
echo "Input: $GLB_INPUT"
echo "Asset: $ASSET_NAME"

# Initialize MCP session (shared by all sub-stages)
source "${SCRIPT_DIR}/stage6-common.sh"
export MCP_SESSION_ID

# Start timing
export T0
T0=$(date +%s)

# --- Run sub-stages in order ---

run_stage() {
    local script="$1"
    local label="$2"
    if ! "${SCRIPT_DIR}/${script}" "$GLB_INPUT" "$ASSET_NAME" "$MCP_URL"; then
        echo ""
        echo "❌ FAILED at: ${label}"
        exit 1
    fi
}

run_stage "stage6a-import.sh"    "Import & Repair"
run_stage "stage6b-geometry.sh"  "Decimate & Scale"
run_stage "stage6c-materials.sh" "Materials & Textures"
run_stage "stage6d-rig.sh"       "Rigging & Weights"
run_stage "stage6e-export.sh"    "Export & Validate"
