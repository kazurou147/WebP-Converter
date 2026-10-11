import { constants as fsConstants } from 'node:fs';
import {
  access,
  copyFile,
  link,
  lstat,
  mkdir,
  readdir,
  readFile,
  rm,
  stat,
  unlink,
  writeFile
} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import sharp from 'sharp';

export const TOOL_NAME = 'WebP Folder Converter';
export const TOOL_VERSION = '1.0.0';
export const WEBP_OPTIONS = Object.freeze({
  quality: 80,
  alphaQuality: 100,
  effort: 4,
  exact: true
});
export const TEMP_PREFIX = '.webp-folder-converter.';
export const DEFAULT_WORKER_LIMIT = Math.max(
  1,
  Math.min(4, typeof os.availableParallelism === 'function' ? os.availableParallelism() : os.cpus().length)
);

const SUPPORTED_EXTENSIONS = new Set(['.png', '.jpg', '.jpeg']);
const LINK_FALLBACK_CODES = new Set(['EXDEV', 'EPERM', 'EACCES', 'ENOTSUP', 'EOPNOTSUPP', 'UNKNOWN']);

export class UserFacingError extends Error {
  constructor(code, message, cause) {
    super(message, { cause });
    this.name = 'UserFacingError';
    this.code = code;
  }
}

export function parseArguments(argv) {
  const parsed = { folder: null, jsonResult: null };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--folder' || argument === '--json-result') {
      const value = argv[index + 1];
      if (!value || value.startsWith('--')) {
        throw new UserFacingError('INVALID_ARGUMENT', `${argument} の値がありません。`);
      }
      const key = argument === '--folder' ? 'folder' : 'jsonResult';
      if (parsed[key] !== null) {
        throw new UserFacingError('INVALID_ARGUMENT', `${argument} が重複しています。`);
      }
      parsed[key] = path.resolve(value);
      index += 1;
      continue;
    }
    throw new UserFacingError('INVALID_ARGUMENT', `不明な引数です: ${argument}`);
  }
  if (!parsed.folder) {
    throw new UserFacingError('INVALID_ARGUMENT', '--folder を指定してください。');
  }
  return parsed;
}

export async function validateFolder(folderPath) {
  let folderStat;
  try {
    folderStat = await stat(folderPath);
  } catch (error) {
    throw new UserFacingError('FOLDER_NOT_FOUND', `対象フォルダが見つかりません: ${folderPath}`, error);
  }
  if (!folderStat.isDirectory()) {
    throw new UserFacingError('NOT_A_FOLDER', `指定されたパスはフォルダではありません: ${folderPath}`);
  }
  return folderStat;
}

export function isSupportedInput(entry) {
  return entry.isFile() && SUPPORTED_EXTENSIONS.has(path.extname(entry.name).toLocaleLowerCase('en-US'));
}

export function buildOutputPath(inputPath) {
  const parsed = path.parse(inputPath);
  return path.join(parsed.dir, `${parsed.name}.webp`);
}

export function outputNameKey(fileName) {
  return fileName.normalize('NFC').toLocaleLowerCase('en-US');
}

export function planConversions(folderPath, entries) {
  const regularFileNames = new Set(
    entries.filter((entry) => entry.isFile()).map((entry) => outputNameKey(entry.name))
  );
  const candidates = entries.filter(isSupportedInput).map((entry) => {
    const inputPath = path.join(folderPath, entry.name);
    const outputPath = buildOutputPath(inputPath);
    return {
      inputPath,
      outputPath,
      inputName: entry.name,
      outputName: path.basename(outputPath)
    };
  });

  const groups = new Map();
  for (const candidate of candidates) {
    const key = outputNameKey(candidate.outputName);
    const group = groups.get(key) ?? [];
    group.push(candidate);
    groups.set(key, group);
  }

  const jobs = [];
  const skippedExisting = [];
  const skippedConflict = [];
  for (const [key, group] of groups) {
    if (group.length > 1) {
      skippedConflict.push(...group.map((item) => ({ ...item, reason: '入力ファイル同士の出力名が競合します。' })));
    } else if (regularFileNames.has(key)) {
      skippedExisting.push({ ...group[0], reason: '既存のWebPがあります。' });
    } else {
      jobs.push(group[0]);
    }
  }

  return { candidates, jobs, skippedExisting, skippedConflict };
}

