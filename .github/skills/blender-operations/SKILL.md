---
name: blender-operations
description: Blender MCP operations for 3D assets — GLB import/inspect, EEVEE rendering, export, trimesh validation, modification patterns (geometry removal, recoloring, scaling), and MCP helper script. Use when importing GLB into Blender, rendering assets, exporting from Blender, or modifying 3D meshes.
allowed-tools: shell
---

# Blender Operations

All operations go through **Blender MCP** (`execute_blender_code` tool) at `http://localhost:8000`.

## Container Path Mapping

| Host path | Container path |
|-----------|---------------|
| `~/assets/raw_3d/` | `/assets/raw_3d/` |
| `~/assets/pbr_maps/` | `/assets/pbr_maps/` |
| `~/assets/final_glb/` | `/assets/final_glb/` |

## Import and Inspect GLB

```python
import bpy

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
bpy.ops.import_scene.gltf(filepath="/assets/final_glb/{asset}_final.glb")

obj = [o for o in bpy.context.scene.objects if o.type == "MESH"][0]
print(f"Vertices: {len(obj.data.vertices)}")
print(f"Faces: {len(obj.data.polygons)}")

for axis_name, axis_idx in [("X", 0), ("Y", 1), ("Z", 2)]:
    vals = [v.co[axis_idx] for v in obj.data.vertices]
    print(f"{axis_name}: {min(vals):.4f} to {max(vals):.4f} (span: {max(vals)-min(vals):.4f})")
```

**Critical:** glTF Y-up → Blender Z-up on import. Z is vertical in Blender.

## Render Reference Image (EEVEE)

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

scene.render.filepath = "/assets/final_glb/{asset}_render.png"
bpy.ops.render.render(write_still=True)
```

Use `view` tool on rendered PNGs to inspect visually. Render before AND after modifications.

## Export GLB

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

## Post-Export Trimesh Validation

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

## Modification Patterns

### Geometry Removal (e.g., remove base/stand/slab)

1. **Analyze** — histogram vertex positions to find boundary:

```python
verts = [(v.co.x, v.co.y, v.co.z) for v in obj.data.vertices]
for z in [-0.50, -0.45, -0.40, -0.35, -0.30]:
    band = [v for v in verts if abs(v[2] - z) < 0.01]
    if band:
        x_span = max(v[0] for v in band) - min(v[0] for v in band)
        print(f"Z≈{z:.2f}: {len(band)} verts, X-span={x_span:.3f}")
```

2. **Delete** in edit mode:

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

3. **Fill holes** if needed:

```python
bpy.ops.object.mode_set(mode="EDIT")
bm = bmesh.from_edit_mesh(obj.data)
for edge in bm.edges:
    if len(edge.link_faces) == 1:
        edge.select = True
bpy.ops.mesh.edge_face_add()
bpy.ops.object.mode_set(mode="OBJECT")
```

### Recolor Region (Trellis2 baked textures)

Two-step: map 3D vertex positions → UV coords → texture pixels, then hue-shift.

**Step 1: Build UV pixel mask:**

```python
import colorsys

mesh = obj.data
uv_layer = mesh.uv_layers.active
w, h = base_img.size
target_pixels = set()

for poly in mesh.polygons:
    verts = [mesh.vertices[vi] for vi in poly.vertices]
    avg_z = sum(v.co.z for v in verts) / len(verts)
    # Define target region (adjust per asset)
    if avg_z > 0.22:
        uvs = [uv_layer.data[li].uv for li in poly.loop_indices]
        u_min = max(0, int(min(uv[0] for uv in uvs) * w))
        u_max = min(w-1, int(max(uv[0] for uv in uvs) * w))
        v_min = max(0, int(min(uv[1] for uv in uvs) * h))
        v_max = min(h-1, int(max(uv[1] for uv in uvs) * h))
        for py in range(v_min, v_max + 1):
            for px in range(u_min, u_max + 1):
                target_pixels.add((px, py))
```

**Step 2: Hue-shift matching pixels:**

```python
pixels = list(base_img.pixels)
TARGET_HUE = 120.0 / 360.0  # Green

for px, py in target_pixels:
    i = (py * w + px) * 4
    r, g, b, a = pixels[i], pixels[i+1], pixels[i+2], pixels[i+3]
    if a < 0.1:
        continue
    h_val, s, v = colorsys.rgb_to_hsv(r, g, b)
    h_deg = h_val * 360
    is_source = (h_deg >= 320 or h_deg <= 35)  # Red/orange range
    if is_source and s > 0.20 and v > 0.05:
        new_r, new_g, new_b = colorsys.hsv_to_rgb(TARGET_HUE, min(s * 1.1, 1.0), v)
        pixels[i], pixels[i+1], pixels[i+2] = new_r, new_g, new_b

base_img.pixels[:] = pixels
base_img.update()
```

**Key:** Combine position-based filtering (which polygons) with color-based filtering (which pixels). Modify base color texture ONLY — the second texture is metallic/roughness.

### Scale/Transform Region

```python
import bmesh

bpy.ops.object.mode_set(mode="EDIT")
bm = bmesh.from_edit_mesh(obj.data)
bm.verts.ensure_lookup_table()
for v in bm.verts:
    v.select = v.co.z > 0.20  # e.g., head region
bpy.ops.transform.resize(value=(1.2, 1.2, 1.2))
bmesh.update_edit_mesh(obj.data)
bpy.ops.object.mode_set(mode="OBJECT")
```

## Hue Reference Table

| Color | Hue (°) | HSV H |
|-------|---------|-------|
| Red | 0° | 0.000 |
| Orange | 30° | 0.083 |
| Yellow | 60° | 0.167 |
| Green | 120° | 0.333 |
| Cyan | 180° | 0.500 |
| Blue | 240° | 0.667 |
| Purple | 270° | 0.750 |
| Magenta | 300° | 0.833 |

## MCP Helper Script

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

## Important Rules

1. **Z is up in Blender** — glTF Y-up is converted on import
2. **Render engine is `BLENDER_EEVEE`** — not `BLENDER_EEVEE_NEXT`
3. **Container paths** — host `~/assets/` maps to container `/assets/`
4. **Always render before/after** — visual comparison catches what automation misses
5. **Use `to_geometry()` for trimesh** — Trellis2 GLBs load as Scene, not Trimesh
6. **Export as GLB** — always `export_format="GLB"`
7. **Clean up after deletion** — `delete_loose` + `normals_make_consistent`
8. **Modify base color texture only** — second texture is metallic/roughness
9. **Saturation filter is critical** for recoloring — prevents grey areas from shifting

## Error Handling

| Problem | Cause | Fix |
|---------|-------|-----|
| No camera render error | Camera deleted on scene clear | Create camera before rendering |
| Recolor affects wrong areas | Threshold too broad | Tighten Z/X thresholds, add saturation filter |
| Holes after deletion | Open boundary edges | Fill with `edge_face_add()` |
| GLB larger after texture edit | Compression differs | Normal — within ±1MB |
| `to_geometry()` fails | Multiple geometries | Use `scene.dump(concatenate=True)` |
