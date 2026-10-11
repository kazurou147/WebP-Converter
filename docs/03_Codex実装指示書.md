# Codex向け実装指示書

## 1. 依頼文

この文書と同じフォルダにある `01_機能仕様書_Ver1.md`、`02_技術設計書.md`、`04_インストール・動作確認手順書.md` を正として、Windows 11用「WebP Folder Converter Ver.1」を実装してください。

不明点があっても、安全側の小さな仮定で進められる場合は実装を止めず、READMEの「実装上の決定」に記録してください。元画像の削除、既存WebPの上書き、再帰処理、Windows 11新メニュー用COM拡張は追加しないでください。

## 2. 完成条件

以下をすべて実装・検証して完了とする。

- Node.js + Sharpによる変換本体
- Node.jsとSharpを同梱した、案件・PC環境から独立したWindows x64リリース
- PowerShellのインストール、起動、アンインストールスクリプト
- HKCUの `Directory\shell` への右クリック項目登録
- 管理者権限を使わないインストール
- 画質80、PNG透過維持、非再帰、元画像保持、既存WebPスキップ
- ファイル単位エラー後の継続
- 最大4件の制御された並列処理
- 日本語・空白・記号を含むパス
- ログと結果ダイアログ
- 自動テストとWindows 11手動テスト手順
- README
- Node.js、Sharp、libvips等のライセンス・第三者通知

## 3. 実装順序

### Phase 1: プロジェクト初期化

1. 実装用の新規ディレクトリを作る。
2. ES Modulesを用いるNode.jsプロジェクトにする。
3. 実行時依存は原則 `sharp` のみとする。
4. テストはNode.js標準の `node:test` と `assert` を優先する。
5. `package-lock.json` をコミット対象にする。
6. `package.json` に `engines.node`、`test`、`self-check` スクリプトを定義する。

このNode.jsプロジェクトはツール自身の開発用であり、Web制作案件へ追加してはならない。

### Phase 2: 変換コア

実装単位を小さく分け、少なくとも次の関数相当をテスト可能にする。

- `parseArguments(argv)`
- `validateFolder(path)`
- `isSupportedInput(dirent)`
- `buildOutputPath(inputPath)`
- `planConversions(entries)`
- `convertOne(job, options)`
- `runWorkerPool(jobs, limit)`
- `formatSummary(result)`
- `writeRunLog(result)`

条件:

- `fs.promises.readdir(folder, { withFileTypes: true })` を1階層だけ実行する。
- `Dirent.isFile()` が真のものだけを候補にする。
- 対象拡張子は `.png`、`.jpg`、`.jpeg`。大文字小文字を無視する。
- `path.parse()` でベース名を得て、`.webp` を付ける。
- 出力名を大文字小文字を無視してグループ化し、複数入力が同じ出力になるグループは全件スキップする。
- 既存出力は変換前と出力確定時の両方で保護する。
- 1件の例外をワーカープール全体へ伝播させない。
- `Promise.all(files.map(...))` による無制限並列は使わない。

Sharp設定:

```js
sharp(inputPath, { failOn: 'error' })
  .autoOrient()
  .webp({ quality: 80, alphaQuality: 100, effort: 4, exact: true })
```

一時ファイルへ出力後、WebPであることと正の寸法を確認し、既存を上書きしない排他的な確定処理を行う。処理の成否にかかわらず、作成した一時ファイルの削除を `finally` で試みる。

### Phase 3: CLIとログ

CLI仕様:

```text
node src/convert-webp.mjs --folder <absolute-or-relative-path> [--json-result <path>]
```

- 相対パスはCLI内部で絶対パスへ解決する。
- 通常表示は日本語。
- `--json-result` がある場合、起動ラッパーが読めるUTF-8 JSONを安全に出力する。
- JSONには少なくとも件数、所要時間、終了コード、ログパス、先頭数件の失敗概要を含める。
- JSON書込み失敗だけで変換済みファイルを巻き戻さない。
- ログは `%LOCALAPPDATA%\WebPFolderConverter\logs`。利用できなければOSの一時ディレクトリへフォールバックする。
- ログ保持は直近30件。

### Phase 4: PowerShellラッパー

`invoke.ps1` は以下を満たすこと。

- 位置引数でフォルダパスを1つ受け取る。
- `Invoke-Expression` を使わない。
- `$PSScriptRoot` からアプリ本体を解決する。
- 一時的な結果JSONのパスを安全に作る。
- Nodeへフォルダと結果JSONを引数配列として渡す。
- 結果JSONを読み、日本語の結果ダイアログを表示する。
- JSONが作られない致命的失敗でもエラーダイアログを表示する。
- 結果JSONは `finally` で削除する。
- 終了コードを引き継ぐ。

PowerShell 5.1で構文エラーがないことを確認する。PowerShell 7専用構文を使わない。

### Phase 5: インストーラー

インストーラー実装前に、Windows x64専用の自己完結リリースを作成する。