function isNotFound(error) {
  return error && error.code === 'ENOENT';
}

async function pathExists(filePath) {
  try {
    await lstat(filePath);
    return true;
  } catch (error) {
    if (isNotFound(error)) return false;
    throw error;
  }
}

function makeTempPath(outputPath) {
  return path.join(
    path.dirname(outputPath),
    `${TEMP_PREFIX}${process.pid}.${randomBytes(12).toString('hex')}.tmp`
  );
}

async function removeTempFile(tempPath) {
  const retryable = new Set(['EPERM', 'EBUSY', 'EACCES']);
  let lastError;
  for (let attempt = 0; attempt < 6; attempt += 1) {
    try {
      await unlink(tempPath);
      return;
    } catch (error) {
      if (isNotFound(error)) return;
      lastError = error;
      if (!retryable.has(error.code) || attempt === 5) break;
      await new Promise((resolve) => setTimeout(resolve, 20 * (attempt + 1)));
    }
  }
  throw lastError;
}

async function commitExclusively(tempPath, outputPath) {
  try {
    await link(tempPath, outputPath);
    return;
  } catch (error) {
    if (error.code === 'EEXIST') throw error;
    if (!LINK_FALLBACK_CODES.has(error.code)) throw error;
  }
  await copyFile(tempPath, outputPath, fsConstants.COPYFILE_EXCL);
}

function stableError(error) {
  if (error instanceof UserFacingError) {
    return { code: error.code, message: error.message, detail: error.cause?.stack ?? error.stack };
  }
  const code = typeof error?.code === 'string' ? error.code : 'CONVERSION_FAILED';
  return {
    code,
    message: error instanceof Error ? error.message : String(error),
    detail: error instanceof Error ? error.stack : String(error)
  };
}

export async function convertOne(job, options = {}) {
  const sharpFactory = options.sharpFactory ?? sharp;
  const webpOptions = options.webpOptions ?? WEBP_OPTIONS;
  const tempPath = makeTempPath(job.outputPath);
  let committed = false;
  try {
    if (await pathExists(job.outputPath)) {
      return { status: 'skippedExisting', ...job, reason: '変換開始時に既存のWebPを確認しました。' };
    }

    const before = await stat(job.inputPath);
    const conversion = sharpFactory(job.inputPath, { failOn: 'error' })
      .autoOrient()
      .webp(webpOptions);
    const outputInfo = await conversion.toFile(tempPath);
    if (outputInfo.format !== 'webp' || !Number.isInteger(outputInfo.width) || outputInfo.width <= 0 ||
        !Number.isInteger(outputInfo.height) || outputInfo.height <= 0) {
      throw new UserFacingError('INVALID_OUTPUT', '生成したファイルを有効なWebPとして確認できませんでした。');
    }

    const after = await stat(job.inputPath);
    if (before.size !== after.size || before.mtimeMs !== after.mtimeMs) {
      throw new UserFacingError('INPUT_CHANGED', '変換中に元画像が変更されました。');
    }

    try {
      await commitExclusively(tempPath, job.outputPath);
      committed = true;
    } catch (error) {
      if (error.code === 'EEXIST') {
        return { status: 'skippedExisting', ...job, reason: '変換中に同名のWebPが作成されました。' };
      }
      throw error;
    }

    const outputStat = await stat(job.outputPath);
    return {
      status: 'converted',
      ...job,
      inputBytes: before.size,
      outputBytes: outputStat.size,
      width: outputInfo.width,
      height: outputInfo.height
    };
  } catch (error) {
    const normalized = stableError(error);
    return {
      status: 'failed',
      ...job,
      errorCode: normalized.code,
      message: normalized.message,
      internalError: normalized.detail
    };
  } finally {
    try {
      await removeTempFile(tempPath);
    } catch (error) {
      options.onCleanupError?.(tempPath, error, committed);
    }
  }
}

