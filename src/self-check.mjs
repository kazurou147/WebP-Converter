import assert from 'node:assert/strict';
import sharp from 'sharp';

const input = {
  create: {
    width: 1,
    height: 1,
    channels: 4,
    background: { r: 0, g: 128, b: 255, alpha: 0.5 }
  }
};
const output = await sharp(input).webp({ quality: 80, alphaQuality: 100, effort: 4, exact: true }).toBuffer();
const metadata = await sharp(output).metadata();
assert.equal(metadata.format, 'webp');
assert.equal(metadata.width, 1);
assert.equal(metadata.height, 1);
assert.equal(metadata.hasAlpha, true);
console.log(`Sharp自己診断成功 (Node.js ${process.version}, Sharp ${sharp.versions.sharp}, libvips ${sharp.versions.vips})`);
