# GodotAssetViewer — Project Instructions

## Project Overview

**GodotAssetViewer** is a Godot 4.6 Mono project. C# for all gameplay logic; GDScript only for editor tooling. Jolt physics, Forward Plus rendering, Vulkan on Linux. Integrated AI-driven 3D asset generation pipeline.

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

EventBus lives in `game/EventBus.cs` as an AutoLoad singleton with typed delegates.

| Scenario | Use | Why |
|---|---|---|
| Cross-system broadcast (e.g. score changed, player died) | **EventBus** | Decouples sender from receivers globally |
| Parent ↔ child within a single scene branch | **Godot Signal** | Keeps coupling local and explicit |
| UI reacting to game state | **EventBus** | UI doesn't need a reference to the emitter |
| Animation finished / tween completed | **Godot Signal** | One-off, local concern |

### Implementation

```csharp
// Declare in game/EventBus.cs
public delegate void ScoreChangedHandler(int newScore);
public static event ScoreChangedHandler? ScoreChanged;
public static void EmitScoreChanged(int newScore) => ScoreChanged?.Invoke(newScore);
```

Always subscribe in `_Ready()`, unsubscribe in `_ExitTree()` to prevent memory leaks:

```csharp
public override void _Ready() { EventBus.ScoreChanged += OnScoreChanged; }
public override void _ExitTree() { EventBus.ScoreChanged -= OnScoreChanged; }
```

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

### Hand-Written Scene Rules

For hand-written `.tscn` files, use `[Export] NodePath` fields resolved with `GetNode<T>()` in `_Ready()`:

```csharp
[Export] public NodePath SpritePath { get; set; } = null!;
private Sprite2D _sprite = null!;

public override void _Ready()
{
    _sprite = GetNode<Sprite2D>(SpritePath);
    System.Diagnostics.Debug.Assert(_sprite != null, "SpritePath must be set");
}
```

Prefer editor-generated scenes; hand-write only when necessary.

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

## Testing Strategy

| Runner | Scope | Notes |
|---|---|---|
| `dotnet test` | Pure C# logic tests | Fast, no engine dependency |
| `./tools/test.sh` | Godot runtime, GDScript tests, engine-aware integration tests | Requires headless Godot |

- **Node-derived classes crash `dotnet test`** — keep core logic in pure C# helper classes
- Always unsubscribe EventBus in `_ExitTree()` to prevent test pollution
- Avoid async anti-patterns in tests (e.g. `ToSignal` after `AddChild` can hang)

## Important Notes

- **Physics Layers**: interactables → layer 2, ground → layer 1
- **Renderer**: Vulkan (Forward Plus) on Linux
- **Godot Version**: 4.6+ Mono
- **Always commit `.uid` files** — run `lint_project.gd` after scene/resource edits
- For authoritative build/test/lint commands, see `AGENTS.md`
- For 3D asset pipeline details, use the `asset-pipeline` skill
- For runtime verification workflow, use the `devtools-runtime` skill