export async function runWorkerPool(jobs, limit, worker) {
  const results = new Array(jobs.length);
  let nextIndex = 0;
  const workerCount = Math.max(1, Math.min(Math.trunc(limit) || 1, jobs.length || 1));

  async function runWorker() {
    while (true) {
      const index = nextIndex;
      nextIndex += 1;
      if (index >= jobs.length) return;
      try {
        results[index] = await worker(jobs[index], index);
      } catch (error) {
        const normalized = stableError(error);
        results[index] = {
          status: 'failed',
          ...jobs[index],
          errorCode: normalized.code,
          message: normalized.message,
          internalError: normalized.detail
        };
      }
    }
  }

  await Promise.all(Array.from({ length: workerCount }, () => runWorker()));
  return results;
}

export function calculateSizeSummary(converted) {
  const inputBytes = converted.reduce((total, item) => total + item.inputBytes, 0);
  const outputBytes = converted.reduce((total, item) => total + item.outputBytes, 0);
  const reducedBytes = inputBytes - outputBytes;
  const reductionRate = inputBytes === 0 ? null : (reducedBytes / inputBytes) * 100;
  return { inputBytes, outputBytes, reducedBytes, reductionRate };
}

export function formatBytes(bytes) {
  if (!Number.isFinite(bytes)) return '-';
  const sign = bytes < 0 ? '-' : '';
  const absolute = Math.abs(bytes);
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let value = absolute;
  let unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  const digits = unitIndex === 0 ? 0 : value >= 100 ? 0 : value >= 10 ? 1 : 2;
  return `${sign}${value.toFixed(digits)} ${units[unitIndex]}`;
}

export function formatSummary(result) {
  const size = result.sizeSummary ?? calculateSizeSummary(result.converted ?? []);
  const rate = size.reductionRate === null ? '-' : `${size.reductionRate.toFixed(1)}%`;
  return [
    'WebP変換が完了しました。',
    `対象: ${result.targetCount}`,
    `成功: ${result.converted.length}`,
    `既存のためスキップ: ${result.skippedExisting.length}`,
    `名前競合のためスキップ: ${result.skippedConflict.length}`,
    `失敗: ${result.failed.length}`,
    `変換前容量（成功分）: ${formatBytes(size.inputBytes)}`,
    `変換後容量（成功分）: ${formatBytes(size.outputBytes)}`,
    `削減率（成功分合計）: ${rate}`,
    `所要時間: ${(result.durationMs / 1000).toFixed(2)} 秒`,
    result.logPath ? `ログ: ${result.logPath}` : null
  ].filter(Boolean).join('\n');
}

function localTimestamp(date = new Date()) {
  const parts = [
    date.getFullYear(),
    String(date.getMonth() + 1).padStart(2, '0'),
    String(date.getDate()).padStart(2, '0'),
    '-',
    String(date.getHours()).padStart(2, '0'),
    String(date.getMinutes()).padStart(2, '0'),
    String(date.getSeconds()).padStart(2, '0'),
    '-',
    String(date.getMilliseconds()).padStart(3, '0')
  ];
  return parts.join('');
}

async function resolveLogDirectory() {
  const candidates = [];
  if (process.env.LOCALAPPDATA) {
    candidates.push(path.join(process.env.LOCALAPPDATA, 'WebPFolderConverter', 'logs'));
  }
  candidates.push(path.join(os.tmpdir(), 'WebPFolderConverter', 'logs'));
  let lastError;
  for (const candidate of candidates) {
    try {
      await mkdir(candidate, { recursive: true });
      await access(candidate, fsConstants.W_OK);
      return candidate;
    } catch (error) {
      lastError = error;
    }
  }
  throw new UserFacingError('LOG_UNAVAILABLE', 'ログ保存先を作成できませんでした。', lastError);
}

