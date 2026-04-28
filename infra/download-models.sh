#!/usr/bin/env bash
# download-models.sh — Download AI models for ComfyUI containers
#
# Downloads model files from HuggingFace to ~/comfyui/models/.
# Organized in tiers so you can download incrementally:
#
#   Tier 1 (~33GB): Flux Schnell + CLIP + T5-XXL + VAE  (minimum for GPU0)
#   Tier 2 (~26GB): Flux Dev + RMBG/SAM/GroundingDINO   (full GPU0)
#   Tier 3 (~11GB): CHORD + Trellis2 + DINOv3            (GPU1)
#
# Usage:
#   ./download-models.sh --tier1       # Essential models only
#   ./download-models.sh --tier2       # Add masking/segmentation models
#   ./download-models.sh --tier3       # Add CHORD + Trellis2 + DINOv3
#   ./download-models.sh --all         # Everything
#   ./download-models.sh --status      # Show what's downloaded
#
# Prerequisites:
#   pip install huggingface-hub        # for hf
#   Run ./setup-dirs.sh first          # creates directory layout
#
# Gated models (Flux Dev, CHORD):
#   export HF_TOKEN=hf_xxxxx          # HuggingFace token with accepted licenses
#   Accept licenses at:
#     https://huggingface.co/black-forest-labs/FLUX.1-dev
#     https://huggingface.co/Ubisoft/ubisoft-laforge-chord

set -euo pipefail

MODELS_DIR="${COMFYUI_MODELS:-$HOME/comfyui/models}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $*"; }
log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }

# Check prerequisites
check_deps() {
    if ! command -v hf &>/dev/null; then
        log_err "hf not found. Install it:"
        log_err "  pip install 'huggingface_hub[cli]'"
        exit 1
    fi

    if [[ ! -d "$MODELS_DIR" ]]; then
        log_err "Models directory not found: $MODELS_DIR"
        log_err "Run ./setup-dirs.sh first."
        exit 1
    fi
}

# Download a single file from a HuggingFace repo
# Args: repo_id filename local_dir [--token]
hf_download_file() {
    local repo="$1"
    local filename="$2"
    local local_dir="$3"
    local needs_token="${4:-false}"

    local dest="$local_dir/$filename"

    if [[ -f "$dest" ]]; then
        local size
        size=$(stat -c%s "$dest" 2>/dev/null || echo "0")
        if [[ "$size" -gt 1000 ]]; then
            log_ok "Already exists: $filename ($(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B"))"
            return 0
        fi
    fi

    log_info "Downloading $filename from $repo ..."
    mkdir -p "$local_dir"

    local token_args=()
    if [[ "$needs_token" == "true" ]]; then
        if [[ -n "${HF_TOKEN:-}" ]]; then
            token_args=(--token "$HF_TOKEN")
        else
            # hf CLI uses cached credentials from 'hf auth login' automatically
            log_info "Using cached HF credentials for gated model"
        fi
    fi

    hf download "$repo" "$filename" \
        --local-dir "$local_dir" \
        "${token_args[@]}" || {
        log_err "Failed to download $repo/$filename"
        if [[ "$needs_token" == "true" ]]; then
            log_warn "  This is a gated model. Ensure you have:"
            log_warn "    1. Accepted the license at https://huggingface.co/$repo"
            log_warn "    2. Logged in via: hf auth login"
        fi
        return 1
    }

    log_ok "Downloaded: $filename"
}

# Download an entire HuggingFace repo snapshot
# Args: repo_id local_dir [--token]
hf_download_repo() {
    local repo="$1"
    local local_dir="$2"
    local needs_token="${3:-false}"

    # Check if already populated (has at least one non-hidden file)
    local file_count
    file_count=$(find "$local_dir" -maxdepth 1 -not -name '.*' -type f 2>/dev/null | wc -l)
    if [[ "$file_count" -gt 2 ]]; then
        log_ok "Already populated: $local_dir ($file_count files)"
        return 0
    fi

    log_info "Downloading repo $repo → $local_dir ..."
    mkdir -p "$local_dir"

    local token_args=()
    if [[ "$needs_token" == "true" ]]; then
        if [[ -n "${HF_TOKEN:-}" ]]; then
            token_args=(--token "$HF_TOKEN")
        else
            log_info "Using cached HF credentials for gated repo"
        fi
    fi

    hf download "$repo" \
        --local-dir "$local_dir" \
        "${token_args[@]}" || {
        log_err "Failed to download repo $repo"
        if [[ "$needs_token" == "true" ]]; then
            log_warn "  This is a gated repo. Ensure you have:"
            log_warn "    1. Accepted the license at https://huggingface.co/$repo"
            log_warn "    2. Logged in via: hf auth login"
        fi
        return 1
    }

    log_ok "Downloaded repo: $repo"
}

