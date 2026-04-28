#!/usr/bin/env node
// set-doublesided.mjs — Set doubleSided=true on all materials in a GLB
//
// Trellis2 AI 3D generation outputs triangle-soup meshes where triangles
// share no vertices. After decimation, visible gaps appear between triangles.
// doubleSided=true renders back faces, visually filling these gaps at zero
// file-size cost.
//
// Usage: node pipeline/set-doublesided.mjs <input.glb> <output.glb>

import { NodeIO } from '@gltf-transform/core';

const args = process.argv.slice(2);
if (args.length < 2) {
    console.log('Usage: node pipeline/set-doublesided.mjs <input.glb> <output.glb>');
    process.exit(1);
}

const io = new NodeIO();
const document = await io.read(args[0]);

let count = 0;
for (const material of document.getRoot().listMaterials()) {
    material.setDoubleSided(true);
    count++;
}

await io.write(args[1], document);
console.log(`Set doubleSided=true on ${count} material(s).`);
