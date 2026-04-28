#!/usr/bin/env bash
# compose-blender.sh — Deploy and manage the Blender + MCP container stack
#
# Pulls pre-built images from registry and manages the container lifecycle.
# Does NOT build images — for that, see the blender-container repository.
#
# Usage:
#   ./infra/compose-blender.sh              # Pull + start (headless, default)
#   ./infra/compose-blender.sh --gui        # Pull + start with KasmVNC GUI
#   ./infra/compose-blender.sh --teardown   # Stop and remove the stack
#   ./infra/compose-blender.sh --status     # Show container status
#   ./infra/compose-blender.sh --logs       # Follow container logs
#
# Environment variables:
#   BLENDER_GPU    — Which GPU to use (default: 1)
#   BLENDER_MODE   — "headless" (default) or "gui"
#   GAAP_VERSION   — Image tag to pull (default: latest)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/blender/docker-compose.yml"

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
    log_info "Pulling Blender + MCP images..."
    compose_cmd -f "$COMPOSE_FILE" pull

    log_info "Starting Blender + MCP stack (${BLENDER_MODE:-headless} mode)..."
    BLENDER_MODE="${BLENDER_MODE:-headless}" compose_cmd -f "$COMPOSE_FILE" up -d

    echo ""
    log_info "Waiting for Blender MCP to become healthy..."
    local retries=0
    local max_retries=40
    while [[ $retries -lt $max_retries ]]; do
        if podman inspect gaap-blender --format '{{.State.Health.Status}}' 2>/dev/null | grep -q 'healthy'; then
            log_ok "Blender socket server is healthy."
            break
        fi
        retries=$((retries + 1))
        sleep 5
    done

    if [[ $retries -ge $max_retries ]]; then
        log_warn "Blender health check did not pass within timeout. Check logs:"
        log_warn "  podman logs gaap-blender"
    fi

    echo ""
    log_ok "Stack is running! (mode: ${BLENDER_MODE:-headless})"
    echo ""
    if [[ "${BLENDER_MODE:-headless}" != "headless" ]]; then
        echo "  Blender Web UI:  http://localhost:3000/"
        echo "  Blender HTTPS:   https://localhost:3001/"
    fi
    echo "  MCP Server:      http://localhost:8000/"
}

teardown() {
    log_info "Stopping and removing the Blender stack..."
    compose_cmd -f "$COMPOSE_FILE" down
    log_ok "Blender stack removed."
}

show_status() {
    compose_cmd -f "$COMPOSE_FILE" ps
}

show_logs() {
    compose_cmd -f "$COMPOSE_FILE" logs -f
}

usage() {
    echo "Usage: $0 [--gui|--teardown|--status|--logs]"
    echo ""
    echo "  (no args)    Check prerequisites, pull images, start (headless)"
    echo "  --gui        Same as above but with KasmVNC web UI"
    echo "  --teardown   Stop and remove the stack"
    echo "  --status     Show container status"
    echo "  --logs       Follow container logs"
    echo ""
    echo "Environment variables:"
    echo "  BLENDER_GPU    GPU index to use (default: 1)"
    echo "  BLENDER_MODE   'headless' (default) or 'gui'"
    echo "  GAAP_VERSION   Image tag to pull (default: latest)"
}

case "${1:-run}" in
    run|"")
        check_prerequisites
        setup_cdi
        run_stack
        ;;
    --gui)
        export BLENDER_MODE=gui
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
