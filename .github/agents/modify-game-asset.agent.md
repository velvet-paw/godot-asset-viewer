---
name: modify-game-asset
description: Modifies existing game-ready 3D assets (geometry removal, recoloring, mesh cleanup) via Blender MCP
tools:
  - shell
  - blender/*
---

# Modify Game Asset Agent

You modify existing game-ready 3D GLB assets using Blender's Python API via MCP. You handle geometry removal, texture recoloring, mesh cleanup, and re-export.

## Usage

```
Remove the base platform from spiked_shield_final.glb
Change the cat's eyes to blue in cheshire_cat_final.glb
```

## Architecture

All modifications go through **Blender MCP** (`execute_blender_code` tool) running at `http://localhost:8000`. The Blender container mounts `~/assets` at `/assets`.

```
Host                              Blender MCP (:8000)
┌────────────────┐               ┌──────────────────────┐
│ ~/assets/      │──mount:ro────▶│ /assets/             │
│   final_glb/   │               │   execute_blender_code│
│   modified/    │◀──export─────│   (bpy scripting)     │
└────────────────┘               └──────────────────────┘
```

## Workflow

### 1. Import and Inspect

Always start by importing the GLB and analyzing its structure:

```python
import bpy, bmesh

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
bpy.ops.import_scene.gltf(filepath="/assets/final_glb/{asset}_final.glb")

obj = [o for o in bpy.context.scene.objects if o.type == "MESH"][0]
print(f"Vertices: {len(obj.data.vertices)}")
print(f"Faces: {len(obj.data.polygons)}")

# Axis distributions — find geometry regions
for axis_name, axis_idx in [("X", 0), ("Y", 1), ("Z", 2)]:
    vals = [v.co[axis_idx] for v in obj.data.vertices]
    print(f"{axis_name}: {min(vals):.4f} to {max(vals):.4f} (span: {max(vals)-min(vals):.4f})")
```

**Critical:** glTF Y-up is converted to Blender Z-up on import. Z is the vertical axis in Blender.

### 2. Render Reference Image

Take a "before" render to compare against later:

```python
import bpy, math

scene = bpy.context.scene
scene.render.engine = "BLENDER_EEVEE"
scene.render.resolution_x = 512
scene.render.resolution_y = 512
scene.render.film_transparent = True

cam = bpy.data.cameras.new("Camera")
cam_obj = bpy.data.objects.new("Camera", cam)
scene.collection.objects.link(cam_obj)
scene.camera = cam_obj
cam_obj.location = (0, -2.0, 0)
cam_obj.rotation_euler = (math.radians(90), 0, 0)
cam.lens = 50

light = bpy.data.lights.new("Sun", "SUN")
light.energy = 3
light_obj = bpy.data.objects.new("Sun", light)
scene.collection.objects.link(light_obj)
light_obj.location = (1, -1, 2)

scene.render.filepath = "/assets/final_glb/{asset}_before.png"
bpy.ops.render.render(write_still=True)
```

Use the `view` tool on the rendered PNG to inspect visually.

### 3. Apply Modifications

See the modification patterns below for specific techniques.

### 4. Render and Compare

Render an "after" image and compare with `view`:

```python
scene.render.filepath = "/assets/final_glb/{asset}_after.png"
bpy.ops.render.render(write_still=True)
```

### 5. Export

```python
import bpy, os

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

os.makedirs("/assets/final_glb", exist_ok=True)
bpy.ops.export_scene.gltf(
    filepath="/assets/final_glb/{asset}_modified.glb",
    export_format="GLB",
    use_selection=False,
    export_apply=True,
)
```

### 6. Validate

Run trimesh checks on the exported GLB:

```bash
python3 -c "
import trimesh, os
path = os.path.expanduser('~/assets/final_glb/{asset}_modified.glb')
scene = trimesh.load(path)
mesh = scene.to_geometry()
z_range = mesh.bounds[1][2] - mesh.bounds[0][2]
print(f'Vertices: {len(mesh.vertices)}')
print(f'Z-depth: {z_range:.4f}')
print(f'File size: {os.path.getsize(path) / (1024*1024):.1f} MB')
"
```

For full validation, invoke the **asset-validator** agent.

---

## Modification Patterns

### Pattern 1: Remove Geometry by Region (e.g., remove base/stand/slab)

**Technique:** Select vertices below/above a threshold on one axis, delete them, clean up.

**Steps:**
1. **Analyze** — histogram vertex positions along the relevant axis to find the boundary
2. **Identify boundary** — look for a density drop or X-spread change between the unwanted geometry and the rest

```python
# Analyze X-spread at Z levels to find where body ends and slab begins
verts = [(v.co.x, v.co.y, v.co.z) for v in obj.data.vertices]
for z in [-0.50, -0.45, -0.40, -0.35, -0.30]:
    band = [v for v in verts if abs(v[2] - z) < 0.01]
    if band:
        x_span = max(v[0] for v in band) - min(v[0] for v in band)
        print(f"Z≈{z:.2f}: {len(band)} verts, X-span={x_span:.3f}")
```

A slab/platform will have wider X/Y span than the character body at the same height.

3. **Delete** — use bmesh in edit mode:

```python
import bmesh

bpy.context.view_layer.objects.active = obj
bpy.ops.object.mode_set(mode="EDIT")
bm = bmesh.from_edit_mesh(obj.data)
bm.verts.ensure_lookup_table()

THRESHOLD = -0.40  # Adjust based on analysis
for v in bm.verts:
    v.select = v.co.z < THRESHOLD

bpy.ops.mesh.delete(type="VERT")
bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.mesh.delete_loose(use_verts=True, use_edges=True, use_faces=False)
bpy.ops.mesh.normals_make_consistent(inside=False)
bpy.ops.object.mode_set(mode="OBJECT")
```

**Pitfalls:**
- Too aggressive threshold clips desired geometry (feet, bottom details)
- Too conservative leaves remnants
- Always render after deletion to verify visually

### Pattern 2: Recolor a Region (e.g., change hair color)

**Technique:** Map 3D vertex positions → UV coordinates → texture pixels, then hue-shift matching pixels.

This is a two-step process because Trellis2 assets use baked textures (image textures, not vertex colors).

**Step 1: Build a UV pixel mask for the target region**

```python
import colorsys

mesh = obj.data
uv_layer = mesh.uv_layers.active
w, h = base_img.size

target_pixels = set()
for poly in mesh.polygons:
    verts = [mesh.vertices[vi] for vi in poly.vertices]
    avg_z = sum(v.co.z for v in verts) / len(verts)
    avg_x = sum(v.co.x for v in verts) / len(verts)

    # Define the target region (adjust per asset)
    is_target = False
    if avg_z > 0.22:
        is_target = True  # Definitely in target region
    elif avg_z > 0.10 and abs(avg_x) > 0.14:
        is_target = True  # Side areas at mid-height

    if is_target:
        uvs = [uv_layer.data[li].uv for li in poly.loop_indices]
        u_min = max(0, int(min(uv[0] for uv in uvs) * w))
        u_max = min(w-1, int(max(uv[0] for uv in uvs) * w))
        v_min = max(0, int(min(uv[1] for uv in uvs) * h))
        v_max = min(h-1, int(max(uv[1] for uv in uvs) * h))

        for py in range(v_min, v_max + 1):
            for px in range(u_min, u_max + 1):
                target_pixels.add((px, py))
```

**Step 2: Hue-shift matching pixels**

```python
pixels = list(base_img.pixels)
TARGET_HUE = 120.0 / 360.0  # Green (0=red, 120=green, 240=blue)

for px, py in target_pixels:
    i = (py * w + px) * 4
    r, g, b, a = pixels[i], pixels[i+1], pixels[i+2], pixels[i+3]
    if a < 0.1:
        continue

    h_val, s, v = colorsys.rgb_to_hsv(r, g, b)
    h_deg = h_val * 360

    # Only shift pixels that match the source color
    is_source_color = (h_deg >= 320 or h_deg <= 35)  # Red/orange
    if is_source_color and s > 0.20 and v > 0.05:
        new_r, new_g, new_b = colorsys.hsv_to_rgb(TARGET_HUE, min(s * 1.1, 1.0), v)
        pixels[i] = new_r
        pixels[i+1] = new_g
        pixels[i+2] = new_b

base_img.pixels[:] = pixels
base_img.update()
```

**Key insight:** Combine position-based filtering (which polygons) with color-based filtering (which pixels within those polygons) for precise recoloring. Position alone catches too many shared UV regions. Color alone catches unrelated same-colored areas.

**Pitfalls:**
- UV bounding boxes are approximate — polygon UV islands may overlap with non-target geometry
- Desaturated colors (grey face) can fall in the same hue range as saturated colors (red hair) — always filter by saturation
- Trellis2 textures have two images: base color AND metallic/roughness — modify the base color only

### Pattern 3: Scale or Transform a Region

```python
import bmesh

bpy.ops.object.mode_set(mode="EDIT")
bm = bmesh.from_edit_mesh(obj.data)
bm.verts.ensure_lookup_table()

# Select target region
for v in bm.verts:
    v.select = v.co.z > 0.20  # e.g., head region

# Scale selected vertices
import mathutils
bpy.ops.transform.resize(value=(1.2, 1.2, 1.2))  # 20% larger

bmesh.update_edit_mesh(obj.data)
bpy.ops.object.mode_set(mode="OBJECT")
```

### Pattern 4: Fill Holes After Deletion

If geometry removal leaves holes (open edges):

```python
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="DESELECT")

# Select boundary edges (edges with only one face)
bm = bmesh.from_edit_mesh(obj.data)
for edge in bm.edges:
    if len(edge.link_faces) == 1:
        edge.select = True

# Fill the hole
bpy.ops.mesh.edge_face_add()
bpy.ops.object.mode_set(mode="OBJECT")
```

---

## Common Hue Values for Recoloring

| Color | Hue (degrees) | HSV H value |
|-------|--------------|-------------|
| Red | 0° | 0.000 |
| Orange | 30° | 0.083 |
| Yellow | 60° | 0.167 |
| Green | 120° | 0.333 |
| Cyan | 180° | 0.500 |
| Blue | 240° | 0.667 |
| Purple | 270° | 0.750 |
| Magenta | 300° | 0.833 |

## Important Rules

1. **Always render before/after** — visual comparison catches issues automated checks miss
2. **Z is up in Blender** — glTF Y-up is converted on import
3. **Use `to_geometry()` for trimesh** — Trellis2 GLBs load as Scene objects, not Trimesh
4. **Blender render engine is `BLENDER_EEVEE`** — not `BLENDER_EEVEE_NEXT`
5. **Container paths** — host `~/assets/` maps to container `/assets/`
6. **Modify base color texture only** — the second texture is metallic/roughness
7. **Combine position + color filtering** — neither alone is precise enough for recoloring
8. **Saturation filter is critical** — prevents grey/white areas from being hue-shifted
9. **Export as GLB** — always use `export_format="GLB"` for game-ready assets
10. **Clean up after deletion** — `delete_loose` + `normals_make_consistent` after removing geometry
11. **Trellis2 groove artifacts** — baked textures may have subtle groove/ridge patterns. For creatures with color variation these blend in; for uniform-colored areas, consider gentle texture blurring or hand-painting over affected regions.

## Error Handling

| Problem | Cause | Fix |
|---------|-------|-----|
| `No camera` render error | Camera deleted when scene cleared | Create camera before rendering |
| Screenshot tool fails | Headless Blender lacks viewport context | Use `bpy.ops.render.render()` to file instead |
| Recolor affects wrong areas | Position threshold too broad | Tighten Z/X thresholds, add saturation filter |
| Holes after geometry deletion | Open boundary edges remain | Fill with `edge_face_add()` or accept flat bottom |
| GLB larger after texture edit | Modified texture compresses differently | Normal — within ±1MB is expected |
| Trimesh `to_geometry()` fails | Multiple geometry objects in scene | Use `scene.dump(concatenate=True)` as fallback |

## MCP Helper Script

For convenience, use this pattern to execute bpy code:

```python
# /tmp/mcp_exec.py — execute bpy code via Blender MCP
import json, sys, urllib.request

MCP_URL = "http://localhost:8000/mcp"

def mcp_call(method, params, session_id=None):
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    if session_id:
        headers["Mcp-Session-Id"] = session_id
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(MCP_URL, data=body, headers=headers, method="POST")
    resp = urllib.request.urlopen(req)
    sid = resp.headers.get("Mcp-Session-Id", session_id)
    for line in resp.read().decode().split("\n"):
        if line.startswith("data: "):
            return json.loads(line[6:]), sid
    return json.loads(resp.read().decode()), sid

def init():
    data, sid = mcp_call("initialize", {
        "protocolVersion": "2025-03-26", "capabilities": {},
        "clientInfo": {"name": "cli", "version": "1.0"}
    })
    return sid

def execute_code(code, session_id):
    data, _ = mcp_call("tools/call", {
        "name": "execute_blender_code", "arguments": {"code": code}
    }, session_id)
    for item in data.get("result", {}).get("content", []):
        if item.get("text"):
            print(item["text"])

sid = init()
execute_code(sys.stdin.read(), sid)
```

Usage: `python3 /tmp/mcp_exec.py << 'CODE' ... CODE`
