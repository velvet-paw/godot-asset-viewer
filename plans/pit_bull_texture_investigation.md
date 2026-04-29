# Pit Bull Texture Investigation — Post-Mortem

**Date:** 2026-04-29  
**Asset:** `actors/pit_bull/pit_bull_final.glb`  
**Resolution:** Restored original model. Root cause was shadow acne — not a texture issue.

---

## Timeline of Issues and Fixes

### Issue 1: Blotchy Dark Coating

**Symptom:** Dark brown patches appearing/disappearing during animation, visible at rest. Described as "someone splashed dark brown paint on our light brown dog" and "like two layers of texture are applied."

**Investigation attempts:**
- Split normals at UV seams — no effect
- Shadow geometry detection (Icosphere shells from Blender import) — removed, no effect on blotching
- Texture dilation via Blender MCP `img.pixels[:]` — Blender glTF exporter ignores in-memory pixel changes, no effect
- Texture dilation via pygltflib binary replacement — appeared to work but extracted texture was unchanged
- Color correction (brightness floor) — made textures muddy/hazy, splotches still present

**Root cause:** Godot's default `DirectionalLight3D` shadow settings (`ShadowBias=0.1`, `ShadowNormalBias=1.0`) are too low for Trellis2 meshes. These have complex topology with thousands of tiny UV islands, causing severe self-shadow artifacts (shadow acne) that look like dark paint splotches.

**Confirmed by:** Disabling shadows entirely on DirectionalLight3D → splotches disappeared immediately.

**Fix applied (commit `7c404ef`):**
```csharp
// ui/asset_viewer/AssetViewer.cs
ShadowBias = 0.15f,
ShadowNormalBias = 3.0f
```

**Also cleaned (commit `f748941`):**
- Cross-seam normal averaging in `stage6b-geometry.sh` (reduces faceting at UV seam boundaries)
- Icosphere shadow shell detection in `gate6_final.py` (catches Blender import artifacts)

---

### Issue 2: "Shiny Metallic Blur" on Regenerated Model

**Triggered by:** Full end-to-end regeneration requested to verify clean baseline after shadow fix.

**Symptom:** Grey/silver metallic shimmer on coat surface, especially around shoulders.

**Root cause (pipeline analysis):**
- `decimation_target=25000` in the Trellis2 workflow produced **344,000 verts** (13.8× over target)
- Trellis2's internal decimation has a topology floor — with `remesh_project=0.9`, some mesh shapes cannot be simplified to the target
- Stage 6 post-bake decimation from 344K → 54K **destroyed UV fidelity**, creating 4,529 UV islands
- Grey/silver garbage pixels between UV islands (Trellis2's automatic UV padding with wrong colors) appeared as metallic shimmer under lighting

**Pipeline improvements made (commit `0607e91`) — kept:**
- `stage6c-materials.sh`: Rewrote texture padding from alpha-based → UV-mask-based detection. Default padding 16px → 64px.
- `gate6_final.py`: Added `check_uv_fragmentation()` (island count), `check_texture_desaturation()` (grey garbage ratio), vectorized UV area calculation
- `stage3-3d.sh`: Added post-generation vertex count check vs `decimation_target` (warns if >3× target)

**Key insight:** This issue didn't require fixing the original model. The original model before regeneration was not affected — the metallic blur was introduced by the regeneration itself (decimation failure). **The shadow bias was the only real problem with the original model.**

---

### Issue 3: 15K Workflow Producing Unit Cubes

**Triggered by:** Attempting to force Trellis2 below its decimation floor by using a 15K target.

**Symptom:** Output GLB was a perfect 1.00×1.00×1.00 unit cube with the concept image projected onto faces.

**Root cause:** `decimation_target=15000` is below Trellis2's absolute minimum viable topology. When the target is too low, the mesh collapses to a degenerate box/cube shape. The concept image is then baked onto the cube's 6 faces.

**Confirmed by:** `trimesh` bounds: `[1.0, 1.0, 1.0]`, aspect ratio 1.00×1.00.

**Rule established: Never use `decimation_target` below 25000 for creatures. 25K is the safe minimum.**

**Deleted:** `comfyui/flows/trellis2-img2mesh-15k.json`

---

### Issue 4: All Subsequent Regenerations Were Cubes

**Symptom:** Multiple regeneration attempts, each producing box-shaped geometry despite different parameters.

**Root cause:** The `~/assets/raw_3d/pit_bull_00001_.glb` file was overwritten repeatedly by failed regenerations. The only reliable source for the good mesh was:
- `~/assets/final_glb/pit_bull_clean.glb` — original generation with normals smoothed and icospheres removed

**All variants produced during investigation (deleted):**
- `pit_bull_best.glb` (355K raw) — cube when rendered in Godot despite trimesh showing dog-shaped proportions
- `pit_bull_v3.glb`, `pit_bull_00001_.glb` — cubes
- `pit_bull_chord.glb`, `pit_bull_dilated.glb`, `pit_bull_padded.glb`, etc. — test artifacts from texture dilation experiments

---

## Resolution

Restored `actors/pit_bull/pit_bull_final.glb` from `pit_bull_clean.glb`:
- 24,127 verts (proper dog proportions: 0.40×0.59×0.80m, ratio 2.00)
- Original Trellis2 texture intact
- Cross-seam normals smoothed (reduces faceting)
- Icosphere shadow shells removed

Shadow acne eliminated by the bias fix in `AssetViewer.cs`. No texture changes required.

---

## Rules for Future Pit Bull / Creature Generation

1. **Try shadow bias before investigating textures.** Trellis2 mesh complexity causes self-shadow artifacts with default Godot settings. Check `ShadowBias=0.15` / `ShadowNormalBias=3.0` first.

2. **Never regenerate a model you're happy with** to "verify" it after a lighting fix. Apply the fix and verify in-place.

3. **`decimation_target=15000` is forbidden for creatures.** Produces degenerate cube output. 25K minimum.

4. **Trellis2 decimation target is a request, not a guarantee.** Some mesh topologies hit internal floors. High-detail subjects (pit bull) may produce 10–14× the target. Add margin when planning pipeline vert budgets.

5. **When Trellis2 produces too many verts:** Stage 6 post-bake decimation will fragment UVs. Gate 6 now catches this via `check_uv_fragmentation()` (fail at >2000 islands). Rerun Stage 3 is the correct response, not texture patching.

6. **The 25K workflow + stage6 pipeline is correct.** Do not modify the default workflow parameters unless the gate6 vertex check fails.
