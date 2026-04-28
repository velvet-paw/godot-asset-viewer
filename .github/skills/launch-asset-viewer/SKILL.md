---
name: launch-asset-viewer
description: Launch the Godot AssetViewer in debug mode (monitor output) or detached mode (user interaction). Use this skill when you need to start the asset viewer, load assets, or verify the viewer is running.
allowed-tools: shell
---

# Launch Asset Viewer

## Prerequisites

- Working directory must be the project root: `/home/kaze/code/asset-viewer`
- .NET SDK 8.0+ installed at `~/.dotnet/` (auto-detected by `tools/godot.sh`)
- Godot 4.6+ Mono available (see `tools/godot.sh` resolution order)

## Debug Mode (Agent Monitors Output)

Use when you need to watch Godot output for errors, run DevTools commands, and capture screenshots.

```bash
# 1. Kill any existing instance
python3 tools/devtools.py quit 2>&1 || true
sleep 2

# 2. Launch in background, capture log
./tools/godot.sh res://ui/asset_viewer/AssetViewer.tscn > /tmp/godot-asset-viewer.log 2>&1 &
GODOT_PID=$!

# 3. Wait for DevTools to initialize (10-12 seconds typical)
sleep 10
python3 tools/devtools.py ping

# 4. Use DevTools to interact
python3 tools/devtools.py asset-load res://actors/wild_boar/wild_boar_desktop.glb
python3 tools/devtools.py screenshot --filename "check.png"
python3 tools/devtools.py asset-reload

# 5. Check log if something goes wrong
cat /tmp/godot-asset-viewer.log
```

**Important**: Launch step 2 with bash `mode="sync"` (it backgrounds with `&`). Use `mode="async"` only if you need to interact with Godot's stdin. The `&` keeps the shell free for DevTools commands.

## Detached Mode (User Interacts)

Use when the user wants to interact with the viewer directly (mouse orbit, click buttons, etc.). The viewer persists after the agent session ends.

```bash
# 1. Kill any existing instance
python3 tools/devtools.py quit 2>&1 || true
sleep 2

# 2. Launch detached (survives session shutdown)
setsid ./tools/godot.sh res://ui/asset_viewer/AssetViewer.tscn > /tmp/godot-asset-viewer.log 2>&1 &
disown

# 3. Confirm it started
sleep 10
python3 tools/devtools.py ping
```

Use bash with `mode="async"` and `detach: true` for step 2 to ensure the process persists independently.

## Loading Assets

```bash
# Load a GLB
python3 tools/devtools.py asset-load res://actors/wild_boar/wild_boar_desktop.glb

# Reload current asset (bypasses in-memory cache)
python3 tools/devtools.py asset-reload

# List available assets
python3 tools/devtools.py asset-list
python3 tools/devtools.py asset-list --type model
```

## Common Asset Paths

| Asset | Path |
|-------|------|
| Wild boar (desktop) | `res://actors/wild_boar/wild_boar_desktop.glb` |
| Wild boar (web) | `res://actors/wild_boar/wild_boar_web.glb` |
| Wild boar (full) | `res://actors/wild_boar/wild_boar_final.glb` |

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "Failed to load .NET runtime" | `tools/godot.sh` auto-detects `~/.dotnet/`. If still failing, `export DOTNET_ROOT=$HOME/.dotnet` before launch. |
| DevTools ping fails after 10s | Wait a few more seconds (up to 15s). Check `/tmp/godot-asset-viewer.log` for crash. |
| Viewer shows stale/cached model | Use `python3 tools/devtools.py asset-reload` or the ⟳ Reload button in the UI. |
| Segfault on launch | Check log. Common cause: corrupted `.godot/imported/` cache. Fix: `rm -rf .godot/imported/ && ./tools/godot.sh --headless --import` |
| Need fresh import after replacing GLB on disk | Kill viewer → `./tools/godot.sh --headless --import` → relaunch viewer |

## Shutting Down

```bash
python3 tools/devtools.py quit
```

For detached instances, use `quit` or find the PID:

```bash
pgrep -f "godot.*AssetViewer" | head -1 | xargs kill
```
