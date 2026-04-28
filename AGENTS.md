# AGENTS.md

Operational instructions for AI coding agents working in this repository.

## Mission

Ship correct Godot features quickly with automatic verification. Do not wait for the user to ask for tests, lint, UID fixes, or runtime screenshots.

## Project Profile

- Godot 4.6+ Mono.
- Gameplay code: C# only.
- GDScript: editor tooling and tiny glue scripts only.
- Physics: Jolt.
- Renderer: Forward Plus.
- Target platform: Linux (Vulkan).

## Hard Rules (Non-Negotiable)

1. Always run applicable tools automatically after edits.
2. Always create or update tests for behavior changes, bug fixes, and non-trivial refactors.
3. Always run those tests, plus broader suites required by changed file types.
4. On any non-documentation change, run the global verification gate before finalizing.
5. Always validate and repair UID/GUID issues after scene/resource/script/shader edits.
6. Always attempt runtime screenshot verification for gameplay-facing changes.
7. Never silently skip a required check. If blocked, state the blocker explicitly.

## Mandatory Autopilot Workflow

Follow this sequence on every coding task unless it is explicitly documentation-only.

1. Classify changed files and affected behavior.
2. Add/update tests first for behavior changes (red/green when fixing bugs).
3. Run fast targeted checks while iterating.
4. Run the global verification gate (non-doc changes) plus all required checks from the matrix below before finalizing.
5. For gameplay-impacting changes, run DevTools runtime validation + screenshot capture.
6. Report commands run and pass/fail outcomes in the final message.

## Test Creation Policy (Explicit)

### Required

- New feature: add tests that cover expected behavior.
- Bug fix: add a failing test first (or tighten an existing test), then fix, then rerun.
- Refactor with behavior risk: add characterization/regression coverage.
- Scene/interaction changes: add or update automated coverage, then verify at runtime with input simulation and screenshot.

### Allowed Exceptions

If a test cannot be added, agent must explain why in final output using one of:
- `external_tooling_blocked`
- `runtime_dependency_missing`
- `legacy_test_harness_gap`

If no exception applies, test creation is mandatory.

### Minimum Test Delta Rule

- For behavior changes and bug fixes, at least one test must be added or strengthened.
- "Strengthened" means tighter assertions, broader coverage, or a new edge case in an existing test.
- If neither is done, the final report must include a blocker code from Allowed Exceptions.

## Global Verification Gate (Mandatory for Non-Docs Changes)

Run all commands below for any code/scene/resource/tooling change:

```bash
dotnet build -warnaserror
dotnet test
./tools/test.sh
./tools/godot.sh --headless --script res://tools/lint_project.gd
```

Do not mark the task complete until this gate passes, or blockers are explicitly documented.

## Required Automatic Checks by Change Type

Run every row that applies.
Rows are additive to the Global Verification Gate; they do not replace it.

| Changed area | Required commands |
|---|---|
| `*.cs`, `*.csproj`, `*.sln` | `dotnet restore` (when needed), then Global Verification Gate |
| `*.tscn`, `*.tres`, `*.res`, `*.uid`, `project.godot` | Global Verification Gate; if only specific scenes changed, also run targeted scene lint with `-- --scene res://...` during iteration |
| `*.gdshader` | Global Verification Gate + `./tools/godot.sh --headless --script res://tools/lint_shaders.gd` |
| `*.gd` | `gdlint <each_changed_file.gd>` + semantic parse check `./tools/godot.sh --headless --check-only --script res://path/to/file.gd`; if test files changed, `./tools/lint_tests.sh`; then Global Verification Gate |
| Input/tooling changes (`tools/setup_input_actions_cli.gd`, input maps) | re-run setup script, then Global Verification Gate |
| Gameplay behavior (movement, camera, combat, interaction, UI flow) | Global Verification Gate + DevTools runtime loop: `ping`, relevant `input` simulation, `screenshot`, `validate-all`, `performance`, `input clear` |

## UID/GUID Integrity Policy (Mandatory)

Godot UID integrity is part of correctness.

1. After hand-editing scenes/resources or adding scripts/shaders, run:
   - `./tools/godot.sh --headless --script res://tools/lint_project.gd`
2. If lint rewrites UIDs, update any stale `uid://...` references immediately.
3. Re-run lint until clean.
4. Always include generated `*.uid` files in the change set.

## Runtime Verification and Screenshots (Mandatory for Gameplay Changes)

For any gameplay-visible change, do all of the following automatically:

1. Ensure game is running: `./tools/godot.sh` (if not already running).
2. Verify DevTools: `python tools/devtools.py ping`.
3. Simulate relevant actions using `python tools/devtools.py input ...` or a sequence file.
4. Capture at least one screenshot:
   - `python tools/devtools.py screenshot --filename "<feature>_<state>.png"`
5. Run runtime validation:
   - `python tools/devtools.py validate-all`
   - `python tools/devtools.py performance`
6. Clear inputs:
   - `python tools/devtools.py input clear`

If DevTools is unreachable, continue all non-runtime checks and report the runtime blocker explicitly.

Store/report screenshot artifact path (default Godot user data location):
- `~/.local/share/godot/app_userdata/GodotAssetViewer/screenshots/`

## Build/Test/Lint Command Set

