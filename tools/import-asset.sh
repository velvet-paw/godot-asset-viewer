#!/usr/bin/env bash
# Import a game-ready asset into the Godot project
# Usage: ./tools/import-asset.sh <asset_name>
#
# Copies from ~/assets/final_glb/ to res://actors/<asset_name>/:
#   - {asset_name}_final.glb      (required)
#   - {asset_name}_lod1.glb       (optional)
#   - {asset_name}_lod2.glb       (optional)
#   - {asset_name}-col.glb        (optional, collision mesh)

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <asset_name>" >&2
    echo "Example: $0 sword" >&2
    exit 1
fi

ASSET_NAME="$1"
SOURCE_DIR="$HOME/assets/final_glb"
TARGET_DIR="actors/${ASSET_NAME}"

# Verify source directory exists
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "Error: Source directory not found: $SOURCE_DIR" >&2
    exit 1
fi

# Verify the main GLB exists
MAIN_GLB="${SOURCE_DIR}/${ASSET_NAME}_final.glb"
if [[ ! -f "$MAIN_GLB" ]]; then
    echo "Error: Main asset not found: $MAIN_GLB" >&2
    exit 1
fi

# Create target directory
mkdir -p "$TARGET_DIR"

COPIED=0

# Copy main GLB
cp "$MAIN_GLB" "$TARGET_DIR/"
echo "  Copied: ${ASSET_NAME}_final.glb"
COPIED=$((COPIED + 1))

# Copy LOD files if they exist
for lod in lod1 lod2; do
    LOD_FILE="${SOURCE_DIR}/${ASSET_NAME}_${lod}.glb"
    if [[ -f "$LOD_FILE" ]]; then
        cp "$LOD_FILE" "$TARGET_DIR/"
        echo "  Copied: ${ASSET_NAME}_${lod}.glb"
        COPIED=$((COPIED + 1))
    fi
done

# Copy collision mesh if it exists
COL_FILE="${SOURCE_DIR}/${ASSET_NAME}-col.glb"
if [[ -f "$COL_FILE" ]]; then
    cp "$COL_FILE" "$TARGET_DIR/"
    echo "  Copied: ${ASSET_NAME}-col.glb"
    COPIED=$((COPIED + 1))
fi

echo "Imported ${COPIED} file(s) to ${TARGET_DIR}/"
