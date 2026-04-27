# Godot Asset Viewer

A Godot 4.6 Mono asset viewer with an integrated AI-driven 3D asset generation pipeline. Browse, preview, and inspect game assets directly in the engine, and generate new 3D assets from text prompts using ComfyUI + Trellis2 + CHORD PBR + Blender.

## Technical Snapshot

- Engine: Godot 4.6 Mono
- Gameplay language: C# (`net8.0`)
- Tooling language: GDScript + Bash + Python
- Physics: Jolt
- Renderer: Forward Plus (Vulkan on Linux)
- Test stack: `dotnet test` + gdUnit4 via `./tools/test.sh`
- AI pipeline: ComfyUI → BiRefNet → Trellis2 → CHORD PBR → Blender

## Runtime Architecture

### Boot Autoloads

`project.godot` wires two autoloads:

- `WindowSetup` (`game/WindowSetup.cs`): handles window placement at startup.
- `DevTools` (`game/DevTools.cs`): runtime command server used by local automation and AI agents.

### DevTools File Protocol

`DevTools` uses a file-based transport under `user://`:

- Command inbox: `devtools_commands.json`
- Result outbox: `devtools_results.json`
- Structured log stream: `devtools_log.jsonl`

The autoload polls every ~100 ms, dispatches commands, and writes structured JSON responses for CLI clients.

### Runtime Command Surface

Implemented command families:

- Visual: `screenshot`, `scene_tree`
- Validation: `validate_scene`, `validate_all_scenes`
- Introspection/mutation: `get_state`, `set_state`, `run_method`
- Input simulation: `input_press`, `input_release`, `input_tap`, `input_clear`, `input_actions`, `input_sequence`
- Runtime ops: `performance`, `ping`, `quit`

`input_sequence` supports asynchronous multi-step scripts with `press`, `release`, `tap`, `hold`, `wait`, `screenshot`, `assert`, and `clear`.

### Runtime Scene Validation

`SceneValidator` (`game/SceneValidator.cs`) validates scenes in two phases:

1. Static `SceneState` scan for missing scripts/resources, invalid signal connection metadata, and relative `NodePath` usage hints.
2. Instantiation scan for missing meshes, textures, shaders, collision shapes, audio streams, and invalid `AnimationPlayer` track targets.

This complements headless lint by catching runtime-only failures.

## Toolchain and Verification

### Godot Launcher Wrapper

`tools/godot.sh` resolves Godot from:

1. `$GODOT4_MONO_EXE` environment variable
2. `godot` or `godot4` on PATH
3. `~/.local/bin/godot`
4. Flatpak (`org.godotengine.GodotSharp`)

### Project Lint

`tools/lint_project.gd` performs:

- UID consistency checks for `ext_resource` entries in `.tscn/.tres`
- Scene-level NodePath resolution warnings using `SceneState`
- Optional JSON output (`--json`)
- Modes: `--uids-only`, `--warnings-only`, `--fail-on-warn`

### Shader Lint

`tools/lint_shaders.gd` compiles each shader in a minimal render harness and verifies compilation by checking a synthetic uniform.

### Tests and Test Lint

- `dotnet test`: C# tests
- `./tools/test.sh`: gdUnit4 runtime tests with timeout handling and normalized exit codes
- `./tools/lint_tests.sh`: gdUnit conventions (`extends GdUnitTestSuite`, `test_` naming, assertion presence, loop sanity)

### Input Bootstrap

`tools/setup_input_actions_cli.gd` seeds and persists default actions:

`move_forward`, `move_backward`, `move_left`, `move_right`, `jump`, `crouch`, `sprint`, `swim_up`, `swim_down`

## CLI Workflow

```bash
# Restore/build/test
dotnet restore
dotnet build -warnaserror
dotnet test
./tools/test.sh
./tools/godot.sh --headless --script res://tools/setup_input_actions_cli.gd

# Static project lint
./tools/godot.sh --headless --script res://tools/lint_project.gd

# Run game + runtime verification loop
./tools/godot.sh
python tools/devtools.py ping
python tools/devtools.py input list
python tools/devtools.py input sequence test/sequences/example_template.json
python tools/devtools.py screenshot --filename "verification.png"
python tools/devtools.py validate-all
python tools/devtools.py performance
python tools/devtools.py input clear

# Asset viewer commands
python tools/devtools.py asset-list --type mesh
python tools/devtools.py asset-load res://actors/humpty_dumpty/humpty_dumpty_final.glb
python tools/devtools.py asset-screenshot --filename "asset_check.png"

# Import generated assets from pipeline
./tools/import-asset.sh humpty_dumpty
```

Screenshots are written to:
`~/.local/share/godot/app_userdata/GodotAssetViewer/screenshots/`

## Asset Generation Pipeline

The integrated pipeline generates game-ready 3D assets from text prompts:

1. **Concept art** (ComfyUI/Flux) → 2. **Background removal** (BiRefNet) → 3. **3D generation** (Trellis2) → 4. **PBR maps** (CHORD) → 5. **Post-processing** (Blender: decimation, rigging, LODs, collision)

Pipeline scripts are in `pipeline/`. Generated assets land in `~/assets/final_glb/` and can be imported into the Godot project via `./tools/import-asset.sh <asset_name>`.

Agent configurations for the pipeline are in `.github/agents/`:
- `asset-orchestrator` — Coordinates the generate-validate-remediate loop
- `game-asset-agent` — Runs the full generation pipeline
- `asset-validator` — Validates asset quality and game-readiness
- `modify-game-asset` — Modifies existing GLB files

## Asset Viewer

The built-in asset viewer (`ui/asset_viewer/AssetViewer.tscn`) provides:
- **Visual preview** of all project assets (meshes, textures, audio, scenes)
- **Orbit camera** for 3D asset inspection
- **Search and filter** by name or type
- **DevTools commands** for AI/CLI access (`asset_viewer_list`, `asset_viewer_load`, etc.)
- **Pipeline import** — pull generated assets directly into the project

## Based On

Originally forked from [cleak/tea-leaves](https://github.com/cleak/tea-leaves), the reusable Godot build-and-validate infrastructure.

## License

MIT. See `LICENSE`.
