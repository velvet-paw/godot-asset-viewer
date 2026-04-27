# Asset Viewer Spec — tea-leaves / Godot 4.6 Mono

## What Asset Viewers Are Used For in Games

An asset viewer is a development tool that lets you browse, preview, and inspect the raw
content of a game project — textures, sprites, meshes, audio clips, animations, materials,
shaders, and scenes — without having to run the game itself or hunt through the file system
manually. In practice they serve several overlapping purposes:

- **Visual verification.** Artists and programmers confirm that imported assets look correct
  (right colours, resolution, UV maps, pivot points) before anything is wired into gameplay.
- **Import debugging.** When an asset misbehaves at runtime — wrong scale, missing mipmaps,
  corrupt audio — the viewer is the first place to check whether the import step itself failed.
- **AI agent verification.** Automated pipelines need a programmatic way to request screenshots
  of individual assets, compare them against reference images, and assert correctness without a
  human in the loop.
- **Content auditing.** Designers and producers browse the full asset catalogue to spot
  duplicates, unused files, or anything that doesn't match the visual style guide.
- **Rapid iteration.** Hot-reload or re-import a single asset and watch the preview update
  immediately, shortening the feedback loop between art software and engine.

---

## Spec: AssetViewer for tea-leaves

### Overview

`AssetViewer` is a Godot editor-side scene (`ui/asset_viewer/AssetViewer.tscn`) plus a
matching DevTools command family (`asset_viewer_*`) that exposes the same functionality to
the CLI and any coding agent. Human users navigate the viewer with a mouse and keyboard;
agents drive it through the existing DevTools file-based protocol.

The viewer must handle every importable asset type that tea-leaves already validates:
meshes, textures/sprites, audio streams, materials, shaders, animations, and packed scenes.

---

### 1. File Locations

```
ui/
  asset_viewer/
    AssetViewer.tscn          # Root scene — open this in Godot to run standalone
    AssetViewer.cs            # Control logic (C#)
    AssetList.cs              # Left-panel file tree / search list
    PreviewViewport.cs        # Right-panel SubViewport renderer
    AudioPreviewPanel.cs      # Waveform + play/stop for AudioStream assets
    AssetMetaPanel.cs         # Bottom metadata strip
    asset_viewer.theme        # Optional theme overrides

tools/
  asset_viewer_devtools.gd    # Registers asset_viewer_* commands with DevTools autoload
```

`AssetViewer.tscn` can be launched standalone (registered as a tool scene) or opened as a
sub-scene inside the existing `DevTools`-enabled game window so the command server is always
reachable.

---

### 2. Human-Facing UI

#### 2.1 Layout

```
┌──────────────────────────────────────────────────────┐
│  [ Search / Filter input ]   [ Type filter dropdown ] │  ← toolbar
├─────────────────┬────────────────────────────────────┤
│                 │                                     │
│   Asset list    │          Preview Viewport           │
│   (scrollable   │    (SubViewport, fills remaining    │
│    tree, left   │     space, camera auto-framed)      │
│    panel)       │                                     │
│                 │                                     │
├─────────────────┴────────────────────────────────────┤
│  Path | Type | Size | Import Date | Custom meta tags  │  ← meta strip
└──────────────────────────────────────────────────────┘
```

#### 2.2 Asset List Panel

- Populated by scanning `res://` recursively for recognised extensions (see §4 Asset Types).
- Supports free-text search (path substring or asset name).
- Type filter dropdown: All / Textures / Meshes / Audio / Materials / Shaders / Scenes /
  Animations.
- Keyboard: `↑`/`↓` navigate; `Enter` loads selected asset; `F5` refreshes list.
- Selecting an item loads it into the Preview Viewport and updates the Meta Strip.

#### 2.3 Preview Viewport

Implemented as a `SubViewport` node so renders are isolated from the main game window.

