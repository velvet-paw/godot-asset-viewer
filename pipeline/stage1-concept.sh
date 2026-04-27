#!/usr/bin/env bash
# test-stage1-concept.sh — Generate a Flux.1 Dev concept image
# Usage: ./test-stage1-concept.sh [prompt] [gpu_url]

set -euo pipefail

PROMPT="${1:-a medieval sword with ornate crossguard, game asset, orthographic view, plain background}"
GPU_URL="${2:-http://localhost:8188}"
FLOW="$HOME/comfyui/flows/flux-concept-art.json"
OUTDIR="$HOME/assets/concepts"

echo "=== Stage 1: Concept Art (Flux.1 Dev) ==="
echo "GPU: $GPU_URL"
echo "Prompt: $PROMPT"

mkdir -p "$OUTDIR"

python3 - "$GPU_URL" "$FLOW" "$PROMPT" "$OUTDIR" <<'PYEOF'
import sys, time
sys.path.insert(0, "pipeline")
from comfyui_api import ComfyUIClient

gpu_url, flow_path, prompt, outdir = sys.argv[1:5]
client = ComfyUIClient(gpu_url)

workflow = client.load_workflow(flow_path)
workflow = client.set_node_input(workflow, "6", "text", prompt)

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
print(f"Stage 1 PASSED ({len(paths)} image(s), {elapsed:.1f}s)")
PYEOF
