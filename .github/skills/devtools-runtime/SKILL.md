---
name: devtools-runtime
description: DevTools runtime verification for the Godot AssetViewer. Use this skill when performing runtime validation, capturing screenshots, simulating input, checking performance, or interacting with the running Godot game via DevTools.
allowed-tools: shell
---

# DevTools Runtime Verification

## Protocol

DevTools uses a file-based protocol under `user://` (typically `~/.local/share/godot/app_userdata/GodotAssetViewer/`):

| File | Purpose |
|------|---------|
| `devtools_commands.json` | Command inbox (write commands here) |
| `devtools_results.json` | Result outbox (read responses here) |

Supported commands: `screenshot`, `validate`, `scene-tree`, `input` (tap/clear simulation), `performance`, `get-state`, `set-state`.

## Runtime Verification Workflow

For any gameplay-visible change, run this sequence:

```bash
# 1. Ensure game is running
./tools/godot.sh    # if not already running

# 2. Verify DevTools
python tools/devtools.py ping

# 3. Simulate relevant actions
python tools/devtools.py input tap jump
python tools/devtools.py input sequence test/sequences/example_template.json

# 4. Capture screenshots
python tools/devtools.py screenshot --filename "<feature>_<state>.png"

# 5. Runtime validation
python tools/devtools.py validate-all
python tools/devtools.py performance

# 6. Clear inputs
python tools/devtools.py input clear
```

If DevTools is unreachable, continue all non-runtime checks and report the blocker explicitly.

## Screenshot Path

Default: `~/.local/share/godot/app_userdata/GodotAssetViewer/screenshots/`

## Asset Viewer Commands

```bash
python tools/devtools.py asset-list --type texture
python tools/devtools.py asset-load res://path/to/asset.glb
python tools/devtools.py asset-screenshot --filename check.png
```

## Full Command Reference

```bash
python tools/devtools.py ping
python tools/devtools.py input list
python tools/devtools.py input tap <action>
python tools/devtools.py input sequence <json_file>
python tools/devtools.py input clear
python tools/devtools.py screenshot --filename "name.png"
python tools/devtools.py validate-all
python tools/devtools.py performance
python tools/devtools.py quit
```
