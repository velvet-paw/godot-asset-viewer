#!/usr/bin/env bash
# toggle-nvidia-drm.sh — Switch nvidia-drm between training and rendering modes
#
# Usage:
#   toggle-nvidia-drm.sh render   # Load nvidia-drm with modeset=1, create renderD nodes
#   toggle-nvidia-drm.sh train    # Unload nvidia-drm, restore blacklist
#   toggle-nvidia-drm.sh status   # Show current state
#
# When nvidia-drm is loaded with modeset=1, NVIDIA GPUs expose /dev/dri/renderDXXX
# nodes needed for Wayland EGL rendering. When blacklisted (training mode), the
# DRM subsystem is not attached to NVIDIA GPUs, reducing overhead for CUDA workloads.

set -euo pipefail

BLACKLIST_FILE="/etc/modprobe.d/nvidia-drm-blacklist.conf"
BLACKLIST_CONTENT="blacklist nvidia-drm"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $*"; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "This script must be run as root."
        exit 1
    fi
}

is_module_loaded() {
    lsmod 2>/dev/null | grep '^nvidia_drm ' >/dev/null 2>&1
}

is_blacklisted() {
    [[ -f "$BLACKLIST_FILE" ]] && grep -q '^blacklist nvidia-drm' "$BLACKLIST_FILE"
}

list_nvidia_render_nodes() {
    local nodes=()
    for node in /dev/dri/renderD*; do
        [[ -e "$node" ]] || continue
        local devpath
        devpath=$(udevadm info "$node" 2>/dev/null | grep 'E: DEVPATH=' | head -1)
        if echo "$devpath" | grep -qi nvidia; then
            nodes+=("$node")
        else
            local driver
            driver=$(udevadm info -a "$node" 2>/dev/null | grep 'DRIVERS==' | grep -v '""' | head -1 || true)
            if echo "$driver" | grep -qi nvidia; then
                nodes+=("$node")
            fi
        fi
    done

    # Fallback: nodes not belonging to Intel (PCI 00:02.0) are likely NVIDIA
    if [[ ${#nodes[@]} -eq 0 ]]; then
        for node in /dev/dri/renderD*; do
            [[ -e "$node" ]] || continue
            local pci_path
            pci_path=$(udevadm info "$node" 2>/dev/null | grep 'E: ID_PATH=' | head -1 || true)
            if ! echo "$pci_path" | grep -q 'pci-0000:00:02.0'; then
                nodes+=("$node")
            fi
        done
    fi

    echo "${nodes[@]}"
}

cmd_status() {
    echo "=== NVIDIA DRM Status ==="
    echo ""

    if is_blacklisted; then
        echo -e "Blacklist:    ${YELLOW}ACTIVE${NC} (training mode)"
    else
        echo -e "Blacklist:    ${GREEN}REMOVED${NC} (rendering mode)"
    fi

    if is_module_loaded; then
        echo -e "nvidia-drm:   ${GREEN}LOADED${NC}"
        local modeset
        modeset=$(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null || echo "unknown")
        echo -e "modeset:      ${modeset}"
    else
        echo -e "nvidia-drm:   ${RED}NOT LOADED${NC}"
    fi

    echo ""
    echo "DRI render nodes:"
    for node in /dev/dri/renderD*; do
        [[ -e "$node" ]] || { echo "  (none)"; break; }
        local pci
        pci=$(udevadm info "$node" 2>/dev/null | grep 'E: ID_PATH=' | sed 's/.*=//' || echo "unknown")
        echo "  $node  ($pci)"
    done

    local nvidia_nodes
    nvidia_nodes=$(list_nvidia_render_nodes)
    echo ""
    if [[ -n "$nvidia_nodes" ]]; then
        echo -e "NVIDIA render nodes: ${GREEN}${nvidia_nodes}${NC}"
    else
        echo -e "NVIDIA render nodes: ${RED}none${NC}"
    fi
}

cmd_render() {
    require_root

    echo "=== Switching to RENDERING mode ==="

    # Remove blacklist
    if is_blacklisted; then
        echo "Removing nvidia-drm blacklist..."
        sed -i '/^blacklist nvidia-drm/d' "$BLACKLIST_FILE"
        # Remove file if empty
        if [[ ! -s "$BLACKLIST_FILE" ]]; then
            rm -f "$BLACKLIST_FILE"
        fi
        log_ok "Blacklist removed."
    else
        log_ok "Blacklist already removed."
    fi

    # Load module
    if is_module_loaded; then
        log_ok "nvidia-drm already loaded."
    else
        echo "Loading nvidia-drm with modeset=1..."
        modprobe nvidia-drm modeset=1
        log_ok "nvidia-drm loaded."
    fi

    # Create render nodes
    echo "Running nvidia-modprobe --modeset..."
    nvidia-modprobe --modeset
    log_ok "nvidia-modprobe complete."

    # Wait for udev to settle
    udevadm settle --timeout=5 2>/dev/null || true
    sleep 1

    # Verify
    local nvidia_nodes
    nvidia_nodes=$(list_nvidia_render_nodes)
    echo ""
    if [[ -n "$nvidia_nodes" ]]; then
        log_ok "NVIDIA render nodes available: $nvidia_nodes"
    else
        log_warn "No NVIDIA render nodes detected. All render nodes:"
        ls -la /dev/dri/renderD* 2>/dev/null || echo "  (none)"
        echo ""
        log_warn "You may need to reboot for modeset changes to take full effect."
    fi
}

cmd_train() {
    require_root

    echo "=== Switching to TRAINING mode ==="

    # Unload module
    if is_module_loaded; then
        echo "Unloading nvidia-drm..."
        if modprobe -r nvidia-drm 2>/dev/null; then
            log_ok "nvidia-drm unloaded."
        else
            log_warn "Could not unload nvidia-drm (may be in use)."
            log_warn "A reboot may be required if a display server or container is using it."
        fi
    else
        log_ok "nvidia-drm already unloaded."
    fi

    # Restore blacklist
    if is_blacklisted; then
        log_ok "Blacklist already in place."
    else
        echo "Restoring nvidia-drm blacklist..."
        echo "$BLACKLIST_CONTENT" > "$BLACKLIST_FILE"
        log_ok "Blacklist restored at $BLACKLIST_FILE"
    fi

    echo ""
    log_ok "Training mode active. nvidia-drm will not auto-load on next boot."
}

usage() {
    echo "Usage: $0 {render|train|status}"
    echo ""
    echo "  render  — Load nvidia-drm (modeset=1), create NVIDIA renderD nodes"
    echo "  train   — Unload nvidia-drm, blacklist it (reduce DRM overhead for CUDA)"
    echo "  status  — Show current nvidia-drm and render node state"
}

case "${1:-}" in
    render) cmd_render ;;
    train)  cmd_train ;;
    status) cmd_status ;;
    *)      usage; exit 1 ;;
esac
