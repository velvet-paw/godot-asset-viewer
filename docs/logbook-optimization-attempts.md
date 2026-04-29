# Optimization Logbook — Trellis2 Asset Pipeline

This document records every optimization technique we attempted on Trellis2-generated 3D assets, what happened, and what we learned. The goal was to reduce file sizes from ~24 MB (source) to something suitable for desktop (~5 MB) and web (~2 MB).

**Final conclusion:** None of the post-processing optimizations produced acceptable visual quality. The source-quality output (150K verts, 2048px PNG, MR stripped) is the shipping asset. File size optimization requires upstream changes to Trellis2's texture resolution or a fundamentally different approach to UV mapping.

---

## What Works (The Golden Path)

These are the techniques that survived and are now part of the production pipeline:

| Technique | Where | Effect |
|-----------|-------|--------|
| `remesh_project=0.9` | Trellis2 ExportGLB node | Manifold topology, shared vertices, no gaps |
| `remesh_band=2.0` | Trellis2 ExportGLB node | Smoother dual-contouring remesh |
| Step 4b MR strip in Blender | `stage6-blender.sh` | Removes metallic/roughness texture before export |
| `doubleSided=true` | Set in Step 4b | Fills micro-gaps at extreme zoom, zero cost |
| 150K vertex target | Stage 6 decimation | Preserves UV fidelity of baked textures |

---

## Experiments That Failed

### 1. gltf-transform simplify (mesh decimation)

**Commit:** `203e3d1` (added), `3fdfac6` (removed)

**What we tried:** Use `@gltf-transform/cli simplify` to reduce vertex count after Stage 6 export.

**What happened:** Completely destroyed vertex normals on Trellis2 meshes. Produced shiny, faceted surfaces that looked like crumpled foil. The simplification algorithm doesn't preserve the per-triangle UV layout that Trellis2 uses.

**Lesson:** All mesh decimation MUST happen in Blender (collapse decimation) where normals are properly recalculated. gltf-transform simplify is incompatible with Trellis2 mesh topology.

---

### 2. gltf-transform quantize (vertex compression)

**Commit:** `203e3d1` (added), `e5c6f7a` (removed)

**What we tried:** Quantize vertex positions and normals to reduce GLB file size.

**What happened:** Produced completely blank renders in Godot 4.6. The quantized vertex data was not correctly interpreted by Godot's glTF importer.

**Lesson:** Godot 4.6's glTF importer does not support quantized vertex attributes. This is a Godot limitation, not a gltf-transform bug.

---

### 3. Texture resize to 1024px / 512px (PNG)

**Commit:** `203e3d1` (added as part of optimize-for-web.sh)

**What we tried:** Resize 2048×2048 base color textures down to 1024px (desktop) or 512px (web) using `gltf-transform resize`.

**What happened:** Noticeable quality loss on detailed areas. Trellis2 bakes one texture per material using per-triangle UV islands — every triangle uses its own UV space. Resizing means each triangle gets fewer texels, and since triangles are small at 150K verts, 512px makes them visibly blurry.

**Lesson:** Texture resize hits a wall with Trellis2's UV layout. Each triangle is allocated roughly (2048²)/(face_count) texels. At 150K faces, that's ~28 texels per face at 2048px. Dropping to 512px gives ~1.7 texels per face — not enough for visual fidelity.

---

### 4. JPEG texture compression in GLB

**Commit:** `90ce39f` (added)

**What we tried:** Convert PNG textures to JPEG (quality 80-85) embedded in the GLB using a custom `png-to-jpeg.mjs` script with gltf-transform.

**What happened:** File size dropped significantly (24 MB → 9 MB at q80), but introduced visible JPEG artifacts — blocking, color banding in smooth gradients, and loss of edge sharpness. On the boar's face specifically, the compression artifacts were noticeable.

**Lesson:** JPEG compression technically works in Godot 4.6, but the quality trade-off is poor for Trellis2's per-triangle UV layout. The texture data needs to be pixel-perfect because each triangle samples from a tiny UV island with hard boundaries.

---

### 5. Decimation to 30K vertices (desktop tier)

**Commit:** `90ce39f` (three-tier generation)

**What we tried:** Run Stage 6 with `TARGET_VERTS=30000` to create a lighter desktop variant.

**What happened:** At 30K verts, UV fidelity was significantly degraded. Texture sampling pulled from neighboring UV islands, causing:
- Light-colored pixels bleeding through dark areas (belly, legs)
- Loss of fine detail in face/ear regions
- Visible seam artifacts where UV islands meet

With `remesh_project=0.9`, the mesh topology is better and decimation is cleaner — but the UV islands still can't survive a 5× reduction (150K → 30K). The geometry is fine but the texture mapping breaks.

**Lesson:** Trellis2's per-triangle UV layout creates a hard floor for vertex count. Below ~50K vertices, UV averaging across island boundaries causes visible texture bleed. The only way to ship at 30K would be to re-UV and re-texture the mesh (a completely different pipeline).

---

### 6. Decimation to 15K vertices (web tier)

**Commit:** `90ce39f` (three-tier generation)

**What we tried:** Run Stage 6 with `TARGET_VERTS=15000` and `SKIP_RIGGING=1` for a web variant.

**What happened:** All the issues from 30K but much worse. The mesh was geometrically acceptable but texturally destroyed. Large areas showed wrong colors, bleed artifacts covered most surfaces, and the overall appearance was of a low-quality asset rather than an optimized one.

**Lesson:** 15K is far below the viability floor for Trellis2 baked textures. Would require completely re-baking textures at a lower resolution onto the decimated mesh, which is a fundamentally different pipeline.

---

### 7. MetallicRoughness stripping via gltf-transform (post-processing)

