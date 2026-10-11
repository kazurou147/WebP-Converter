import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, readFile, readdir, stat, utimes, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import {
  TEMP_PREFIX,
  WEBP_OPTIONS,
  buildOutputPath,
  calculateSizeSummary,
  cleanupStaleTempFiles,
  convertOne,
  formatSummary,
  isSupportedInput,
  parseArguments,
  planConversions,
  runConversion,
  runWorkerPool
} from '../src/converter.mjs';

async function makeTestRoot(name = 'WebP Converter Test') {
  const root = await mkdtemp(path.join(os.tmpdir(), `${name}-`));
  process.env.LOCALAPPDATA = path.join(root, 'Local App Data');
  return root;
}

async function makePng(filePath, { width = 8, height = 6, alpha = 1, noise = false } = {}) {
  if (noise) {
    const channels = 4;
    const buffer = Buffer.alloc(width * height * channels);
    for (let index = 0; index < buffer.length; index += 4) {
      buffer[index] = (index * 17) % 256;
      buffer[index + 1] = (index * 29) % 256;
      buffer[index + 2] = (index * 43) % 256;
      buffer[index + 3] = Math.round(alpha * 255);
    }
    await sharp(buffer, { raw: { width, height, channels } }).png().toFile(filePath);
    return;
  }
  await sharp({
    create: { width, height, channels: 4, background: { r: 20, g: 100, b: 200, alpha } }
  }).png().toFile(filePath);
}

async function makeJpeg(filePath, { width = 8, height = 6, orientation } = {}) {
  let image = sharp({
    create: { width, height, channels: 3, background: { r: 210, g: 120, b: 20 } }
  });
  if (orientation) image = image.withMetadata({ orientation });
  await image.jpeg().toFile(filePath);
}

async function sha256(filePath) {
  return createHash('sha256').update(await readFile(filePath)).digest('hex');
}

async function readMetadata(filePath) {
  const image = sharp(filePath);
  try {
    return await image.metadata();
  } finally {
    image.destroy();
  }
}

function fakeDirent(name, isFile = true) {
  return { name, isFile: () => isFile };
}

test('引数を解析し、相対パスを絶対パスへ変換する', () => {
  const parsed = parseArguments(['--folder', 'images', '--json-result', 'result.json']);
  assert.equal(parsed.folder, path.resolve('images'));
  assert.equal(parsed.jsonResult, path.resolve('result.json'));
  assert.throws(() => parseArguments([]), /--folder/);
  assert.throws(() => parseArguments(['--unknown']), /不明な引数/);
});

test('存在しないフォルダは終了コード1になりログと結果JSONを残す', async () => {
  const root = await makeTestRoot();
  const resultPath = path.join(root, 'fatal-result.json');
  const missingFolder = path.join(root, 'missing');
  const cliPath = path.resolve('src', 'convert-webp.mjs');
  const execution = await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [cliPath, '--folder', missingFolder, '--json-result', resultPath], {
      windowsHide: true,
      env: { ...process.env, LOCALAPPDATA: path.join(root, 'Local App Data') }
    });
    let stderr = '';
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', (code) => resolve({ code, stderr }));
  });
  assert.equal(execution.code, 1);
  assert.match(execution.stderr, /致命的エラー/);
  const result = JSON.parse(await readFile(resultPath, 'utf8'));
  assert.equal(result.exitCode, 1);
  assert.equal(result.fatalError.errorCode, 'FOLDER_NOT_FOUND');
  assert.equal((await stat(result.logPath)).isFile(), true);
});

test('PNG/JPG/JPEGの通常ファイルだけを大小文字を区別せず対象にする', () => {
  for (const name of ['a.png', 'a.PNG', 'a.jpg', 'a.JPG', 'a.jpeg', 'a.JPEG']) {
    assert.equal(isSupportedInput(fakeDirent(name)), true, name);
  }
  assert.equal(isSupportedInput(fakeDirent('a.webp')), false);
  assert.equal(isSupportedInput(fakeDirent('a.png', false)), false);
});

test('出力名はベース名を保って小文字.webpになる', () => {
  assert.equal(buildOutputPath(path.join('C:\\images', 'hero.pc.2x.PNG')), path.join('C:\\images', 'hero.pc.2x.webp'));
});