function logLines(result) {
  const lines = [
    `${TOOL_NAME} ${TOOL_VERSION}`,
    `Node.js: ${process.version}`,
    `Sharp: ${sharp.versions.sharp}`,
    `libvips: ${sharp.versions.vips}`,
    `開始: ${result.startedAt}`,
    `終了: ${result.finishedAt}`,
    `対象フォルダ: ${result.folder}`,
    `設定: quality=${WEBP_OPTIONS.quality}, alphaQuality=${WEBP_OPTIONS.alphaQuality}, effort=${WEBP_OPTIONS.effort}, workers=${result.workerLimit}, recursive=false`,
    ''
  ];
  for (const item of result.converted) {
    lines.push(`[変換] ${item.inputPath} -> ${item.outputPath} (${item.inputBytes} -> ${item.outputBytes} bytes)`);
  }
  for (const item of result.skippedExisting) {
    lines.push(`[既存スキップ] ${item.inputPath} -> ${item.outputPath}: ${item.reason}`);
  }
  for (const item of result.skippedConflict) {
    lines.push(`[競合スキップ] ${item.inputPath} -> ${item.outputPath}: ${item.reason}`);
  }
  for (const item of result.failed) {
    lines.push(`[失敗] ${item.inputPath} -> ${item.outputPath}: ${item.errorCode}: ${item.message}`);
    if (item.internalError) lines.push(item.internalError);
  }
  for (const item of result.cleanupWarnings ?? []) {
    lines.push(`[一時ファイル削除警告] ${item.tempPath}: ${item.message}`);
  }
  if (result.fatalError) {
    lines.push(
      '',
      `[致命的エラー] ${result.fatalError.code}: ${result.fatalError.message}`,
      result.fatalError.internalError ?? '',
      `終了コード: ${result.exitCode}`
    );
  } else {
    lines.push('', formatSummary({ ...result, logPath: null }), `終了コード: ${result.exitCode}`);
  }
  return lines;
}

async function pruneLogs(logDirectory) {
  try {
    const entries = await readdir(logDirectory, { withFileTypes: true });
    const logs = [];
    for (const entry of entries) {
      if (!entry.isFile() || !/^\d{8}-\d{6}-\d{3}\.log$/u.test(entry.name)) continue;
      const filePath = path.join(logDirectory, entry.name);
      const fileStat = await stat(filePath);
      logs.push({ filePath, mtimeMs: fileStat.mtimeMs });
    }
    logs.sort((a, b) => b.mtimeMs - a.mtimeMs);
    await Promise.all(logs.slice(30).map(({ filePath }) => rm(filePath, { force: true }).catch(() => {})));
  } catch {
    // Log retention is best-effort and never changes the conversion result.
  }
}

export async function writeRunLog(result) {
  const logDirectory = await resolveLogDirectory();
  const logPath = path.join(logDirectory, `${localTimestamp(new Date(result.startedAt))}.log`);
  await writeFile(logPath, `${logLines(result).join('\r\n')}\r\n`, { encoding: 'utf8', flag: 'wx' });
  await pruneLogs(logDirectory);
  return logPath;
}

export async function cleanupStaleTempFiles(folderPath, now = Date.now()) {
  const entries = await readdir(folderPath, { withFileTypes: true });
  const removed = [];
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.startsWith(TEMP_PREFIX) || !entry.name.endsWith('.tmp')) continue;
    const tempPath = path.join(folderPath, entry.name);
    try {
      const fileStat = await stat(tempPath);
      if (now - fileStat.mtimeMs >= 24 * 60 * 60 * 1000) {
        await unlink(tempPath);
        removed.push(tempPath);
      }
    } catch {
      // Cleanup is best-effort. Current conversion work must not be blocked.
    }
  }
  return removed;
}

