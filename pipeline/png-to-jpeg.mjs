/**
 * Convert PNG textures in a GLB to JPEG for smaller file sizes.
 * Usage: node pipeline/png-to-jpeg.mjs <input.glb> <output.glb> [quality=80]
 * 
 * Godot 4.6 supports JPEG textures in GLB natively.
 * Typical savings: 60-70% smaller texture data.
 */
import { NodeIO } from '@gltf-transform/core';
import sharp from 'sharp';
import { readFileSync, statSync } from 'fs';

const [input, output, quality] = process.argv.slice(2);
if (!input || !output) {
    console.error('Usage: node pipeline/png-to-jpeg.mjs <input.glb> <output.glb> [quality=80]');
    process.exit(1);
}

const jpegQuality = parseInt(quality || '80', 10);
const io = new NodeIO();
const doc = await io.read(input);
let converted = 0;

for (const texture of doc.getRoot().listTextures()) {
    const img = texture.getImage();
    if (!img || texture.getMimeType() === 'image/jpeg') continue;
    
    const jpegBuffer = await sharp(Buffer.from(img))
        .jpeg({ quality: jpegQuality, mozjpeg: true })
        .toBuffer();
    
    const savings = ((img.byteLength - jpegBuffer.byteLength) / img.byteLength * 100).toFixed(0);
    texture.setImage(new Uint8Array(jpegBuffer));
    texture.setMimeType('image/jpeg');
    converted++;
    console.error(`  Texture ${texture.getName() || converted}: PNG ${(img.byteLength/1024).toFixed(0)}KB → JPEG ${(jpegBuffer.byteLength/1024).toFixed(0)}KB (-${savings}%)`);
}

await io.write(output, doc);
const outSize = statSync(output).size;
console.log(`${(outSize / 1024 / 1024).toFixed(1)}M`);
