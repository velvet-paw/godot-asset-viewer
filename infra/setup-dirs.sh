#!/usr/bin/env bash
# setup-dirs.sh — Create host directory layout for ComfyUI + asset pipeline
#
# Creates:
#   ~/comfyui/   — models, flows, output, settings (mounted into container)
#   ~/assets/    — pipeline output directories
#
# Safe to run multiple times — only creates directories that don't exist.
#
# Usage:
#   ./setup-dirs.sh

set -euo pipefail

GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log_ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }

COMFYUI_BASE="$HOME/comfyui"
ASSETS_BASE="$HOME/assets"

log_info "Creating ComfyUI directory layout under $COMFYUI_BASE ..."

mkdir -p \
    "$COMFYUI_BASE/models/checkpoints" \
    "$COMFYUI_BASE/models/clip" \
    "$COMFYUI_BASE/models/diffusion_models" \
    "$COMFYUI_BASE/models/text_encoders" \
    "$COMFYUI_BASE/models/unet" \
    "$COMFYUI_BASE/models/vae" \
    "$COMFYUI_BASE/models/loras" \
    "$COMFYUI_BASE/models/RMBG/BiRefNet" \
    "$COMFYUI_BASE/models/RMBG/BEN2" \
    "$COMFYUI_BASE/models/RMBG/inspyrenet" \
    "$COMFYUI_BASE/models/sam2" \
    "$COMFYUI_BASE/models/sam3" \
    "$COMFYUI_BASE/models/grounding-dino" \
    "$COMFYUI_BASE/models/trellis2" \
    "$COMFYUI_BASE/models/dinov3" \
    "$COMFYUI_BASE/flows" \
    "$COMFYUI_BASE/custom_nodes" \
    "$COMFYUI_BASE/output" \
    "$COMFYUI_BASE/settings"

log_ok "ComfyUI directories created."

log_info "Creating asset pipeline directories under $ASSETS_BASE ..."

mkdir -p \
    "$ASSETS_BASE/concepts" \
    "$ASSETS_BASE/masked" \
    "$ASSETS_BASE/raw_3d" \
    "$ASSETS_BASE/pbr_maps" \
    "$ASSETS_BASE/final_glb"

log_ok "Asset directories created."

echo ""
log_info "Directory layout:"
echo "  $COMFYUI_BASE/"
find "$COMFYUI_BASE" -type d | sort | sed "s|^$COMFYUI_BASE|  ~/comfyui|"
echo ""
echo "  $ASSETS_BASE/"
find "$ASSETS_BASE" -type d | sort | sed "s|^$ASSETS_BASE|  ~/assets|"
echo ""
log_ok "Setup complete. Download models to ~/comfyui/models/ before starting containers."
