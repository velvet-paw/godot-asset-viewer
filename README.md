# Tea Leaves

Tea Leaves is the engineering substrate for dog-designed Godot games: non-semantic keyboard streams are interpreted as design input, and this repo provides the runtime tooling and verification rails that turn those streams into working game builds.

[Quasar Saz](https://github.com/cleak/quasar-saz) is one finished game and `tea-leaves` is the reusable technical core behind that workflow.

## Generation Loop

1. Dog keyboard input is treated as intentional design signal, not noise.
2. An agent translates that signal into concrete Godot changes (code, scenes, resources, controls).
3. This repository's automation stack validates the result (build/test/lint/runtime checks) before changes are accepted.

## Technical Snapshot

- Engine: Godot 4.6 Mono
- Gameplay language: C# (`net8.0`)
- Tooling language: GDScript + PowerShell + Python
- Physics: Jolt
- Renderer: Forward Plus (D3D12 on Windows)
- Test stack: `dotnet test` + gdUnit4 via `pwsh ./tools/test.ps1`

## Runtime Architecture

### Boot Autoloads

`project.godot` wires two autoloads:

- `WindowSetup` (`game/WindowSetup.cs`): forces startup window placement on monitor index `2`, centers using `ScreenGetUsableRect`, and sets always-on-top. Change this as desired - it was a kludge to make good recordings.
- `DevTools` (`game/DevTools.cs`): runtime command server used by local automation.

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

`tools/godot.ps1` resolves Godot from:

1. `GODOT4_MONO_EXE`
2. `C:\Projects\Godot\Godot_v4.6-stable_mono_win64\...`

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
- `pwsh ./tools/test.ps1`: gdUnit4 runtime tests with timeout handling and normalized exit codes
- `pwsh ./tools/lint_tests.ps1`: gdUnit conventions (`extends GdUnitTestSuite`, `test_` naming, assertion presence, loop sanity)

### Input Bootstrap

`tools/setup_input_actions_cli.gd` seeds and persists default actions:

`move_forward`, `move_backward`, `move_left`, `move_right`, `jump`, `crouch`, `sprint`, `swim_up`, `swim_down`

## CLI Workflow

```powershell
# Restore/build/test
dotnet restore
dotnet build -warnaserror
dotnet test
pwsh ./tools/test.ps1
pwsh ./tools/godot.ps1 --headless --script res://tools/setup_input_actions_cli.gd

# Static project lint
pwsh ./tools/godot.ps1 --headless --script res://tools/lint_project.gd

# Run game + runtime verification loop
pwsh ./tools/godot.ps1
python tools/devtools.py ping
python tools/devtools.py input list
python tools/devtools.py input sequence test/sequences/example_template.json
python tools/devtools.py screenshot --filename "verification.png"
python tools/devtools.py validate-all
python tools/devtools.py performance
python tools/devtools.py input clear
```

Screenshots are written to:
`%APPDATA%/Godot/app_userdata/TeaLeaves/screenshots/`

## Repository Status

This repo currently ships the platform and verification infrastructure, not a full game content stack yet:

- `actors/`, `levels/`, `scripts/`, `ui/`, `data/`, `util/` are scaffolded directories.
- `test/unit/test_example.gd` and `test/sequences/example_template.json` are starter references.

In short: `tea-leaves` is the repeatable build-and-validate loop that dog-generated game ideas plug into.

## Related Projects

- **[Quasar Saz](https://github.com/cleak/quasar-saz)** - The finished game built on this foundation, designed by a dog and developed by Claude Code ([watch the video](https://youtu.be/8BbPlPou3Bg))
- **[DogKeyboard](https://github.com/cleak/DogKeyboard)** - All the routing and miscellaneous tasks for reading input from Momo, dispensing treats, and playing chimes for her

## License

MIT. See `LICENSE`.