# ══════════════════════════════════════════════
#  Tier 1 — Essential (minimum for GPU0 test)
# ══════════════════════════════════════════════
download_tier1() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo " Tier 1: Essential models (Flux Schnell + encoders)"
    echo "═══════════════════════════════════════════════"

    # Flux.1 Schnell (open license, no token needed)
    hf_download_file "black-forest-labs/FLUX.1-schnell" \
        "flux1-schnell.safetensors" \
        "$MODELS_DIR/diffusion_models"

    # CLIP text encoder
    hf_download_file "comfyanonymous/flux_text_encoders" \
        "clip_l.safetensors" \
        "$MODELS_DIR/text_encoders"

    # T5-XXL text encoder (fp16 for quality, fp8 available as alternative)
    hf_download_file "comfyanonymous/flux_text_encoders" \
        "t5xxl_fp16.safetensors" \
        "$MODELS_DIR/text_encoders"

    # VAE
    hf_download_file "black-forest-labs/FLUX.1-schnell" \
        "ae.safetensors" \
        "$MODELS_DIR/vae"

    echo ""
    log_ok "Tier 1 complete — GPU0 can start with Flux Schnell."
}

# ══════════════════════════════════════════════
#  Tier 2 — Full GPU0 (Flux Dev + RMBG/SAM)
# ══════════════════════════════════════════════
download_tier2() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo " Tier 2: Full GPU0 (Flux Dev + masking models)"
    echo "═══════════════════════════════════════════════"

    # Flux.1 Dev (gated — requires HF token + license acceptance)
    hf_download_file "black-forest-labs/FLUX.1-dev" \
        "flux1-dev.safetensors" \
        "$MODELS_DIR/diffusion_models" \
        "true" || true

    # BiRefNet-HR (background removal — best quality)
    hf_download_repo "1038lab/BiRefNet" \
        "$MODELS_DIR/RMBG/BiRefNet"

    # BEN2 (batch background removal)
    hf_download_repo "1038lab/BEN2" \
        "$MODELS_DIR/RMBG/BEN2"

    # INSPYRENET (human portrait segmentation)
    hf_download_repo "1038lab/inspyrenet" \
        "$MODELS_DIR/RMBG/inspyrenet"

    # SAM3 (text-prompted segmentation)
    hf_download_repo "1038lab/sam3" \
        "$MODELS_DIR/sam3"

    # SAM2 Large (multi-object segmentation)
    hf_download_repo "1038lab/sam2" \
        "$MODELS_DIR/sam2"

    # GroundingDINO (text-guided detection for SAM)
    hf_download_repo "1038lab/GroundingDINO" \
        "$MODELS_DIR/grounding-dino"

    echo ""
    log_ok "Tier 2 complete — GPU0 has full masking/segmentation capability."
}