test('入力同士の競合は全件、既存WebPは変換前にスキップする', () => {
  const folder = path.resolve('fixtures');
  const plan = planConversions(folder, [
    fakeDirent('same.png'),
    fakeDirent('SAME.JPG'),
    fakeDirent('exists.jpeg'),
    fakeDirent('EXISTS.WEBP'),
    fakeDirent('ok.png')
  ]);
  assert.equal(plan.candidates.length, 4);
  assert.deepEqual(plan.skippedConflict.map((item) => item.inputName).sort(), ['SAME.JPG', 'same.png']);
  assert.equal(plan.skippedExisting[0].inputName, 'exists.jpeg');
  assert.equal(plan.jobs[0].inputName, 'ok.png');
});

test('空フォルダは終了コード0で正常終了する', async () => {
  const root = await makeTestRoot();
  const result = await runConversion(root);
  assert.equal(result.targetCount, 0);
  assert.equal(result.exitCode, 0);
  assert.deepEqual(result.sizeSummary, { inputBytes: 0, outputBytes: 0, reducedBytes: 0, reductionRate: null });
});

test('変換成功時に元画像を変更せず、容量集計と画質設定を適用する', async () => {
  const root = await makeTestRoot();
  const input = path.join(root, '画像.png');
  await makePng(input, { width: 32, height: 24, noise: true });
  const beforeHash = await sha256(input);
  const beforeMtime = (await stat(input)).mtimeMs;
  let capturedOptions;
  const sharpFactory = (...args) => {
    const instance = sharp(...args);
    const originalWebp = instance.webp.bind(instance);
    instance.webp = (options) => {
      capturedOptions = options;
      return originalWebp(options);
    };
    return instance;
  };
  const result = await runConversion(root, { sharpFactory });
  const output = path.join(root, '画像.webp');
  assert.equal(result.exitCode, 0);
  assert.equal(result.converted.length, 1);
  assert.deepEqual(capturedOptions, WEBP_OPTIONS);
  assert.equal(await sha256(input), beforeHash);
  assert.equal((await stat(input)).mtimeMs, beforeMtime);
  assert.equal(result.sizeSummary.inputBytes, (await stat(input)).size);
  assert.equal(result.sizeSummary.outputBytes, (await stat(output)).size);
  assert.match(formatSummary(result), /変換前容量（成功分）/);
  assert.match(formatSummary(result), /削減率（成功分合計）/);
});

test('変換後が大きくなってもWebPを保持し負の削減率を集計できる', async () => {
  const summary = calculateSizeSummary([{ inputBytes: 100, outputBytes: 125 }]);
  assert.deepEqual(summary, { inputBytes: 100, outputBytes: 125, reducedBytes: -25, reductionRate: -25 });

  const root = await makeTestRoot();
  const input = path.join(root, 'tiny.png');
  await makePng(input, { width: 1, height: 1 });
  const result = await runConversion(root);
  assert.equal(result.converted.length, 1);
  assert.equal((await stat(path.join(root, 'tiny.webp'))).isFile(), true);
});

test('既存WebPを上書きせず、内容と更新日時を保つ', async () => {
  const root = await makeTestRoot();
  const input = path.join(root, 'existing.png');
  const output = path.join(root, 'existing.webp');
  await makePng(input);
  await writeFile(output, Buffer.from('do not overwrite'));
  const hash = await sha256(output);
  const mtime = (await stat(output)).mtimeMs;
  const result = await runConversion(root);
  assert.equal(result.skippedExisting.length, 1);
  assert.equal(await sha256(output), hash);
  assert.equal((await stat(output)).mtimeMs, mtime);
});

test('透明PNGからアルファ付きWebPを作る', async () => {
  const root = await makeTestRoot();
  await makePng(path.join(root, 'alpha.png'), { alpha: 0.25 });
  await runConversion(root);
  const metadata = await readMetadata(path.join(root, 'alpha.webp'));
  assert.equal(metadata.format, 'webp');
  assert.equal(metadata.hasAlpha, true);
});

test('JPEGのEXIF Orientationを画素へ反映する', async () => {
  const root = await makeTestRoot();
  await makeJpeg(path.join(root, 'oriented.jpg'), { width: 2, height: 3, orientation: 6 });
  await runConversion(root);
  const metadata = await readMetadata(path.join(root, 'oriented.webp'));
  assert.equal(metadata.width, 3);
  assert.equal(metadata.height, 2);
  assert.equal(metadata.orientation, undefined);
});

test('壊れた画像の後も正常画像を変換し終了コード2にする', async () => {
  const root = await makeTestRoot();
  await writeFile(path.join(root, 'broken.jpg'), 'not an image');
  await makePng(path.join(root, 'valid.png'));
  const result = await runConversion(root, { workerLimit: 1 });
  assert.equal(result.converted.length, 1);
  assert.equal(result.failed.length, 1);
  assert.equal(result.exitCode, 2);
  assert.equal((await stat(path.join(root, 'valid.webp'))).isFile(), true);
});

