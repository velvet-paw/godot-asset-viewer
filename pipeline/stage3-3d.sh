#!/usr/bin/env bash
# stage3-3d.sh — Image to 3D mesh via Trellis2
#
# Uploads both concept art (full RGB with glow) and masked image (for alpha mask).
# Trellis2 conditioning uses the concept's RGB + masked image's alpha channel,
# so the glow/aura is preserved in the 3D reconstruction.
#
# Usage: ./stage3-3d.sh [concept_image] [gpu_url] [asset_name]

set -euo pipefail

INPUT="${1:-concept_00001_.png}"
GPU_URL="${2:-http://localhost:8188}"
ASSET_NAME="${3:-asset}"
FLOW="$HOME/comfyui/flows/trellis2-img2mesh.json"
OUTDIR="$HOME/assets/raw_3d"

echo "=== Stage 3: Image to 3D (Trellis2) ==="
echo "GPU: $GPU_URL"
echo "Input: $INPUT"
echo "Asset: $ASSET_NAME"

mkdir -p "$OUTDIR"

python3 - "$GPU_URL" "$FLOW" "$INPUT" "$OUTDIR" "$ASSET_NAME" <<'PYEOF'
import sys, time, os, shutil, glob
import numpy as np
from PIL import Image
sys.path.insert(0, "pipeline")
from comfyui_api import ComfyUIClient

gpu_url, flow_path, input_image, outdir, asset_name = sys.argv[1:6]
client = ComfyUIClient(gpu_url)

# Upload concept art (full RGB including glow effects)
concept_path = os.path.expanduser(f"~/assets/concepts/{input_image}")
if not os.path.exists(concept_path):
    print(f"  ⚠ Concept not found at {concept_path}, checking masked dir")
    concept_path = os.path.expanduser(f"~/assets/masked/{input_image}")
concept_name = os.path.basename(concept_path)
print(f"Uploading concept: {concept_path}")
client.upload_image(concept_path)

# Create an enhanced mask that includes glow/aura effects.
# BiRefNet's mask is too aggressive for ethereal objects — it clips the glow.
# We combine BiRefNet's mask with a luminance-difference mask that captures
# anything visually distinct from the background.
masked_name = concept_name.replace("concept_", "masked_")
masked_path = os.path.expanduser(f"~/assets/masked/{masked_name}")
enhanced_mask_name = concept_name.replace("concept_", "enhanced_mask_")
enhanced_mask_path = os.path.expanduser(f"~/assets/masked/{enhanced_mask_name}")

concept_img = Image.open(concept_path).convert("RGB")
concept_arr = np.array(concept_img, dtype=np.float32)

# Estimate background color from corners (10% border)
h, w = concept_arr.shape[:2]
border = int(min(h, w) * 0.1)
corners = np.concatenate([
    concept_arr[:border, :border].reshape(-1, 3),
    concept_arr[:border, -border:].reshape(-1, 3),
    concept_arr[-border:, :border].reshape(-1, 3),
    concept_arr[-border:, -border:].reshape(-1, 3),
])
bg_color = np.median(corners, axis=0)

# Compute per-pixel color distance from background
diff = np.sqrt(np.sum((concept_arr - bg_color) ** 2, axis=2))
# Normalize and threshold — anything >25% different from bg is foreground
diff_norm = diff / (diff.max() + 1e-6)
glow_mask = (diff_norm > 0.25).astype(np.float32)

# Dilate slightly to fill gaps
from PIL import ImageFilter
glow_pil = Image.fromarray((glow_mask * 255).astype(np.uint8), 'L')
glow_pil = glow_pil.filter(ImageFilter.MaxFilter(3))
glow_mask = np.array(glow_pil).astype(np.float32) / 255.0

# Combine with BiRefNet mask if available (union)
if os.path.exists(masked_path):
    birefnet_img = Image.open(masked_path)
    if birefnet_img.mode == 'RGBA':
        birefnet_mask = np.array(birefnet_img)[:,:,3].astype(np.float32) / 255.0
        combined_mask = np.maximum(glow_mask, birefnet_mask)
    else:
        combined_mask = glow_mask
else:
    combined_mask = glow_mask

# Save as RGBA with concept RGB + enhanced alpha
enhanced_rgba = np.dstack([
    np.array(concept_img),
    (combined_mask * 255).astype(np.uint8)
])
enhanced_img = Image.fromarray(enhanced_rgba, 'RGBA')
enhanced_img.save(enhanced_mask_path)

fg_pct = 100 * (combined_mask > 0.5).sum() / combined_mask.size
print(f"Enhanced mask: {fg_pct:.1f}% foreground (glow-inclusive)")
print(f"Uploading enhanced mask: {enhanced_mask_path}")
client.upload_image(enhanced_mask_path)

# Single LoadImage node: RGB from concept + alpha from enhanced mask
# InvertMask (node 2) flips alpha for GetConditioning
workflow = client.load_workflow(flow_path)
workflow = client.set_node_input(workflow, "1", "image", enhanced_mask_name)
workflow = client.set_filename_prefix(workflow, asset_name)

# Record existing GLBs before queueing to detect new ones
comfyui_output = os.path.expanduser("~/comfyui/output")
existing_glbs = set(glob.glob(os.path.join(comfyui_output, "*.glb")))

t0 = time.time()
prompt_id = client.queue(workflow)
print(f"Queued: {prompt_id}")
print("Waiting (Trellis2 takes 2-5 min)...")
result = client.wait(prompt_id, timeout=900)
elapsed = time.time() - t0
print(f"Completed in {elapsed:.1f}s — {result['status']['status_str']}")

# Trellis2ExportGLB saves to ComfyUI output dir (not tracked in history)
# Find newly created GLB files
current_glbs = set(glob.glob(os.path.join(comfyui_output, "*.glb")))
new_glbs = sorted(current_glbs - existing_glbs, key=os.path.getmtime, reverse=True)

if new_glbs:
    src = new_glbs[0]
    dst = os.path.join(outdir, f"{asset_name}_00001_.glb")
    shutil.copy2(src, dst)
    size = os.path.getsize(dst)
    print(f"  ✅ {dst} ({size} bytes)")

    # Early gate: check vertex count vs decimation_target
    try:
        import trimesh
        scene = trimesh.load(dst, force='scene')
        mesh = list(scene.geometry.values())[0]
        verts = len(mesh.vertices)
        import json as _json
        with open(flow_path) as _f:
            _wf = _json.load(_f)
        target = int(_wf.get('7', {}).get('inputs', {}).get('decimation_target', 25000))
        ratio = verts / target
        print(f"  Vertex check: {verts} verts (target {target}, ratio {ratio:.1f}x)")
        if ratio > 3.0:
            print(f"  ⚠ WARNING: vertex count {ratio:.1f}x over target — UV fragmentation likely")
            print(f"  ⚠ Consider regenerating with lower decimation_target (e.g. 15000)")
        else:
            print(f"  ✅ Vertex count within expected range")
    except Exception as e:
        print(f"  ⚠ Vertex check skipped: {e}")

    print(f"Stage 3 PASSED ({elapsed:.1f}s)")
else:
    print("  ❌ No GLB output found in ComfyUI output directory")
    sys.exit(1)
PYEOF
