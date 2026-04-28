# AGENTS.md

Operational instructions for AI coding agents working in this repository.

## Mission

Ship correct Godot features quickly with automatic verification. Do not wait for the user to ask for tests, lint, UID fixes, or runtime screenshots.

## Project Profile

- Godot 4.6+ Mono. C# for gameplay, GDScript for editor tooling only.
- Jolt physics, Forward Plus renderer, Linux (Vulkan).
- For conventions and patterns, see `.github/copilot-instructions.md`.
- For 3D asset pipeline details, use the `asset-pipeline` skill.
- For runtime verification details, use the `devtools-runtime` skill.

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

## Test Creation Policy

### Required

- New feature: add tests that cover expected behavior.
- Bug fix: add a failing test first (or tighten an existing test), then fix, then rerun.
- Refactor with behavior risk: add characterization/regression coverage.
- Scene/interaction changes: add or update automated coverage, then verify at runtime.

### Minimum Test Delta Rule

- For behavior changes and bug fixes, at least one test must be added or strengthened.
- "Strengthened" means tighter assertions, broader coverage, or a new edge case.
- Node-derived / runtime-dependent tests must use `./tools/test.sh`; reserve `dotnet test` for pure C# logic.

### Allowed Exceptions

If a test cannot be added, explain why using one of:
- `external_tooling_blocked`
- `runtime_dependency_missing`
- `legacy_test_harness_gap`

## Global Verification Gate (Mandatory for Non-Docs Changes)

```bash
dotnet build -warnaserror
dotnet test
./tools/test.sh
./tools/godot.sh --headless --script res://tools/lint_project.gd
```

Do not mark the task complete until this gate passes, or blockers are explicitly documented.

## Required Automatic Checks by Change Type

Run every row that applies. Rows are additive to the Global Verification Gate.

| Changed area | Required commands |
|---|---|
| `*.cs`, `*.csproj`, `*.sln` | `dotnet restore` (when needed), then Global Verification Gate |
| `*.tscn`, `*.tres`, `*.res`, `*.uid`, `project.godot` | Global Verification Gate; targeted scene lint with `-- --scene res://...` during iteration |
| `*.gdshader` | Global Verification Gate + `./tools/godot.sh --headless --script res://tools/lint_shaders.gd` |
| `*.gd` | `gdlint <file>` + `./tools/godot.sh --headless --check-only --script res://path/to/file.gd`; if test files changed, `./tools/lint_tests.sh`; then Global Verification Gate |
| Input/tooling changes | Re-run `./tools/godot.sh --headless --script res://tools/setup_input_actions_cli.gd`, then Global Verification Gate |
| Gameplay behavior | Global Verification Gate + runtime verification (see below) |

## UID/GUID Integrity Policy

1. After hand-editing scenes/resources or adding scripts/shaders, run: `./tools/godot.sh --headless --script res://tools/lint_project.gd`
2. If lint rewrites UIDs, update any stale `uid://...` references immediately.
3. Re-run lint until clean. Always include generated `*.uid` files in the change set.

## Runtime Verification (Gameplay Changes)

For any gameplay-visible change, run this sequence:

```bash
python tools/devtools.py ping
python tools/devtools.py input tap <relevant_action>
python tools/devtools.py screenshot --filename "<feature>_<state>.png"
python tools/devtools.py validate-all
python tools/devtools.py performance
python tools/devtools.py input clear
```

Ensure the game is running first with `./tools/godot.sh`. If DevTools is unreachable, continue all non-runtime checks and report the blocker explicitly. Screenshots go to `~/.local/share/godot/app_userdata/GodotAssetViewer/screenshots/`.

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

# GDScript lint and test lint
gdlint path/to/file.gd
./tools/godot.sh --headless --check-only --script res://path/to/file.gd
./tools/lint_tests.sh

# Input setup
./tools/godot.sh --headless --script res://tools/setup_input_actions_cli.gd
```

## Failure Handling Rules

- `tools/test.sh` exit codes: `0=pass`, `1=test failures`, `124=timeout`.
- If `./tools/test.sh` exits `124` (timeout), rerun once with `--timeout 120`.
- If `./tools/test.sh` reports missing `GdUnitCmdTool.gd`, verify files exist under `addons/gdUnit4/bin/` and report as blocker if missing.
- If `dotnet restore` has already succeeded in-session and project files are unchanged, it may be skipped.
- If `gdlint` is unavailable, run Godot semantic check-only for each changed `.gd` file.
- If a required command is unavailable, continue remaining checks and report exactly which command could not run.

## First-Time or Fresh Environment Bootstrap

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
- In final response, include: tests created/updated, commands run, pass/fail result summary, blockers and residual risk, runtime screenshot filename/path for gameplay changes.

## Definition of Done

All items must be true:

1. Applicable tests were created/updated.
2. Applicable test suites were run.
3. Global Verification Gate passed for non-doc changes.
4. Build/lint checks for changed file types passed.
5. UID/GUID validation was run and any rewritten references were fixed.
6. Gameplay changes had runtime validation with simulated input and screenshot attempt.
7. Final report includes concrete command outcomes.
