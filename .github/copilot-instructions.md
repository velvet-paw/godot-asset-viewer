# GodotAssetViewer — Project Instructions

## Project Overview

**GodotAssetViewer** (renamed from TeaLeaves) is a Godot 4.6 Mono project.

- **C#** for all gameplay logic; **GDScript** only for editor tooling
- **Jolt Physics** engine, **Forward Plus** rendering, **Vulkan** on Linux
- Integrated AI-driven 3D asset generation pipeline (ComfyUI + Trellis2 + CHORD PBR + Blender)

## First-Time Setup

```bash
dotnet restore
dotnet build -warnaserror
./tools/godot.sh --headless --script res://tools/setup_input_actions_cli.gd
dotnet test
./tools/test.sh
```

## Core Tenets

1. **C# for gameplay, GDScript only for editor tooling**
2. **Composition over inheritance** for Nodes
3. **Typed EventBus** for cross-system communication
4. **Data-driven configs** using Godot Resource assets (`[GlobalClass]` C# classes)
5. **Fail-fast validation** — assert in `_Ready()`
6. **Deterministic state machines**
7. **Test-driven debugging**

## Language Usage

- **C#** — all gameplay logic, systems, and tests
- **GDScript** — ONLY for editor tools and scene glue scripts
- Namespace convention: `TeaLeaves.*`, `TeaLeaves.Systems.*`

## EventBus Pattern

### When to Use EventBus vs Godot Signals

| Scenario | Use | Why |
|---|---|---|
| Cross-system broadcast (e.g. score changed, player died) | **EventBus** | Decouples sender from receivers globally |
| Parent ↔ child within a single scene branch | **Godot Signal** | Keeps coupling local and explicit |
| UI reacting to game state | **EventBus** | UI doesn't need a reference to the emitter |
| Animation finished / tween completed | **Godot Signal** | One-off, local concern |

### Implementation

EventBus lives in `game/EventBus.cs` as an AutoLoad singleton with typed delegates:

```csharp
// Declare typed delegate + event
public delegate void ScoreChangedHandler(int newScore);
public static event ScoreChangedHandler? ScoreChanged;

// Emit helper
public static void EmitScoreChanged(int newScore) => ScoreChanged?.Invoke(newScore);
```

### Subscribing / Unsubscribing

Always unsubscribe in `_ExitTree()` to prevent memory leaks and stale references:

```csharp
public override void _Ready()
{
    EventBus.ScoreChanged += OnScoreChanged;
}

public override void _ExitTree()
{
    EventBus.ScoreChanged -= OnScoreChanged;
}

private void OnScoreChanged(int newScore)
{
    // handle event
}
```

### Emitting Events

```csharp
EventBus.EmitScoreChanged(42);
```

### Adding New Events

1. Add a delegate type and `static event` field in `game/EventBus.cs`
2. Add a static `Emit*` helper method
3. Subscribe in `_Ready()`, unsubscribe in `_ExitTree()`

### Testing EventBus

- Subscribe in test setup, assert expected values in the handler
- Unsubscribe in teardown to isolate tests

## C# Conventions

- **Physics** → `_PhysicsProcess(double delta)` (never `_Process` for physics)
- **`[Export]`** with proper hints for inspector-editable fields
- **`[GlobalClass]`** on custom Resource subclasses
- **Validate in `_Ready()`** with asserts (fail fast)
- **`GD.PushError()`** for runtime issues that shouldn't crash
- **`GlobalPosition`** requires the node to be in the scene tree — call `AddChild()` first
- **Nullable fields**: use `= null!` for fields initialized in `_Ready()`

### Resource Patterns

```csharp
[GlobalClass]
public partial class EnemyData : Resource
{
    [Export] public float Speed { get; set; } = 100f;
    [Export] public int Health { get; set; } = 3;
}
```

### Hand-Written Scene NodePath Patterns

Use `[Export] NodePath` and resolve in `_Ready()`:

```csharp
[Export] public NodePath SpritePath { get; set; } = null!;
private Sprite2D _sprite = null!;

public override void _Ready()
{
    _sprite = GetNode<Sprite2D>(SpritePath);
    System.Diagnostics.Debug.Assert(_sprite != null, "SpritePath must be set");
}
```

## Key Commands

All commands are bash (not PowerShell).

```bash
# Build & Test
dotnet restore && dotnet build -warnaserror
dotnet test
./tools/test.sh
./tools/godot.sh --headless --script res://tools/lint_project.gd

# Linting
./tools/godot.sh --headless --script res://tools/lint_shaders.gd
gdlint path/to/file.gd
./tools/lint_tests.sh

# DevTools runtime
python tools/devtools.py ping
python tools/devtools.py screenshot --filename "verification.png"
python tools/devtools.py validate-all
python tools/devtools.py performance
python tools/devtools.py input tap jump
python tools/devtools.py input clear

# Asset viewer
python tools/devtools.py asset-list --type texture
python tools/devtools.py asset-load res://path/to/asset.glb
python tools/devtools.py asset-screenshot --filename check.png
```

## Project Structure

```
res://
  scripts/         # C# gameplay code
  actors/          # Player and NPCs (scenes)
  levels/          # Level scenes
  ui/              # HUD, menus, asset_viewer/
  util/            # Camera rigs, markers
  game/            # AutoLoads (DevTools, EventBus)
  data/            # Resource definitions
  test/            # gdUnit4 tests + sequences/
  tools/           # Lint/setup scripts (GDScript, bash)
  addons/          # Third-party addons (gdUnit4)
  pipeline/        # AI asset generation pipeline scripts
  comfyui/         # ComfyUI workflow configs
  plans/           # Design documents
```

## Validation Pipeline

Run before every commit:

1. `dotnet build -warnaserror`
2. `dotnet test`
3. `./tools/test.sh`
4. `./tools/godot.sh --headless --script res://tools/lint_project.gd`
5. `gdlint` for any modified GDScript files

## Testing Strategy

| Runner | Scope | Notes |
|---|---|---|
| `dotnet test` | Pure C# logic tests | Fast, no engine dependency |
| `./tools/test.sh` | Godot runtime, GDScript tests, engine-aware integration tests | Requires headless Godot |

- **Node-derived classes crash `dotnet test`** — keep core logic in pure C# helper classes
- Always unsubscribe EventBus in `_ExitTree()` to prevent test pollution
- Avoid async anti-patterns in tests

## DevTools

File-based protocol under `user://`:

| File | Purpose |
|---|---|
| `devtools_commands.json` | Command inbox (write commands here) |
| `devtools_results.json` | Result outbox (read responses here) |

Supported commands: `screenshot`, `validate`, `scene-tree`, `input` (tap/clear simulation), `performance`, `get-state`, `set-state`.

## Asset Generation Pipeline

### Tools

| Stage | Tool | Purpose |
|---|---|---|
| Concept | ComfyUI (Flux) | Text-to-image generation |
| Mask | BiRefNet | Background removal |
| 3D | Trellis2 (primary) | Image-to-3D textured mesh |
| PBR | CHORD | PBR material maps (used only when Trellis2 textures are stripped or absent) |
| Post-process | Blender | Mesh cleanup, decimation, rigging, LODs, export |

### Pipeline Flow

```
concept → mask → Trellis2 3D (baked textures) → Blender post-process
```

- **Output**: `~/assets/final_glb/{asset_name}_final.glb`
- **Import**: `tools/import-asset.sh` copies assets into `res://`
- **Agent configs**: `.github/agents/` contains orchestrator, validator, generator, and modifier agent definitions

### Creature-Specific Guidance

- **Concept art must have color variation** — uniform white/grey surfaces expose Trellis2 groove artifacts. Use distinct markings (e.g., grey body, lighter belly, darker back).
- **Quadruped prompts**: include `three-quarter front view, all four legs visible and separated, fluffy tail, bold clean cel-shaded forms`.
- **Vertex targets for Trellis2 baked textures**: 150K for creatures, 100K for props, 50K for weapons. This applies universally — decimation below 50K destroys baked UV mapping regardless of asset type.
- **Trellis2 default params**: keep at 12 sampling steps, 7.5 guidance. Higher values cause CUDA OOM on RTX 3090.

### Stage 6 Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ASSET_TYPE` | `creature` | Controls vertex target, scale, rigging |
| `TARGET_VERTS` | (per type) | Override vertex target |
| `TARGET_HEIGHT` | (per type) | Override height in meters |
| `GENERATE_LODS` | `0` | Set `1` to produce LOD1 + LOD2 |
| `GENERATE_COLLISION` | `0` | Set `1` to produce convex hull collision |
| `FORCE_PBR` | `0` | Set `1` to strip Trellis2 textures and apply fresh UV + CHORD PBR |
| `UV_METHOD` | `smart` | `smart` for Smart UV Project, `camera` for concept-art-aligned projection |
| `PBR_CHANNELS` | `all` | Comma-separated list: `albedo,normal,roughness,metallic,height` |
| `SKIP_RIGGING` | `0` | Set `1` to skip armature/weighting |
| `SKIP_GROUND_REMOVAL` | `0` | Set `1` to keep ground plane |

## Important Notes

- **Physics Layers**: interactables → layer 2, ground → layer 1
- **Renderer**: Vulkan (Forward Plus) on Linux
- **Godot Version**: 4.6+ Mono
- **Always commit `.uid` files**
- **UID integrity**: run `lint_project.gd` after scene/resource edits
