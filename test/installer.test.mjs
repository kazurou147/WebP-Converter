import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, readdir, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

async function read(relativePath) {
  return readFile(path.join(projectRoot, relativePath), 'utf8');
}

function parseJson(text) {
  return JSON.parse(text.replace(/^\uFEFF/u, ''));
}

async function exists(filePath) {
  try {
    await stat(filePath);
    return true;
  } catch {
    return false;
  }
}

async function listFiles(root) {
  const result = [];
  async function visit(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const fullPath = path.join(directory, entry.name);
      if (entry.isDirectory()) await visit(fullPath);
      else if (entry.isFile()) result.push(path.relative(root, fullPath).replaceAll('\\', '/'));
    }
  }
  await visit(root);
  return result.sort();
}

test('製品バージョンはpackage、ロックファイル、実行ログで1.1.0に一致する', async () => {
  const packageJson = parseJson(await read('package.json'));
  const packageLock = parseJson(await read('package-lock.json'));
  const converter = await read('src/converter.mjs');
  assert.equal(packageJson.version, '1.1.0');
  assert.equal(packageLock.version, packageJson.version);
  assert.equal(packageLock.packages[''].version, packageJson.version);
  assert.match(converter, /TOOL_VERSION = '1\.1\.0'/u);
});

test('Inno Setup設定は固定パス、非管理者、Windows 11 x64、HKCU専用である', async () => {
  const source = await read('installer/WebPFolderConverter.iss');
  assert.match(source, /AppId=\{\{A39D662A-4554-4EF0-9E11-541FFAD70C43\}/u);
  assert.match(source, /DefaultDirName=\{localappdata\}\\Programs\\WebPFolderConverter/u);
  assert.match(source, /DisableDirPage=yes/u);
  assert.match(source, /PrivilegesRequired=lowest/u);
  assert.match(source, /PrivilegesRequiredOverridesAllowed=\s*$/mu);
  assert.match(source, /MinVersion=10\.0\.22000/u);
  assert.match(source, /ArchitecturesAllowed=x64os/u);
  assert.match(source, /SetupArchitecture=x64/u);
  assert.match(source, /OutputBaseFilename=WebP-Converter-Setup-\{#AppVersion\}/u);
  assert.match(source, /Root: HKCU; Subkey: "Software\\Classes\\Directory\\shell\\WebPFolderConverter"/u);
  assert.match(source, /Flags: uninsdeletekey/u);
  assert.doesNotMatch(source, /Root: HKLM/u);
  assert.doesNotMatch(source, /Type: filesandordirs/u);
  assert.doesNotMatch(source, /\{localappdata\}\\WebPFolderConverter\\logs/u);
});

test('移行ヘルパーは正規v1.0.0だけを退避し固定パス以外を拒否する', async () => {
  const source = await read('scripts/installer-migration.ps1');
  assert.match(source, /Package\.version -ne '1\.0\.0'/u);
  assert.match(source, /Assert-ExactPath -Actual \$InstallDir/u);
  assert.match(source, /phase = 'backing-up'/u);
  assert.match(source, /\$State\.phase = 'prepared'/u);
  assert.match(source, /'prepared' \{ Restore-LegacyInstall/u);
  assert.match(source, /Move-Item -LiteralPath \$BackupDir -Destination \$InstallDir/u);
  assert.doesNotMatch(source, /Remove-Item[^\r\n]+\*/u);
});

test('作成済みリリースのマニフェストは全ファイルのSHA-256と一致する', async (context) => {
  const releaseRoot = path.join(projectRoot, 'dist', 'WebPFolderConverter');
  const manifestPath = path.join(releaseRoot, 'release-manifest.json');
  if (!(await exists(manifestPath))) {
    context.skip('build-release.ps1実行後に検証します。');
    return;
  }
  const packageJson = parseJson(await read('package.json'));
  const manifest = parseJson(await readFile(manifestPath, 'utf8'));
  if (manifest.version !== packageJson.version) {
    context.skip('distには別バージョンの成果物があります。v1.1.0再ビルド後に検証します。');
    return;
  }

  const listed = [...manifest.files].sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
  const actual = (await listFiles(releaseRoot)).filter((item) => item !== 'release-manifest.json');
  assert.deepEqual(listed.map((item) => item.path), actual);
  for (const item of listed) {
    const bytes = await readFile(path.join(releaseRoot, ...item.path.split('/')));
    assert.equal(createHash('sha256').update(bytes).digest('hex'), item.sha256, item.path);
  }
});

test('作成済みインストーラーとSHA-256ファイルが一致する', async (context) => {
  const packageJson = parseJson(await read('package.json'));
  const name = `WebP-Converter-Setup-${packageJson.version}.exe`;
  const installerPath = path.join(projectRoot, 'dist', 'installer', name);
  const checksumPath = `${installerPath}.sha256`;
  if (!(await exists(installerPath)) || !(await exists(checksumPath))) {
    context.skip('build-installer.ps1実行後に検証します。');
    return;
  }
  const expected = (await readFile(checksumPath, 'ascii')).trim();
  const actualHash = createHash('sha256').update(await readFile(installerPath)).digest('hex');
  assert.equal(expected, `${actualHash}  ${name}`);
});