| Asset type          | Preview behaviour                                                   |
|---------------------|---------------------------------------------------------------------|
| Texture2D / Sprite  | Displayed on a quad mesh, zoom with scroll wheel, pan with MMB drag |
| Mesh / MeshInstance | Loaded in a scene with a `DirectionalLight3D`; orbit camera on LMB drag |
| Material            | Applied to a unit sphere; same orbit camera                        |
| Shader              | Applied to a sphere/quad according to shader type; orbit / scroll   |
| AudioStream         | Waveform visualised in `AudioPreviewPanel`; play/stop/seek bar     |
| AnimationPlayer     | Loads the associated scene, plays first animation; timeline slider  |
| PackedScene         | Instantiated and centred; orbit camera                              |

Camera framing: When loading a 3D asset the camera is auto-positioned to fit the asset's
AABB with a small padding factor (1.5×). This is recalculated on load and on window resize.

#### 2.4 Metadata Strip

Shows for every selected asset:
- Full `res://` path
- Detected Godot type
- File size (bytes)
- Import file modification time
- Any `.import` metadata key/value pairs (compressed format, mipmaps, etc.)

---

### 3. DevTools Command Surface (AI / CLI Access)

All commands follow the existing DevTools file-based protocol:
- **Inbox:** `user://devtools_commands.json`
- **Outbox:** `user://devtools_results.json`
- **Logs:** `user://devtools_log.jsonl`

The autoload polls every ~100 ms (matching existing behaviour). All responses include a
`"command"` echo, a `"status"` field (`"ok"` or `"error"`), and a `"result"` object.

#### 3.1 Command Reference

---

##### `asset_viewer_list`
List assets matching optional filters.

Request:
```json
{
  "command": "asset_viewer_list",
  "type_filter": "texture",   // optional: texture | mesh | audio | material | shader | scene | animation | all
  "search": "enemy",          // optional: substring match on path
  "limit": 50                 // optional, default 100
}
```

Response:
```json
{
  "command": "asset_viewer_list",
  "status": "ok",
  "result": {
    "count": 3,
    "assets": [
      { "path": "res://actors/enemy/enemy_sprite.png", "type": "CompressedTexture2D", "size_bytes": 14820 },
      { "path": "res://actors/enemy/enemy_mesh.glb",   "type": "ArrayMesh",           "size_bytes": 83210 },
      { "path": "res://actors/enemy/enemy_idle.tres",  "type": "Animation",            "size_bytes": 3400  }
    ]
  }
}
```

---

##### `asset_viewer_load`
Load a specific asset into the preview viewport.

Request:
```json
{
  "command": "asset_viewer_load",
  "path": "res://actors/enemy/enemy_sprite.png"
}
```

Response:
```json
{
  "command": "asset_viewer_load",
  "status": "ok",
  "result": {
    "path": "res://actors/enemy/enemy_sprite.png",
    "type": "CompressedTexture2D",
    "size_bytes": 14820,
    "import_meta": {
      "compress/mode": "2",
      "mipmaps/generate": "false",
      "process/size_limit": "0"
    }
  }
}
```

---

##### `asset_viewer_screenshot`
Capture the current preview viewport to a PNG file.

Request:
```json
{
  "command": "asset_viewer_screenshot",
  "filename": "enemy_sprite_check.png"  // saved under the standard screenshots/ directory
}
```

Response:
```json
{
  "command": "asset_viewer_screenshot",
  "status": "ok",
  "result": {
    "path": "%APPDATA%/Godot/app_userdata/TeaLeaves/screenshots/enemy_sprite_check.png"
  }
}
```

---

##### `asset_viewer_camera`
Adjust camera for 3D previews.

Request:
```json
{
  "command": "asset_viewer_camera",
  "action": "orbit",     // orbit | zoom | reset | set_position
  "delta_yaw":   45.0,   // degrees, used with "orbit"
  "delta_pitch": -15.0,
  "zoom_factor":  1.2,   // used with "zoom"
  "position": [0, 1, 3]  // used with "set_position"
}
```