export async function runConversion(folderPath, options = {}) {
  const started = new Date();
  const workerLimit = options.workerLimit ?? DEFAULT_WORKER_LIMIT;
  const cleanupWarnings = [];
  await validateFolder(folderPath);
  await cleanupStaleTempFiles(folderPath);

  let entries;
  try {
    entries = await readdir(folderPath, { withFileTypes: true });
  } catch (error) {
    throw new UserFacingError('FOLDER_ENUMERATION_FAILED', `対象フォルダを列挙できません: ${folderPath}`, error);
  }
  const plan = planConversions(folderPath, entries);
  options.onPlan?.(plan);

  const processed = await runWorkerPool(plan.jobs, workerLimit, async (job) => {
    const item = await convertOne(job, {
      ...options,
      onCleanupError(tempPath, error) {
        cleanupWarnings.push({ tempPath, message: error.message });
        options.onCleanupError?.(tempPath, error);
      }
    });
    options.onItem?.(item);
    return item;
  });

  const converted = processed.filter((item) => item.status === 'converted');
  const failed = processed.filter((item) => item.status === 'failed');
  const skippedDuringConversion = processed.filter((item) => item.status === 'skippedExisting');
  const finished = new Date();
  const result = {
    toolVersion: TOOL_VERSION,
    nodeVersion: process.version,
    sharpVersion: sharp.versions.sharp,
    folder: folderPath,
    startedAt: started.toISOString(),
    finishedAt: finished.toISOString(),
    durationMs: finished.getTime() - started.getTime(),
    workerLimit,
    targetCount: plan.candidates.length,
    converted,
    skippedExisting: [...plan.skippedExisting, ...skippedDuringConversion],
    skippedConflict: plan.skippedConflict,
    failed,
    cleanupWarnings,
    exitCode: failed.length > 0 ? 2 : 0,
    logPath: null
  };
  result.sizeSummary = calculateSizeSummary(converted);
  result.logPath = await writeRunLog(result);
  return result;
}

export async function writeJsonResult(jsonPath, result) {
  const publicResult = {
    targetCount: result.targetCount,
    convertedCount: result.converted.length,
    skippedExistingCount: result.skippedExisting.length,
    skippedConflictCount: result.skippedConflict.length,
    failedCount: result.failed.length,
    durationMs: result.durationMs,
    exitCode: result.exitCode,
    logPath: result.logPath,
    sizeSummary: result.sizeSummary,
    fatalError: result.fatalError ? {
      errorCode: result.fatalError.code,
      message: result.fatalError.message
    } : null,
    failureSummary: result.failed.slice(0, 5).map((item) => ({
      inputPath: item.inputPath,
      errorCode: item.errorCode,
      message: item.message
    }))
  };
  await mkdir(path.dirname(jsonPath), { recursive: true });
  await writeFile(jsonPath, JSON.stringify(publicResult, null, 2), { encoding: 'utf8', flag: 'wx' });
}

export async function createFatalResult(error, { folder = null, startedAt = new Date() } = {}) {
  const finished = new Date();
  const normalized = stableError(error);
  const result = {
    toolVersion: TOOL_VERSION,
    nodeVersion: process.version,
    sharpVersion: sharp.versions.sharp,
    folder: folder ?? '(未確定)',
    startedAt: startedAt.toISOString(),
    finishedAt: finished.toISOString(),
    durationMs: finished.getTime() - startedAt.getTime(),
    workerLimit: 0,
    targetCount: 0,
    converted: [],
    skippedExisting: [],
    skippedConflict: [],
    failed: [],
    cleanupWarnings: [],
    exitCode: 1,
    sizeSummary: calculateSizeSummary([]),
    fatalError: {
      code: normalized.code,
      message: normalized.message,
      internalError: normalized.detail
    },
    logPath: null
  };
  result.logPath = await writeRunLog(result);
  return result;
}

export async function readPackageVersion(packageJsonPath) {
  return JSON.parse(await readFile(packageJsonPath, 'utf8')).version;
}