test('サブフォルダは探索しない', async () => {
  const root = await makeTestRoot();
  const subfolder = path.join(root, 'subfolder');
  await mkdir(subfolder);
  await makePng(path.join(subfolder, 'nested.png'));
  const result = await runConversion(root);
  assert.equal(result.targetCount, 0);
  assert.rejects(stat(path.join(subfolder, 'nested.webp')), { code: 'ENOENT' });
});

test('日本語・空白・記号を含むパスを処理する', async () => {
  const base = await makeTestRoot('制作素材 & 確認用（秋）');
  const folder = path.join(base, '制作素材 & 確認用（秋）');
  await mkdir(folder);
  await makePng(path.join(folder, '商品画像 #1.png'));
  const result = await runConversion(folder);
  assert.equal(result.exitCode, 0);
  assert.equal((await stat(path.join(folder, '商品画像 #1.webp'))).isFile(), true);
});

test('同じ出力を並行作成しても片方だけが確定し上書きしない', async () => {
  const root = await makeTestRoot();
  const input = path.join(root, 'race.png');
  const output = path.join(root, 'race.webp');
  await makePng(input, { width: 64, height: 64, noise: true });
  const job = { inputPath: input, outputPath: output, inputName: 'race.png', outputName: 'race.webp' };
  const results = await Promise.all([convertOne(job), convertOne(job)]);
  assert.equal(results.filter((item) => item.status === 'converted').length, 1);
  assert.equal(results.filter((item) => item.status === 'skippedExisting').length, 1);
  assert.equal((await readMetadata(output)).format, 'webp');
});

test('正常時・失敗時に現在実行の一時ファイルを残さない', async () => {
  const root = await makeTestRoot();
  await makePng(path.join(root, 'ok.png'));
  await writeFile(path.join(root, 'bad.jpg'), 'bad');
  await runConversion(root);
  const names = await readdir(root);
  assert.equal(names.some((name) => name.startsWith(TEMP_PREFIX)), false);
});

test('24時間以上前の固有一時ファイルだけを削除する', async () => {
  const root = await makeTestRoot();
  const oldTemp = path.join(root, `${TEMP_PREFIX}old.tmp`);
  const recentTemp = path.join(root, `${TEMP_PREFIX}recent.tmp`);
  const unrelated = path.join(root, 'unrelated.tmp');
  await writeFile(oldTemp, 'old');
  await writeFile(recentTemp, 'recent');
  await writeFile(unrelated, 'keep');
  const oldDate = new Date(Date.now() - 25 * 60 * 60 * 1000);
  await utimes(oldTemp, oldDate, oldDate);
  const removed = await cleanupStaleTempFiles(root);
  assert.deepEqual(removed, [oldTemp]);
  assert.equal((await stat(recentTemp)).isFile(), true);
  assert.equal((await stat(unrelated)).isFile(), true);
});

test('ワーカープールは指定同時数を超えず、失敗後も継続する', async () => {
  const jobs = Array.from({ length: 8 }, (_, index) => ({ index }));
  let active = 0;
  let maximum = 0;
  const results = await runWorkerPool(jobs, 3, async (job) => {
    active += 1;
    maximum = Math.max(maximum, active);
    await new Promise((resolve) => setTimeout(resolve, 5));
    active -= 1;
    if (job.index === 2) throw new Error('expected failure');
    return { status: 'converted', ...job };
  });
  assert.equal(maximum, 3);
  assert.equal(results.length, 8);
  assert.equal(results[2].status, 'failed');
  assert.equal(results[7].status, 'converted');
});

test('案件種別に関係なく対象WebP以外のツールファイルを作らない', async () => {
  for (const projectType of ['wordpress', 'static-html', 'astro', 'nuxt']) {
    const base = await makeTestRoot(projectType);
    const folder = path.join(base, projectType);
    await mkdir(folder);
    await writeFile(path.join(folder, projectType === 'wordpress' ? 'wp-config.php' : 'project-marker.txt'), 'marker');
    await makePng(path.join(folder, 'asset.png'));
    await runConversion(folder);
    const names = (await readdir(folder)).sort();
    assert.deepEqual(names, [projectType === 'wordpress' ? 'wp-config.php' : 'project-marker.txt', 'asset.png', 'asset.webp'].sort());
  }
});
