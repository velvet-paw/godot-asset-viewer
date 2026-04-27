#!/usr/bin/env bash
# test-stage2-mask.sh — Remove background using BiRefNet-HR
# Usage: ./test-stage2-mask.sh [input_image] [gpu_url]

set -euo pipefail

INPUT="${1:-concept_00001_.png}"
GPU_URL="${2:-http://localhost:8188}"
FLOW="$HOME/comfyui/flows/rmbg-mask.json"
OUTDIR="$HOME/assets/masked"

echo "=== Stage 2: Background Removal (BiRefNet-HR) ==="
echo "GPU: $GPU_URL"
echo "Input: $INPUT"

mkdir -p "$OUTDIR"

python3 - "$GPU_URL" "$FLOW" "$INPUT" "$OUTDIR" <<'PYEOF'
import sys, time
sys.path.insert(0, "pipeline")
from comfyui_api import ComfyUIClient

gpu_url, flow_path, input_image, outdir = sys.argv[1:5]
client = ComfyUIClient(gpu_url)

import os
client.upload_image(os.path.expanduser(f"~/assets/concepts/{input_image}"))

workflow = client.load_workflow(flow_path)
workflow = client.set_node_input(workflow, "1", "image", input_image)

t0 = time.time()
prompt_id = client.queue(workflow)
print(f"Queued: {prompt_id}")
result = client.wait(prompt_id, timeout=300)
elapsed = time.time() - t0
print(f"Completed in {elapsed:.1f}s — {result['status']['status_str']}")

paths = client.download_images(prompt_id, outdir)
import os
for p in paths:
    size = os.path.getsize(p)
    print(f"  ✅ {p} ({size} bytes)")
print(f"Stage 2 PASSED ({len(paths)} image(s), {elapsed:.1f}s)")
PYEOF
