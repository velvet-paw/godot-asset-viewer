#!/usr/bin/env bash
# screenshot-asset.sh — Import a 3D asset into Godot and capture a screenshot
#
# Usage: screenshot-asset.sh <asset_name> [glb_resource_path]
#
# Handles the full lifecycle:
#   1. Import asset from ~/assets/final_glb/ into the Godot project
#   2. Run Godot headless import pass
#   3. Launch AssetViewer (or reuse running instance)
#   4. Load the GLB via DevTools
#   5. Take a screenshot
#   6. Print the screenshot path
set -euo pipefail

ASSET_NAME="${1:-}"
PROJECT_DIR="/home/kaze/code/asset-viewer"
SCREENSHOT_DIR="/home/kaze/.local/share/godot/app_userdata/GodotAssetViewer"
GODOT_LOG="/tmp/godot-asset-viewer.log"

if [[ -z "$ASSET_NAME" ]]; then
    echo "Usage: $0 <asset_name> [glb_resource_path]" >&2
    echo "Example: $0 wolf" >&2
    echo "Example: $0 wolf res://actors/wolf/wolf_lod1.glb" >&2
    exit 1
fi

GLB_PATH="${2:-res://actors/${ASSET_NAME}/${ASSET_NAME}_final.glb}"

# ── Environment setup ──
export PATH="$HOME/.dotnet:$PATH"
export DOTNET_ROOT="$HOME/.dotnet"

cd "$PROJECT_DIR"

# Resolve Godot executable
resolve_godot() {
    if [[ -n "${GODOT4_MONO_EXE:-}" ]] && [[ -x "$GODOT4_MONO_EXE" ]]; then
        echo "$GODOT4_MONO_EXE"; return
    fi
    for cmd in godot godot4; do
        if command -v "$cmd" &>/dev/null; then echo "$cmd"; return; fi
    done
    if [[ -x "$HOME/.local/bin/godot" ]]; then
        echo "$HOME/.local/bin/godot"; return
    fi
    echo "ERROR: Godot not found" >&2; exit 1
}
GODOT=$(resolve_godot)

echo "── Step 1: Import asset files ──"
if [[ -f "$HOME/assets/final_glb/${ASSET_NAME}_final.glb" ]]; then
    ./tools/import-asset.sh "$ASSET_NAME"
else
    echo "  ⏭ No pipeline output found, assuming already imported"
    if [[ ! -d "actors/${ASSET_NAME}" ]]; then
        echo "  ❌ actors/${ASSET_NAME}/ does not exist" >&2
        exit 1
    fi
fi

echo "── Step 2: Godot import pass ──"
# Kill any existing Godot instance to ensure fresh import
EXISTING_PID=$(pgrep -x godot 2>/dev/null || true)
if [[ -n "$EXISTING_PID" ]]; then
    echo "  Stopping existing Godot (PID $EXISTING_PID)..."
    kill "$EXISTING_PID" 2>/dev/null || true
    sleep 2
fi

# Run headless import (may crash on large GLBs — that's OK, it still imports)
timeout 60 "$GODOT" --headless --editor --quit > /tmp/godot-import.log 2>&1 || true

# Verify import files exist
if [[ -f "actors/${ASSET_NAME}/${ASSET_NAME}_final.glb.import" ]]; then
    echo "  ✅ Import cache up to date"
else
    echo "  ⚠ Import file not found, retrying..."
    timeout 60 "$GODOT" --headless --editor --quit > /tmp/godot-import.log 2>&1 || true
fi

echo "── Step 3: Launch AssetViewer ──"
nohup "$GODOT" --scene res://ui/asset_viewer/AssetViewer.tscn > "$GODOT_LOG" 2>&1 &
GODOT_PID=$!
echo "  Godot PID: $GODOT_PID"

# Wait for DevTools to come up
echo "  Waiting for DevTools..."
DEVTOOLS="python3 tools/devtools.py"
for i in $(seq 1 20); do
    if $DEVTOOLS ping >/dev/null 2>&1; then
        echo "  ✅ DevTools ready"
        break
    fi
    if ! kill -0 "$GODOT_PID" 2>/dev/null; then
        echo "  ❌ Godot crashed. Logs:" >&2
        tail -10 "$GODOT_LOG" >&2
        exit 1
    fi
    sleep 1
done

if ! $DEVTOOLS ping >/dev/null 2>&1; then
    echo "  ❌ DevTools did not respond within 20s" >&2
    tail -10 "$GODOT_LOG" >&2
    exit 1
fi

echo "── Step 4: Load asset ──"
$DEVTOOLS asset-load "$GLB_PATH"
sleep 2

echo "── Step 5: Capture screenshot ──"
RESULT=$($DEVTOOLS asset-screenshot 2>&1)
echo "  $RESULT"

# Extract and print the screenshot path
SCREENSHOT_PATH=$(echo "$RESULT" | grep -oP '(?<=Screenshot saved: ).*' || echo "$SCREENSHOT_DIR/asset_viewer_screenshot.png")

echo ""
echo "════════════════════════════════════════"
echo "  Screenshot: $SCREENSHOT_PATH"
echo "════════════════════════════════════════"