**Commit:** `e5c6f7a` (added as strip-metalrough.mjs)

**What we tried:** Replace the MR texture with a 1×1 flat PNG using gltf-transform after Stage 6 export.

**What happened:** This worked but was fragile — the 1×1 replacement texture sometimes confused Godot's import pipeline. Occasionally resulted in slightly different material behavior compared to having no MR at all.

**Lesson:** Better to prevent the MR texture from ever being exported. We moved MR stripping into Blender (Step 4b) where we can disconnect the texture node entirely and set scalar values, producing a cleaner GLB that never had an MR texture in the first place.

---

### 8. Three-tier generation pipeline (generate-asset-tiers.sh)

**Commit:** `90ce39f`

**What we tried:** A wrapper script that runs Stage 6 three times with different `TARGET_VERTS` (150K, 30K, 15K) to produce source/desktop/web variants from the same Trellis2 output.

**What happened:** The script worked correctly — it successfully generated all three tiers. But the desktop (30K) and web (15K) tiers looked bad due to the UV fidelity issues described above. Having the script wasn't the problem; the underlying assumption that "less verts = smaller but acceptable" was wrong for Trellis2 meshes.

**Lesson:** The three-tier approach assumed that mesh decimation was a safe optimization — it isn't for Trellis2's UV layout. File size optimization for Trellis2 assets requires a different approach (smaller source textures, atlas packing, or re-UV).

---

### 9. WebP textures in GLB

**What we tried:** Convert textures to WebP format inside the GLB.

**What happened:** Godot 4.6 does not support WebP textures embedded in GLB files. The import silently produces blank materials.

**Lesson:** Godot 4.6's glTF importer only supports PNG and JPEG texture formats within GLB.

---

### 10. Draco/KTX2/meshopt compression

**What we tried:** Research phase only — did not implement.

**What happened:** None of these are supported by Godot 4.6's glTF importer. Draco would be the most useful (mesh compression without quality loss) but Godot simply can't decode it.

**Lesson:** Godot 4.6 has extremely limited glTF extension support. Only standard uncompressed GLB is reliable.

---

## Summary of Godot 4.6 GLB Limitations

| Feature | Status | Notes |
|---------|--------|-------|
| PNG textures | ✅ Works | Only reliable texture format |
| JPEG textures | ⚠️ Works but lossy | Quality loss visible on Trellis2 UV layout |
| WebP textures | ❌ Broken | Silent blank materials |
| Quantized vertices | ❌ Broken | Blank renders |
| gltf-transform simplify | ❌ Destroys normals | On Trellis2 meshes specifically |
| Draco compression | ❌ Not supported | Godot can't decode |
| KTX2/Basis textures | ❌ Not supported | Godot can't decode in GLB |
| meshopt compression | ❌ Not supported | Godot can't decode |
| doubleSided materials | ✅ Works | Zero cost, fills gaps |
| Multiple materials | ✅ Works | One texture per material |

---

## The Breakthrough: Low-Poly at Source

**The key insight:** Instead of generating at high vertex counts and decimating post-bake, set `decimation_target` in Trellis2's ExportGLB node to the desired vertex count. Trellis2 bakes textures ONTO the decimated mesh, so UV fidelity is preserved at any target.

| Approach | Verts | Size | Quality |
|----------|-------|------|---------|
| Post-bake decimation (150K → 15K) | 15K | 9.4 MB | ❌ Destroyed UVs, texture bleed |
| Low-poly at source (decimation_target=15K) | 12K | 2.7 MB | ✅ Clean textures, no artifacts |

**Why it works:** Trellis2's CuMesh remesher runs decimation BEFORE texture baking. The texture atlas is created for the target mesh, so each triangle gets proper UV coverage regardless of vertex count. Post-bake decimation fails because it tries to merge UV islands that were baked for a different topology.

**New defaults:** `decimation_target=25000`, `texture_size=1024`. This produces ~3 MB assets with good visual quality.

---

## Remaining Optimization Directions

1. **UV atlas repacking** — After generation, reproject textures onto a shared UV layout. Would enable JPEG compression without per-triangle artifacts.

2. **Godot .res format** — Import GLB once, save as `.res` with Godot's native compression. Larger on disk but faster to load at runtime.

3. **Even lower vertex targets** — `decimation_target=10000` or lower hasn't been tested. May still look acceptable for distant/small objects.

---

## Timeline

| Date | What | Result |
|------|------|--------|
| 2026-04-28 AM | Added optimize-for-web.sh with gltf-transform | Discovered quantize/simplify break Godot |
| 2026-04-28 AM | Removed simplify, made MR strip default | Fixed shiny artifacts from gltf-transform |
| 2026-04-28 AM | Added set-doublesided.mjs | Fixed polygon gaps on decimated meshes |
| 2026-04-28 PM | Enabled CuMesh remesh_project=0.9 | Fixed triangle soup at source (best single fix) |
| 2026-04-28 PM | Added three-tier generation + JPEG | File sizes good, visual quality bad at low verts |
| 2026-04-28 PM | Moved MR strip into Stage 6 Blender | Eliminated MR artifacts at source |
| 2026-04-28 PM | Generated source/desktop/web final | Source great, desktop/web still degraded |
| 2026-04-28 PM | **Decision: ship source quality only** | Quality > file size for now |
| 2026-04-28 PM | **Breakthrough: low-poly at source** | Set Trellis2 `decimation_target=15000` — textures baked onto 15K mesh. 2.7 MB, no artifacts. 90% smaller than 150K source. |
| 2026-04-28 PM | Updated default to `decimation_target=25000` | Best balance of quality and file size (~3 MB). Texture size 1024px. |
