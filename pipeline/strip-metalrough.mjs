#!/usr/bin/env node
// strip-metalrough.mjs — Replace metallicRoughness texture with flat values
//
// Replaces the metallicRoughnessTexture with a 1x1 pixel image encoding the
// desired metallic/roughness values. This avoids shiny artifacts from UV
// distortion while keeping the texture slot valid (prevents Godot crashes).
//
// Usage: node pipeline/strip-metalrough.mjs <input.glb> <output.glb> [--metallic 0.0] [--roughness 0.9]
//
// Requires: @gltf-transform/core (comes with @gltf-transform/cli)

import { NodeIO, Texture } from '@gltf-transform/core';

const args = process.argv.slice(2);
if (args.length < 2 || args.includes('--help')) {
    console.log('Usage: node pipeline/strip-metalrough.mjs <input.glb> <output.glb> [--metallic N] [--roughness N]');
    console.log('  Replaces metallicRoughnessTexture with flat scalar values.');
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

// Create a 1x1 PNG with the desired MR values
// glTF packs: Green=roughness, Blue=metallic (R and A unused, set to 255)
const r = 255;
const g = Math.round(roughness * 255);
const b = Math.round(metallic * 255);
const a = 255;

// Minimal 1x1 RGBA PNG
function createMinimalPng(r, g, b, a) {
    // PNG signature
    const signature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

    function crc32(buf) {
        let c = 0xffffffff;
        for (let i = 0; i < buf.length; i++) {
            c ^= buf[i];
            for (let j = 0; j < 8; j++) {
                c = (c >>> 1) ^ (c & 1 ? 0xedb88320 : 0);
            }
        }
        return (c ^ 0xffffffff) >>> 0;
    }

    function makeChunk(type, data) {
        const len = Buffer.alloc(4);
        len.writeUInt32BE(data.length);
        const typeAndData = Buffer.concat([Buffer.from(type), data]);
        const crc = Buffer.alloc(4);
        crc.writeUInt32BE(crc32(typeAndData));
        return Buffer.concat([len, typeAndData, crc]);
    }

    // IHDR: 1x1, 8-bit RGBA
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(1, 0);  // width
    ihdr.writeUInt32BE(1, 4);  // height
    ihdr[8] = 8;   // bit depth
    ihdr[9] = 6;   // color type: RGBA
    ihdr[10] = 0;  // compression
    ihdr[11] = 0;  // filter
    ihdr[12] = 0;  // interlace

    // IDAT: raw pixel data with zlib wrapper
    // Filter byte (0=None) + RGBA pixel
    const rawData = Buffer.from([0, r, g, b, a]);
    // Minimal zlib: header(2) + stored block(5+data) + adler32(4)
    const zlibHeader = Buffer.from([0x78, 0x01]); // zlib deflate, no compression
    const stored = Buffer.alloc(5);
    stored[0] = 0x01; // final block, stored
    stored.writeUInt16LE(rawData.length, 1);
    stored.writeUInt16LE(~rawData.length & 0xffff, 3);
    // Adler32
    let s1 = 1, s2 = 0;
    for (let i = 0; i < rawData.length; i++) {
        s1 = (s1 + rawData[i]) % 65521;
        s2 = (s2 + s1) % 65521;
    }
    const adler = Buffer.alloc(4);
    adler.writeUInt32BE((s2 << 16) | s1);
    const idat = Buffer.concat([zlibHeader, stored, rawData, adler]);

    const iend = Buffer.alloc(0);

    return Buffer.concat([
        signature,
        makeChunk('IHDR', ihdr),
        makeChunk('IDAT', idat),
        makeChunk('IEND', iend),
    ]);
}

const pngData = createMinimalPng(r, g, b, a);

let replaced = 0;
for (const material of root.listMaterials()) {
    const mrTexture = material.getMetallicRoughnessTexture();
    if (mrTexture) {
        // Replace the existing texture image with the 1x1 flat PNG
        mrTexture.setImage(new Uint8Array(pngData));
        mrTexture.setMimeType('image/png');
        replaced++;
    }
    material.setMetallicFactor(metallic);
    material.setRoughnessFactor(roughness);
}

await io.write(outputPath, document);
console.log(`Replaced ${replaced} metallicRoughness texture(s) with flat values. metallic=${metallic}, roughness=${roughness}.`);