- Node.js公式のWindows x64 ZIPに含まれるランタイムを `runtime` へ組み込む。
- SharpはWindows x64環境で本番依存だけを復元し、必要なoptional dependenciesとlibvipsを欠落させない。
- 不要なnpmキャッシュ、テスト、開発依存はリリースへ含めない。
- `runtime\node.exe` からSharpの自己診断を行う。
- リリースマニフェストへ全配布ファイルのSHA-256、Node.js版、Sharp版、対象OS/CPUを記録する。
- Node.jsと第三者依存のライセンス・通知を同梱する。
- 利用PCでのインストール時に `npm install`、`npm ci`、ダウンロードを行わない。

`scripts/install.ps1` を実装する。

- 管理者としての実行を要求しない。
- 固定先は `[Environment]::GetFolderPath('LocalApplicationData')` 配下の `Programs\WebPFolderConverter`。
- `%LOCALAPPDATA%` という未展開文字列をレジストリへ保存しない。
- 配布マニフェストの整合性検証に失敗したら登録を行わない。
- `$InstallDir\runtime\node.exe` でSharpの読み込みと1px画像のWebP変換を自己診断する。
- PATH上の `node`、`npm`、`npx` を呼び出さない。
- .NET Registry APIを使い、次のキーを登録する。

```text
HKCU\Software\Classes\Directory\shell\WebPFolderConverter
HKCU\Software\Classes\Directory\shell\WebPFolderConverter\command
```

- 表示名は `WebPに変換`。
- コマンドは `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<absolute>\invoke.ps1" "%1"`。
- 文字列の引用符を正しく登録し、登録後に読み戻して確認する。
- 再実行で更新できる冪等性を持たせる。
- 既存インストール更新時も、失敗した新版で動作中の版を壊さない。

`scripts/uninstall.ps1` は所有するキー、固定インストール先、ツールのログ領域だけを削除する。削除直前に絶対パスが期待値と完全一致することを検証する。元画像、生成済みWebP、案件内ファイル、PCに別途導入されたNode.jsは削除しない。

### Phase 6: テスト

最低限、次の自動テストを実装する。

1. `.png/.jpg/.jpeg` と大文字拡張子だけが対象になる。
2. サブフォルダを処理しない。
3. 出力名が正しい。
4. 既存WebPを上書きしない。処理前後のハッシュが同じ。
5. 元画像を変更しない。処理前後のハッシュが同じ。
6. 透明PNGからアルファ付きWebPを生成する。
7. 画質オプションが80で渡される。
8. 壊れたJPEGと正常画像が混在しても正常画像は変換され、終了コード2になる。
9. `same.png` と `same.jpg` は競合スキップされる。
10. 日本語、空白、`&`、括弧を含むパスで成功する。
11. 空フォルダは終了コード0。
12. 並行して同じ出力を作ろうとしても既存を上書きしない。
13. 一時ファイルが正常時・失敗時とも残らない。
14. PATHにNode.jsがない状態でも同梱 `runtime\node.exe` で動作する。
15. WordPress、静的HTML、Astro、Nuxt.jsの各サンプルフォルダへ、WebP以外のツールファイルを作らない。
16. Codex、VS Code、開発サーバーを起動せずに右クリック操作だけで動作する。

自動テストのfixtureはテスト中に一時ディレクトリへコピーして使用し、リポジトリ内の原本を書き換えない。

Windows実機では、レジストリ登録、メニュー表示、右クリック起動、結果ダイアログ、アンインストールを手動確認する。テストのためにExplorerプロセスを強制終了する処理をインストーラーへ組み込まない。

## 4. 禁止事項

- 元画像の削除・移動・更新
- 既存 `.webp` の上書き
- サブフォルダ探索
- `Invoke-Expression`、`eval`、ファイル名を含むシェル文字列連結
- 管理者権限やHKLMへの登録
- Explorerプロセス内へロードするDLL
- 無制限並列
- テレメトリ、解析送信、自動アップロード
- 仕様外のGUIフレームワーク導入
- Sharp以外の重複する画像変換依存
- 案件側のNode.js、Sharp、`package.json`、`node_modules`、環境変数への依存
- インストール時または実行時の依存パッケージダウンロード

## 5. 実装完了時の報告内容

Codexは完了時に次を簡潔に報告する。

- 実装したファイル一覧
- 採用したNode.js・Sharpのバージョン
- 自己完結リリースのファイル構成、SHA-256マニフェスト、ライセンス同梱結果
- 自動テスト結果
- Windows 11実機確認の結果。実機操作をしていない場合は未確認と明記する
- 既知の制約
- インストールコマンドとアンインストールコマンド
- `git diff --check` 等の基本確認結果

## 6. 完了判定チェックリスト

- [ ] 4文書を読んだ
- [ ] 仕様外の機能を追加していない
- [ ] `npm ci` が成功する
- [ ] `npm test` が成功する
- [ ] Sharp自己診断が成功する
- [ ] 同梱Node.jsでSharp自己診断が成功する
- [ ] システムNode.jsなしでインストール・実行できる
- [ ] インストール時・実行時にネットワークアクセスしない
- [ ] 案件フォルダへ依存物・設定・ログを作らない
- [ ] 元画像不変テストが成功する
- [ ] 既存WebP不変テストが成功する
- [ ] 日本語パステストが成功する
- [ ] 部分失敗後の継続テストが成功する
- [ ] HKCU登録内容を読み戻して確認した
- [ ] アンインストールで所有キーだけが消える
- [ ] READMEにWindows 11での操作経路を明記した