Response:
```json
{
  "command": "asset_viewer_camera",
  "status": "ok",
  "result": {
    "yaw": 45.0,
    "pitch": -15.0,
    "distance": 3.2
  }
}
```

---

##### `asset_viewer_audio`
Control audio playback for AudioStream assets.

Request:
```json
{
  "command": "asset_viewer_audio",
  "action": "play"    // play | stop | seek
  "position_sec": 0.0 // used with "seek"
}
```

Response:
```json
{
  "command": "asset_viewer_audio",
  "status": "ok",
  "result": {
    "state": "playing",
    "position_sec": 0.0,
    "duration_sec": 4.32
  }
}
```

---

##### `asset_viewer_get_meta`
Return full metadata for a path without loading it visually.

Request:
```json
{
  "command": "asset_viewer_get_meta",
  "path": "res://actors/enemy/enemy_sprite.png"
}
```

Response:
```json
{
  "command": "asset_viewer_get_meta",
  "status": "ok",
  "result": {
    "path": "res://actors/enemy/enemy_sprite.png",
    "type": "CompressedTexture2D",
    "size_bytes": 14820,
    "dimensions": { "width": 128, "height": 128 },
    "import_meta": { "compress/mode": "2", "mipmaps/generate": "false" }
  }
}
```

---

##### `asset_viewer_validate`
Confirm an asset loads without errors (does not update the preview UI).

Request:
```json
{
  "command": "asset_viewer_validate",
  "path": "res://actors/enemy/enemy_mesh.glb"
}
```

Response (`status` is `"error"` if load fails):
```json
{
  "command": "asset_viewer_validate",
  "status": "ok",
  "result": {
    "valid": true,
    "warnings": []
  }
}
```

---

#### 3.2 Python CLI Wrappers

Add these to `tools/devtools.py` following the existing command pattern:

```bash
# List all textures mentioning "enemy"
python tools/devtools.py asset-list --type texture --search enemy

# Load asset into viewer
python tools/devtools.py asset-load res://actors/enemy/enemy_sprite.png

# Screenshot the current preview
python tools/devtools.py asset-screenshot --filename enemy_check.png

# Orbit camera 45 degrees yaw
python tools/devtools.py asset-camera orbit --yaw 45 --pitch -15

# Play audio
python tools/devtools.py asset-audio play

# Get metadata only (no visual load)
python tools/devtools.py asset-meta res://actors/enemy/enemy_sprite.png

# Validate without loading
python tools/devtools.py asset-validate res://actors/enemy/enemy_mesh.glb
```

---

### 4. Asset Types and Extensions

| Type label   | Extensions / Resource types                              |
|--------------|----------------------------------------------------------|
| `texture`    | `.png .jpg .webp .svg .bmp .tga` → `CompressedTexture2D` |
| `mesh`       | `.glb .gltf .obj .fbx` → `ArrayMesh` / `ImporterMesh`   |
| `audio`      | `.wav .ogg .mp3` → `AudioStreamWAV` / `AudioStreamOggVorbis` |
| `material`   | `.tres .res` typed as `BaseMaterial3D` / `ShaderMaterial` |
| `shader`     | `.gdshader`                                              |
| `scene`      | `.tscn .scn`                                             |
| `animation`  | `.tres .res` typed as `Animation` / `AnimationLibrary`   |

---

### 5. Architecture Notes

#### C# vs GDScript split

Follow the project's existing convention:

- `AssetViewer.cs`, `AssetList.cs`, `PreviewViewport.cs`, `AudioPreviewPanel.cs`,
  `AssetMetaPanel.cs` — all C#. These are the runtime control classes.
- `asset_viewer_devtools.gd` — GDScript glue that hooks into the DevTools autoload and
  dispatches `asset_viewer_*` commands to the C# `AssetViewer` singleton (exposed via
  `[GlobalClass]` or accessed through the scene tree).

#### SubViewport isolation