# ══════════════════════════════════════════════
#  Tier 3 — GPU1 (CHORD + Trellis2 + DINOv3)
# ══════════════════════════════════════════════
download_tier3() {
    echo ""
    echo "═══════════════════════════════════════════════"
    echo " Tier 3: GPU1 models (CHORD + Trellis2 + DINOv3)"
    echo "═══════════════════════════════════════════════"

    # CHORD v1 (gated — Ubisoft research-only license)
    hf_download_file "Ubisoft/ubisoft-laforge-chord" \
        "chord_v1.safetensors" \
        "$MODELS_DIR/checkpoints" \
        "true" || true

    # ── Trellis2: microsoft/TRELLIS.2-4B (~8 GB) ──
    local trellis_dir="$MODELS_DIR/trellis2"
    local trellis_files=(
        pipeline.json
        texturing_pipeline.json
        ckpts/shape_dec_next_dc_f16c32_fp16.json
        ckpts/shape_dec_next_dc_f16c32_fp16.safetensors
        ckpts/shape_enc_next_dc_f16c32_fp16.json
        ckpts/shape_enc_next_dc_f16c32_fp16.safetensors
        ckpts/slat_flow_img2shape_dit_1_3B_1024_bf16.json
        ckpts/slat_flow_img2shape_dit_1_3B_1024_bf16.safetensors
        ckpts/slat_flow_img2shape_dit_1_3B_512_bf16.json
        ckpts/slat_flow_img2shape_dit_1_3B_512_bf16.safetensors
        ckpts/slat_flow_imgshape2tex_dit_1_3B_1024_bf16.json
        ckpts/slat_flow_imgshape2tex_dit_1_3B_1024_bf16.safetensors
        ckpts/slat_flow_imgshape2tex_dit_1_3B_512_bf16.json
        ckpts/slat_flow_imgshape2tex_dit_1_3B_512_bf16.safetensors
        ckpts/ss_flow_img_dit_1_3B_64_bf16.json
        ckpts/ss_flow_img_dit_1_3B_64_bf16.safetensors
        ckpts/tex_dec_next_dc_f16c32_fp16.json
        ckpts/tex_dec_next_dc_f16c32_fp16.safetensors
        ckpts/tex_enc_next_dc_f16c32_fp16.json
        ckpts/tex_enc_next_dc_f16c32_fp16.safetensors
    )
    mkdir -p "$trellis_dir/ckpts"
    for f in "${trellis_files[@]}"; do
        hf_download_file "microsoft/TRELLIS.2-4B" "$f" "$trellis_dir"
    done

    # Shared sparse_structure_decoder from Trellis v1
    local trellis_legacy_files=(
        ckpts/ss_dec_conv3d_16l8_fp16.json
        ckpts/ss_dec_conv3d_16l8_fp16.safetensors
    )
    for f in "${trellis_legacy_files[@]}"; do
        hf_download_file "microsoft/TRELLIS-image-large" "$f" "$trellis_dir"
    done

    # ── DINOv3 (~1.2 GB) ──
    # Public mirror of facebook/dinov3 (gated); Trellis2 remaps to this.
    hf_download_file "PIA-SPACE-LAB/dinov3-vitl-pretrain-lvd1689m" \
        "model.safetensors" \
        "$MODELS_DIR/dinov3"

    # ── BiRefNet for Trellis2RemoveBackground (~425 MB) ──
    # Trellis2's built-in rembg uses ZhengPeng7/BiRefNet via HF cache format.
    # Must be pre-downloaded since models/ is mounted read-only in the container.
    local birefnet_cache="$MODELS_DIR/birefnet"
    if [ -d "$birefnet_cache/models--ZhengPeng7--BiRefNet" ]; then
        log_ok "Already cached: BiRefNet (Trellis2 rembg)"
    else
        log_info "Downloading ZhengPeng7/BiRefNet → $birefnet_cache (HF cache format)..."
        mkdir -p "$birefnet_cache"
        python3 -c "
from huggingface_hub import snapshot_download
snapshot_download('ZhengPeng7/BiRefNet', cache_dir='$birefnet_cache')
" || { log_err "Failed to download BiRefNet"; return 1; }
        log_ok "Downloaded BiRefNet for Trellis2RemoveBackground"
    fi

    echo ""
    log_ok "Tier 3 complete — GPU1 has CHORD PBR + Trellis2 3D generation."
}

