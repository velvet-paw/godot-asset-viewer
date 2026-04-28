---
name: godot-asset-screenshot
description: Launch Godot's AssetViewer, load a GLB asset, and capture a screenshot. Use this skill whenever you need to visually verify a 3D asset in the Godot asset viewer, import a generated asset into Godot, or take a screenshot of a loaded model.
allowed-tools: shell
---

# Godot Asset Screenshot Skill

Use the `screenshot-asset.sh` script from this skill's base directory to import, load, and screenshot a 3D asset in the Godot AssetViewer.

## Usage

```bash
bash <skill_dir>/screenshot-asset.sh <asset_name> [glb_path]
```

- **asset_name** (required): The name of the asset (e.g., `wolf`). Used to find `~/assets/final_glb/{asset_name}_final.glb` and import into `actors/{asset_name}/`.
- **glb_path** (optional): Override the Godot resource path to load. Defaults to `res://actors/{asset_name}/{asset_name}_final.glb`.

The script will:
1. Import the asset from `~/assets/final_glb/` into the Godot project
2. Run a Godot headless import pass so the `.import` cache is up to date
3. Launch the AssetViewer scene (or reuse a running instance)
4. Load the specified GLB via DevTools
5. Take a screenshot and print the absolute path

## Output

The script prints the absolute path to the screenshot file on success. Use the `view` tool to inspect the resulting image.

## Environment

The script auto-detects `DOTNET_ROOT` and the Godot executable. It expects to be run with the working directory set to the `asset-viewer` project root at `/home/kaze/code/asset-viewer`.

## Quick Reference

| What | How |
|------|-----|
| Screenshot a freshly generated asset | `bash <skill_dir>/screenshot-asset.sh wolf` |
| Screenshot with custom resource path | `bash <skill_dir>/screenshot-asset.sh wolf res://actors/wolf/wolf_lod1.glb` |
| View the screenshot | Use the `view` tool on the path printed by the script |
| Quit Godot after you're done | `cd /home/kaze/code/asset-viewer && python3 tools/devtools.py quit` |

## Troubleshooting

- **"Failed to load .NET runtime"**: The script sets `DOTNET_ROOT` automatically. If it still fails, ensure `~/.dotnet/` contains a working .NET 8 SDK.
- **Godot crashes on import**: Large GLBs (>20MB) can cause headless import to crash. The script retries once. If it keeps failing, try reducing the mesh complexity first.
- **DevTools not responding**: The script waits up to 20 seconds for Godot to initialize. If it times out, check `cat /tmp/godot-asset-viewer.log` for errors.
- **Screenshot looks unchanged after re-import**: The script always kills any existing Godot instance and relaunches to ensure fresh imports.
