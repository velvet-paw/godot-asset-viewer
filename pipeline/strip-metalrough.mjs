#!/usr/bin/env node
// strip-metalrough.mjs — Remove metallicRoughness texture from GLB
//
// Strips the metallicRoughnessTexture and sets flat scalar values instead.
// This prevents shiny artifacts caused by UV distortion during mesh decimation.
//
// Usage: node pipeline/strip-metalrough.mjs <input.glb> <output.glb> [--metallic 0.0] [--roughness 0.9]
//
// Requires: @gltf-transform/core (comes with @gltf-transform/cli)

import { NodeIO } from '@gltf-transform/core';

const args = process.argv.slice(2);
if (args.length < 2 || args.includes('--help')) {
    console.log('Usage: node pipeline/strip-metalrough.mjs <input.glb> <output.glb> [--metallic N] [--roughness N]');
    console.log('  Strips metallicRoughnessTexture, sets flat scalar values.');
    console.log('  --metallic   Metallic factor (default: 0.0)');
    console.log('  --roughness  Roughness factor (default: 0.9)');
    process.exit(args.includes('--help') ? 0 : 1);
}

const inputPath = args[0];
const outputPath = args[1];

let metallic = 0.0;
let roughness = 0.9;

for (let i = 2; i < args.length; i++) {
    if (args[i] === '--metallic' && args[i + 1]) metallic = parseFloat(args[++i]);
    if (args[i] === '--roughness' && args[i + 1]) roughness = parseFloat(args[++i]);
}

const io = new NodeIO();
const document = await io.read(inputPath);
const root = document.getRoot();

let stripped = 0;
for (const material of root.listMaterials()) {
    const mrTexture = material.getMetallicRoughnessTexture();
    if (mrTexture) {
        material.setMetallicRoughnessTexture(null);
        stripped++;
    }
    material.setMetallicFactor(metallic);
    material.setRoughnessFactor(roughness);
}

// Prune orphaned textures/images
const usedTextures = new Set();
for (const mat of root.listMaterials()) {
    for (const tex of [
        mat.getBaseColorTexture(),
        mat.getMetallicRoughnessTexture(),
        mat.getNormalTexture(),
        mat.getOcclusionTexture(),
        mat.getEmissiveTexture(),
    ]) {
        if (tex) usedTextures.add(tex);
    }
}

for (const texture of root.listTextures()) {
    if (!usedTextures.has(texture)) {
        texture.dispose();
    }
}

await io.write(outputPath, document);
console.log(`Stripped ${stripped} metallicRoughness texture(s). Set metallic=${metallic}, roughness=${roughness}.`);