# ══════════════════════════════════════════════
#  Status — show what's downloaded
# ══════════════════════════════════════════════
show_status() {
    echo "═══════════════════════════════════════════════"
    echo " Model Download Status"
    echo "═══════════════════════════════════════════════"
    echo ""

    local total_size=0

    check_file() {
        local path="$1"
        local label="$2"
        if [[ -f "$path" ]]; then
            local size
            size=$(stat -c%s "$path" 2>/dev/null || echo "0")
            total_size=$((total_size + size))
            printf "  ${GREEN}✓${NC} %-40s %s\n" "$label" "$(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B")"
        else
            printf "  ${RED}✗${NC} %-40s %s\n" "$label" "missing"
        fi
    }

    check_dir() {
        local path="$1"
        local label="$2"
        if [[ -d "$path" ]]; then
            local count
            count=$(find "$path" -type f -not -name '.*' 2>/dev/null | wc -l)
            if [[ "$count" -gt 0 ]]; then
                local size
                size=$(du -sb "$path" 2>/dev/null | awk '{print $1}')
                total_size=$((total_size + size))
                printf "  ${GREEN}✓${NC} %-40s %s (%d files)\n" "$label" "$(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B")" "$count"
            else
                printf "  ${RED}✗${NC} %-40s %s\n" "$label" "empty"
            fi
        else
            printf "  ${RED}✗${NC} %-40s %s\n" "$label" "missing"
        fi
    }

    echo "Tier 1 (Essential):"
    check_file "$MODELS_DIR/diffusion_models/flux1-schnell.safetensors" "Flux.1 Schnell"
    check_file "$MODELS_DIR/text_encoders/clip_l.safetensors"          "CLIP-L encoder"
    check_file "$MODELS_DIR/text_encoders/t5xxl_fp16.safetensors"      "T5-XXL encoder (fp16)"
    check_file "$MODELS_DIR/vae/ae.safetensors"                        "Flux VAE"

    echo ""
    echo "Tier 2 (Full GPU0):"
    check_file "$MODELS_DIR/diffusion_models/flux1-dev.safetensors"    "Flux.1 Dev"
    check_dir  "$MODELS_DIR/RMBG/BiRefNet"                             "BiRefNet-HR"
    check_dir  "$MODELS_DIR/RMBG/BEN2"                                 "BEN2"
    check_dir  "$MODELS_DIR/RMBG/inspyrenet"                           "INSPYRENET"
    check_dir  "$MODELS_DIR/sam3"                                      "SAM3"
    check_dir  "$MODELS_DIR/sam2"                                      "SAM2 Large"
    check_dir  "$MODELS_DIR/grounding-dino"                            "GroundingDINO"

    echo ""
    echo "Tier 3 (GPU1):"
    check_file "$MODELS_DIR/checkpoints/chord_v1.safetensors"                   "CHORD v1"
    check_dir  "$MODELS_DIR/trellis2"                                           "Trellis2"
    check_file "$MODELS_DIR/dinov3/model.safetensors"                           "DINOv3"
    check_dir  "$MODELS_DIR/birefnet/models--ZhengPeng7--BiRefNet"              "BiRefNet (Trellis2 rembg)"

    echo ""
    echo "Total downloaded: $(numfmt --to=iec "$total_size" 2>/dev/null || echo "${total_size}B")"
}

# ══════════════════════════════════════════════
#  Main
# ══════════════════════════════════════════════

usage() {
    echo "Usage: $0 {--tier1|--tier2|--tier3|--all|--status}"
    echo ""
    echo "  --tier1    Flux Schnell + CLIP + T5 + VAE (~33GB)"
    echo "  --tier2    Flux Dev + RMBG/SAM models (~26GB, needs HF_TOKEN for Dev)"
    echo "  --tier3    CHORD + Trellis2 + DINOv3 (~11GB, needs HF_TOKEN for CHORD)"
    echo "  --all      Download everything"
    echo "  --status   Show what's already downloaded"
    echo ""
    echo "Environment:"
    echo "  HF_TOKEN           HuggingFace token (required for gated models)"
    echo "  COMFYUI_MODELS     Override models directory (default: ~/comfyui/models)"
}

case "${1:-}" in
    --tier1)
        check_deps
        download_tier1
        ;;
    --tier2)
        check_deps
        download_tier2
        ;;
    --tier3)
        check_deps
        download_tier3
        ;;
    --all)
        check_deps
        download_tier1
        download_tier2
        download_tier3
        echo ""
        echo "═══════════════════════════════════════════════"
        log_ok "All model tiers downloaded."
        echo "═══════════════════════════════════════════════"
        ;;
    --status)
        show_status
        ;;
    --help|-h)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
