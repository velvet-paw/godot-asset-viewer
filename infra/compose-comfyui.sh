#!/usr/bin/env bash
# compose-comfyui.sh — Deploy and manage the ComfyUI container
#
# Pulls a pre-built image from registry and manages the container lifecycle.
# Does NOT build images — for that, see the blender-container repository.
#
# Usage:
#   ./infra/compose-comfyui.sh              # Pull + start the stack
#   ./infra/compose-comfyui.sh --teardown   # Stop and remove the stack
#   ./infra/compose-comfyui.sh --status     # Show container status
#   ./infra/compose-comfyui.sh --logs       # Follow container logs
#
# Environment variables:
#   COMFYUI_GPU   — Which GPU to use (default: 0)
#   COMFYUI_PORT  — Host port to expose (default: 8188)
#   GAAP_VERSION  — Image tag to pull (default: latest)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/comfyui/docker-compose.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $*"; }
log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }

setup_cdi() {
    log_info "Checking nvidia-container-toolkit..."
    if ! command -v nvidia-ctk &>/dev/null; then
        log_err "nvidia-container-toolkit not found. Install it:"
        log_err "  sudo apt-get install nvidia-container-toolkit"
        exit 1
    fi
    log_ok "nvidia-container-toolkit available."

    local cdi_dir="${XDG_CONFIG_HOME:-$HOME/.config}/cdi"
    log_info "Generating CDI specs for rootless podman..."
    mkdir -p "$cdi_dir"
    nvidia-ctk cdi generate --output="$cdi_dir/nvidia.yaml"
    log_ok "CDI specs generated at $cdi_dir/nvidia.yaml"
}

check_prerequisites() {
    local errors=0

    if ! lsmod 2>/dev/null | grep '^nvidia_drm ' >/dev/null 2>&1; then
        log_err "nvidia-drm module is not loaded."
        log_err "Run: $SCRIPT_DIR/toggle-nvidia-drm.sh render"
        errors=$((errors + 1))
    else
        log_ok "nvidia-drm module loaded."
    fi

    if ! command -v podman &>/dev/null; then
        log_err "podman is not installed."
        errors=$((errors + 1))
    else
        log_ok "podman $(podman --version | awk '{print $NF}') available."
    fi

    if command -v podman-compose &>/dev/null; then
        log_ok "podman-compose available."
    elif podman compose version &>/dev/null; then
        log_ok "podman compose (plugin) available."
    else
        log_err "Neither podman-compose nor 'podman compose' plugin found."
        errors=$((errors + 1))
    fi

    local gpu_count
    gpu_count=$(nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l || echo "0")
    if [[ "$gpu_count" -lt 1 ]]; then
        log_err "No NVIDIA GPUs detected."
        errors=$((errors + 1))
    else
        log_ok "$gpu_count NVIDIA GPU(s) detected."
    fi

    if [[ $errors -gt 0 ]]; then
        log_err "Fix the above errors before continuing."
        exit 1
    fi
}

compose_cmd() {
    if podman compose version &>/dev/null 2>&1; then
        podman compose "$@"
    else
        podman-compose "$@"
    fi
}

run_stack() {
    local gpu="${COMFYUI_GPU:-0}"
    local port="${COMFYUI_PORT:-8188}"

    log_info "Setting up host directories..."
    "$SCRIPT_DIR/setup-dirs.sh"
    echo ""

    log_info "Pulling ComfyUI image..."
    compose_cmd -f "$COMPOSE_FILE" pull

    log_info "Starting ComfyUI (GPU $gpu, port $port)..."
    compose_cmd -f "$COMPOSE_FILE" up -d

    echo ""
    log_info "Waiting for container to become healthy..."
    local retries=0
    local max_retries=60
    while [[ $retries -lt $max_retries ]]; do
        local health
        health=$(podman inspect gaap-comfyui --format '{{.State.Health.Status}}' 2>/dev/null || echo "unknown")
        if [[ "$health" == "healthy" ]]; then
            break
        fi
        if [[ $((retries % 6)) -eq 0 ]]; then
            log_info "  gaap-comfyui: $health"
        fi
        retries=$((retries + 1))
        sleep 5
    done

    local final_health
    final_health=$(podman inspect gaap-comfyui --format '{{.State.Health.Status}}' 2>/dev/null || echo "unknown")
    if [[ "$final_health" == "healthy" ]]; then
        log_ok "ComfyUI is healthy."
    else
        log_warn "Health check did not pass within timeout. Check logs:"
        log_warn "  podman logs gaap-comfyui"
    fi

    echo ""
    log_ok "ComfyUI stack is running!"
    echo ""
    echo "  ComfyUI:  http://localhost:${port}/"
    echo "  GPU:      ${gpu}"
}

teardown() {
    log_info "Stopping and removing the ComfyUI stack..."
    compose_cmd -f "$COMPOSE_FILE" down
    log_ok "ComfyUI stack removed."
}

show_status() {
    compose_cmd -f "$COMPOSE_FILE" ps
}

show_logs() {
    compose_cmd -f "$COMPOSE_FILE" logs -f
}

usage() {
    echo "Usage: $0 [--teardown|--status|--logs]"
    echo ""
    echo "  (no args)    Check prerequisites, pull image, start ComfyUI"
    echo "  --teardown   Stop and remove the ComfyUI stack"
    echo "  --status     Show container status"
    echo "  --logs       Follow container logs"
    echo ""
    echo "Environment variables:"
    echo "  COMFYUI_GPU    GPU index to use (default: 0)"
    echo "  COMFYUI_PORT   Host port to expose (default: 8188)"
    echo "  GAAP_VERSION   Image tag to pull (default: latest)"
}

case "${1:-run}" in
    run|"")
        check_prerequisites
        setup_cdi
        run_stack
        ;;
    --teardown)
        teardown
        ;;
    --status)
        show_status
        ;;
    --logs)
        show_logs
        ;;
    --help|-h)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