`PreviewViewport` wraps a `SubViewport` with its own `Camera3D` / `Camera2D` and a minimal
scene (lights, grid floor optional). Load the target resource into this viewport, not the
main scene tree, to prevent any side-effects on gameplay state.

#### Resource loading

Use `ResourceLoader.Load<T>(path)` (C#). Never use `GD.Load` for type-sensitive assets.
For large meshes or scenes, use `ResourceLoader.LoadThreadedRequest` and poll with
`ResourceLoader.LoadThreadedGetStatus` so the UI stays responsive.

#### Camera auto-frame (3D)

```csharp
// After loading a 3D asset, calculate AABB and position camera:
Aabb bounds = mesh.GetAabb();
float radius = bounds.Size.Length() * 0.5f;
camera.Position = bounds.GetCenter() + new Vector3(0, radius * 0.5f, radius * 1.5f);
camera.LookAt(bounds.GetCenter(), Vector3.Up);
```

#### EventBus integration

Emit typed bus events so other tools can react without tight coupling:

```csharp
EventBus.Emit(new AssetLoadedEvent { Path = path, Type = assetType });
EventBus.Emit(new AssetPreviewReadyEvent { Path = path });
```

---

### 6. Tests

#### C# unit tests (`dotnet test`)

- `AssetListTests.cs` — filter/search logic, extension-to-type mapping.
- `AssetMetaTests.cs` — metadata extraction for each asset type.
- `PreviewViewportTests.cs` — camera auto-frame calculation (pure math, no Godot runtime).

#### gdUnit4 runtime tests (`pwsh ./tools/test.ps1`)

- `test_asset_viewer_load.gd` — loads a known `.png` and `.glb` fixture, asserts no errors.
- `test_asset_viewer_devtools.gd` — sends `asset_viewer_list` and `asset_viewer_load`
  commands via the DevTools inbox, reads the outbox, asserts `"status": "ok"`.

#### Sequences

`test/sequences/asset_viewer_smoke.json` — agent sequence that:
1. Calls `asset_viewer_list` (all types).
2. Loads the first texture result.
3. Takes a screenshot (`asset_viewer_smoke_texture.png`).
4. Orbits the camera 90°.
5. Takes a second screenshot (`asset_viewer_smoke_texture_rotated.png`).
6. Asserts both files exist and are non-zero bytes.

---

### 7. Verification Gate

After implementation, the following must all pass before the feature is considered done,
per the AGENTS.md definition of done:

```bash
dotnet build -warnaserror
dotnet test
pwsh ./tools/test.ps1
pwsh ./tools/godot.ps1 --headless --script res://tools/lint_project.gd

# Runtime smoke test
pwsh ./tools/godot.ps1
python tools/devtools.py ping
python tools/devtools.py asset-list --type texture
python tools/devtools.py asset-load res://icon.svg
python tools/devtools.py asset-screenshot --filename asset_viewer_smoke.png
python tools/devtools.py validate-all
python tools/devtools.py performance
python tools/devtools.py input clear
```

Screenshot artifacts land in:
`%APPDATA%/Godot/app_userdata/TeaLeaves/screenshots/`

---

### 8. Open Questions / Future Work

- **Hot-reload:** Watch `.import` file mtime and auto-refresh the preview without a manual
  `F5`. Godot's `FileSystemWatcher` or a polling timer are both viable.
- **Diff mode:** Compare two asset versions side-by-side (useful when an artist updates a
  texture and an agent needs to confirm the change landed correctly).
- **Thumbnail cache:** Pre-render 64×64 thumbnails for the asset list so scrolling is fast
  on large projects. Store in `user://asset_viewer_cache/`.
- **Tag / annotation support:** Let humans attach freeform tags to assets and expose them
  through `asset_viewer_get_meta` so agents can query by semantic label.
- **Batch validate:** `asset_viewer_validate_all` command that runs `asset_viewer_validate`
  for every file in the project and returns an aggregated report — natural complement to the
  existing `validate_all_scenes` command.