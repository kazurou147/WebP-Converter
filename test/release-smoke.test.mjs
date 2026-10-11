import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const releaseRoot = path.join(projectRoot, 'dist', 'WebPFolderConverter');
const bundledNode = path.join(releaseRoot, 'runtime', 'node.exe');
const bundledCli = path.join(releaseRoot, 'src', 'convert-webp.mjs');

test('PATHにNode.jsがなくても同梱ランタイムで変換できる', async (context) => {
  try {
    await stat(bundledNode);
    await stat(bundledCli);
  } catch {
    context.skip('自己完結リリース作成後に実行するテストです。');
    return;
  }

  const root = await mkdtemp(path.join(os.tmpdir(), 'WebP release smoke 日本語 & '));
  const imageFolder = path.join(root, 'images');
  const localAppData = path.join(root, 'Local App Data');
  const resultPath = path.join(root, 'result.json');
  const { mkdir } = await import('node:fs/promises');
  await mkdir(imageFolder);
  await sharp({
    create: { width: 4, height: 3, channels: 4, background: { r: 12, g: 34, b: 56, alpha: 0.5 } }
  }).png().toFile(path.join(imageFolder, '商品画像 #1.png'));

  const execution = await new Promise((resolve, reject) => {
    const child = spawn(
      bundledNode,
      [bundledCli, '--folder', imageFolder, '--json-result', resultPath],
      {
        windowsHide: true,
        env: { ...process.env, PATH: '', Path: '', LOCALAPPDATA: localAppData }
      }
    );
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', (code) => resolve({ code, stdout, stderr }));
  });

  assert.equal(execution.code, 0, execution.stderr);
  assert.match(execution.stdout, /成功: 1/);
  assert.equal((await stat(path.join(imageFolder, '商品画像 #1.webp'))).isFile(), true);
  const result = JSON.parse(await readFile(resultPath, 'utf8'));
  assert.equal(result.convertedCount, 1);
  assert.equal(typeof result.sizeSummary.inputBytes, 'number');
  assert.equal(typeof result.sizeSummary.outputBytes, 'number');
  assert.equal(typeof result.sizeSummary.reductionRate, 'number');
});
