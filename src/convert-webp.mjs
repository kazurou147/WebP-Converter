#!/usr/bin/env node
import {
  createFatalResult,
  formatBytes,
  formatSummary,
  parseArguments,
  runConversion,
  writeJsonResult
} from './converter.mjs';

let jsonResultPath = null;
let exitCode = 1;
let targetFolder = null;
const cliStartedAt = new Date();

try {
  const args = parseArguments(process.argv.slice(2));
  jsonResultPath = args.jsonResult;
  targetFolder = args.folder;
  console.log(`対象フォルダ: ${args.folder}`);
  const result = await runConversion(args.folder, {
    onPlan(plan) {
      console.log(`対象ファイル数: ${plan.candidates.length}`);
      for (const item of plan.skippedExisting) console.log(`[スキップ・既存] ${item.inputName}`);
      for (const item of plan.skippedConflict) console.log(`[スキップ・競合] ${item.inputName}`);
    },
    onItem(item) {
      if (item.status === 'converted') {
        console.log(`[変換] ${item.inputName}: ${formatBytes(item.inputBytes)} -> ${formatBytes(item.outputBytes)}`);
      } else if (item.status === 'skippedExisting') {
        console.log(`[スキップ・既存] ${item.inputName}`);
      } else {
        console.error(`[失敗] ${item.inputName}: ${item.message}`);
      }
    }
  });
  console.log('');
  console.log(formatSummary(result));
  exitCode = result.exitCode;
  if (jsonResultPath) {
    try {
      await writeJsonResult(jsonResultPath, result);
    } catch (error) {
      console.error(`結果JSONを書き込めませんでした: ${error.message}`);
    }
  }
} catch (error) {
  console.error(`致命的エラー: ${error.message}`);
  try {
    const result = await createFatalResult(error, { folder: targetFolder, startedAt: cliStartedAt });
    console.error(`ログ: ${result.logPath}`);
    if (jsonResultPath) await writeJsonResult(jsonResultPath, result);
  } catch (reportError) {
    console.error(`致命的エラーの記録にも失敗しました: ${reportError.message}`);
  }
}

process.exitCode = exitCode;