```bash
# C# restore/build/tests
dotnet restore
dotnet build -warnaserror
dotnet test

# Godot runtime test suite (gdUnit4)
./tools/test.sh
./tools/test.sh --test "res://test/unit/"
./tools/test.sh --timeout 120

# Project and shader lint
./tools/godot.sh --headless --script res://tools/lint_project.gd
./tools/godot.sh --headless --script res://tools/lint_project.gd -- --scene res://path/to/scene.tscn
./tools/godot.sh --headless --script res://tools/lint_shaders.gd
./tools/godot.sh --headless --script res://tools/lint_shaders.gd -- res://path/to/shader.gdshader

# GDScript lint and test lint
gdlint path/to/file.gd
./tools/godot.sh --headless --check-only --script res://path/to/file.gd
./tools/lint_tests.sh

# Input setup
./tools/godot.sh --headless --script res://tools/setup_input_actions_cli.gd

# DevTools runtime checks
python tools/devtools.py ping
python tools/devtools.py input list
python tools/devtools.py input tap jump
python tools/devtools.py input sequence test/sequences/example_template.json
python tools/devtools.py screenshot --filename "verification.png"
python tools/devtools.py validate-all
python tools/devtools.py performance
python tools/devtools.py input clear
python tools/devtools.py quit
```

## Failure Handling Rules

- `tools/test.sh` exit codes: `0=pass`, `1=test failures`, `124=timeout`.
- If `./tools/test.sh` exits `124` (timeout), rerun once with `--timeout 120`.
- If `./tools/test.sh` reports missing `GdUnitCmdTool.gd`, verify files exist under `addons/gdUnit4/bin/` and report as blocker if missing.
- If `dotnet restore` has already succeeded in-session and project files are unchanged, it may be skipped; otherwise run it.
- If `gdlint` is unavailable, still run Godot semantic check-only for each changed `.gd` file via `./tools/godot.sh --headless --check-only --script res://path/to/file.gd`.
- If a required command is unavailable (`gdlint`, Python, Godot), continue remaining checks and report exactly which command could not run and why.

## Engineering Conventions

### Language and Architecture

- Keep gameplay logic in C#.
- Do not implement gameplay systems in GDScript unless explicitly unavoidable.
- Prefer composition over inheritance for nodes.
- Use typed EventBus patterns for cross-system decoupling.
- Use data-driven config via `[GlobalClass]` resources.
- Keep state transitions deterministic and explicit.

### C# Safety and Godot-Specific Patterns

- Put physics logic in `_PhysicsProcess(double delta)`.
- Validate required setup in `_Ready()`.
- Fail fast on misconfiguration (`GD.PushError()` or assertions).
- For non-null fields initialized in `_Ready()`, use `= null!` to satisfy nullable warnings.
- Add node to tree before setting `GlobalPosition`.

### Hand-Written Scene Rules

- For hand-written `.tscn` files, do not rely on typed node export deserialization from `NodePath`.
- Use `[Export] NodePath ...Path` fields, then resolve with `GetNodeOrNull<T>()` in `_Ready()`.
- Prefer editor-generated scenes when possible; hand-write only when necessary.

## Testing Strategy Details

### Which runner to use

- `dotnet test`: pure C# logic tests.
- `./tools/test.sh`: Godot runtime, GDScript tests, and engine-aware integration tests.

### Node-derived class caveat

Classes inheriting from Godot `Node` typically throw runtime-level failures (often `AccessViolationException`) when instantiated under plain `dotnet test` without Godot runtime support. Keep core logic testable in pure C# helpers when possible.

### Anti-patterns to avoid in async/runtime tests

- Waiting for `"ready"` after `AddChild` with `ToSignal` (can hang).
- Infinite loops without deterministic exit.
- Async tests requiring runtime but missing runtime requirement markers.

## Asset Generation Pipeline

Specialized agent configurations live in `.github/agents/` and handle 3D asset generation:

- **asset-orchestrator** (`asset-orchestrator.agent.md`): Coordinates the generate → validate → remediate loop, ensuring assets meet quality gates before delivery. Includes creature-specific escalation strategies and color-variation requirements.
- **game-asset-agent** (`game-asset-agent.agent.md`): Generates game-ready 3D assets end-to-end through the pipeline: Flux (concept art) → BiRefNet (background removal) → Trellis2 (textured 3D mesh) → Blender (post-processing). Trellis2 baked textures are preserved by default; CHORD PBR is only applied when textures are absent or explicitly stripped via `FORCE_PBR=1`.
- **asset-validator** (`asset-validator.agent.md`): Validates assets for quality, correctness, and game-readiness (geometry, UVs, materials, file size). Includes creature-specific quality checks for color variation and UV fidelity.
- **modify-game-asset** (`modify-game-asset.agent.md`): Modifies existing GLB files — geometry removal, recoloring, mesh cleanup — via Blender.

Pipeline scripts live in `pipeline/` (stage scripts: concept → mask → 3D → Blender post-process).
Generated assets are delivered to `~/assets/final_glb/`.

## First-Time or Fresh Environment Bootstrap

Run once when environment is new or dependencies changed:

```bash
dotnet restore
dotnet build -warnaserror
./tools/godot.sh --headless --script res://tools/setup_input_actions_cli.gd
dotnet test
./tools/test.sh
```

## Execution/Reporting Requirements

- Prefer targeted checks while iterating; run full required checks before final output.
- For headless Godot lint commands, prefer short timeouts (target 20s when practical).
- Use absolute paths for file operations when a path must be provided explicitly.
- In final response, include:
  - tests created/updated,
  - commands run,
  - pass/fail result summary,
  - blockers and residual risk,
  - runtime screenshot filename/path for gameplay changes.

## Definition of Done

All items must be true:

1. Applicable tests were created/updated.
2. Applicable test suites were run.
3. Global Verification Gate passed for non-doc changes.
4. Build/lint checks for changed file types passed.
5. UID/GUID validation was run and any rewritten references were fixed.
6. Gameplay changes had runtime validation with simulated input and screenshot attempt.
7. Final report includes concrete command outcomes.
