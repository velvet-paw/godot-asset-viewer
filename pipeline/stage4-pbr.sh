#!/usr/bin/env bash
# test-stage4-pbr.sh — PBR material decomposition via CHORD
# Usage: ./test-stage4-pbr.sh [input_image] [gpu_url] [asset_name]

set -euo pipefail

INPUT="${1:-concept_00001_.png}"
GPU_URL="${2:-http://localhost:8188}"
ASSET_NAME="${3:-pbr}"
FLOW="$HOME/comfyui/flows/chord-pbr.json"
OUTDIR="$HOME/assets/pbr_maps"

echo "=== Stage 4-5: PBR Decomposition (CHORD) ==="
echo "GPU: $GPU_URL"
echo "Input: $INPUT"
echo "Asset: $ASSET_NAME"

mkdir -p "$OUTDIR"

python3 - "$GPU_URL" "$FLOW" "$INPUT" "$OUTDIR" "$ASSET_NAME" <<'PYEOF'
import sys, time, os
sys.path.insert(0, "pipeline")
from comfyui_api import ComfyUIClient

gpu_url, flow_path, input_image, outdir, asset_name = sys.argv[1:6]
client = ComfyUIClient(gpu_url)

# Upload input image to GPU1
client.upload_image(os.path.expanduser(f"~/assets/concepts/{input_image}"))

workflow = client.load_workflow(flow_path)
workflow = client.set_node_input(workflow, "1", "image", input_image)
workflow = client.set_filename_prefix(workflow, asset_name)

t0 = time.time()
prompt_id = client.queue(workflow)
print(f"Queued: {prompt_id}")
result = client.wait(prompt_id, timeout=300)
elapsed = time.time() - t0
print(f"Completed in {elapsed:.1f}s — {result['status']['status_str']}")

paths = client.download_images(prompt_id, outdir)
for p in paths:
    size = os.path.getsize(p)
    print(f"  ✅ {p} ({size} bytes)")

expected = {"basecolor", "normal", "roughness", "metalness", "height"}
found = set()
for p in paths:
    for ch in expected:
        if ch in os.path.basename(p):
            found.add(ch)

missing = expected - found
if missing:
    print(f"  ⚠ Missing channels: {missing}")
else:
    print(f"Stage 4-5 PASSED ({len(paths)} PBR maps, {elapsed:.1f}s)")
PYEOF
