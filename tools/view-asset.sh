#!/usr/bin/env bash
# Quick launcher: import a generated asset and open it in the Asset Viewer
set -euo pipefail

ASSET_NAME="${1:-}"

if [[ -z "$ASSET_NAME" ]]; then
    echo "Usage: ./tools/view-asset.sh <asset_name>"
    echo ""
    echo "Example: ./tools/view-asset.sh humpty_dumpty"
    echo ""
    echo "This will:"
    echo "  1. Import the asset from ~/assets/final_glb/ into the Godot project"
    echo "  2. Launch the Asset Viewer scene with Godot"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Step 1: Import asset from pipeline
echo "📦 Importing ${ASSET_NAME}..."
"$SCRIPT_DIR/import-asset.sh" "$ASSET_NAME"

# Step 2: Launch Asset Viewer
echo ""
echo "🚀 Launching Asset Viewer..."
"$SCRIPT_DIR/godot.sh" --scene res://ui/asset_viewer/AssetViewer.tscn
