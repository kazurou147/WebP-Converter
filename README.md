# WebP Folder Converter Ver.1

Windows 11のエクスプローラーで選択したフォルダ直下にあるPNG・JPEG画像を、同じフォルダへWebPとして一括保存する個人向けツールです。元画像を変更せず、既存のWebPを上書きしません。

## 主な動作

- 対象は選択フォルダ直下の `.png`、`.jpg`、`.jpeg`（大文字拡張子を含む）です。
- サブフォルダ、画像ファイルの右クリック、フォルダ背景の右クリックは対象外です。
- 出力は元のベース名に小文字の `.webp` を付けた名前です。
- 画質80、アルファ品質100、effort 4で変換します。
- PNGの透過を保持し、JPEGのEXIF Orientationを画素へ反映します。
- EXIF、GPS、コメント等のメタデータはWebPへ引き継ぎません。
- 既存の同名WebPは内容にかかわらずスキップします。
- `same.png` と `same.jpg` のように出力名が競合する入力は、両方ともスキップします。
- 最大4件の制御された並列処理を行い、1件が失敗しても残りを処理します。
- 成功分の変換前容量、変換後容量、合計削減率を結果に表示します。
- 変換後の容量が元画像より大きくなっても、自動削除せずWebPを保持します。この場合、合計削減率は負の値になることがあります。

## 動作環境

- Windows 11 64ビット（x64）
- 通常ユーザー。管理者権限は不要です。
- インストール後の利用にNode.js、npm、Sharp、Codex、VS Codeは不要です。
- インストール時と実行時にネットワーク接続は不要です。

配布物にはNode.js 24.21.0 LTS、Sharp 0.35.5とWindows x64用libvipsを同梱します。PCのPATHにあるNode.jsや、Web制作案件のNode.js環境は使用しません。

## インストール

重要: ソースコードのフォルダではなく、`scripts\build-release.ps1` が生成した `dist\WebPFolderConverter` 配布フォルダから実行してください。

1. 配布フォルダをローカルPCへ展開します。
2. 配布フォルダでPowerShellを開きます。
3. 次を実行します。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1
```

インストーラーは以下を行います。

1. Windows 11 x64であることを確認します。
2. `release-manifest.json` に記録された全配布ファイルのSHA-256を検証します。
3. `%LOCALAPPDATA%\Programs\WebPFolderConverter` のステージング領域へ配置します。
4. 同梱Node.jsで1ピクセルのWebP変換自己診断を行います。
5. 成功後にアプリを切り替えます。
6. HKCUの所有キーだけに右クリックメニューを登録し、登録値を読み戻します。

更新も新しい配布フォルダから同じコマンドを再実行します。新版の自己診断前に動作中の版を置き換えません。

## 使い方

1. 変換したい画像が入ったフォルダ自体を右クリックします。
2. Windows 11の「その他のオプションを確認」を選びます。`Shift + F10` でも開けます。
3. 「WebPに変換」を選びます。
4. コンソールで進捗を確認します。
5. 完了ダイアログで件数と容量を確認します。

結果ダイアログには次を表示します。

- 対象、成功、既存スキップ、名前競合スキップ、失敗の件数
- 成功した画像の変換前容量合計
- 成功した画像の変換後容量合計
- 成功分合計の削減率
- 所要時間とログの場所

ログは `%LOCALAPPDATA%\WebPFolderConverter\logs` にUTF-8で保存し、直近30件を保持します。保存できない場合はOSの一時フォルダへフォールバックします。

## アンインストール

元の配布フォルダで次を実行します。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1
```

ログを残す場合は次を実行します。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1 -KeepLogs
```

アンインストーラーが削除するものは、HKCUの `WebPFolderConverter` キー、固定インストール先、既定では本ツールのログ領域だけです。元画像、生成済みWebP、案件内ファイル、PCへ別途導入されたNode.jsには触れません。

## 開発と自動テスト

開発時だけ、対応するNode.jsとnpmを用意して次を実行します。

```powershell
npm ci
npm test
npm run self-check
```

CLIを直接確認する場合:

```powershell
node .\src\convert-webp.mjs --folder 'C:\path\to\images'
```

自動テストでは、拡張子、非再帰、出力名、入力競合、元画像と既存WebPの不変、透過、EXIF Orientation、画質指定、部分失敗、日本語・空白・記号パス、空フォルダ、排他的な同時確定、一時ファイル、ワーカー数、案件非依存、容量集計を確認します。

右クリック表示、結果ダイアログ、UAC非表示、PATHにNode.jsがない環境、OneDrive、UNC共有、アンインストールはWindows 11実機で手動確認してください。テストのためにExplorerを強制終了する処理はありません。

## 自己完結リリースの作成

開発用PCで次を実行します。この工程だけはNode.js公式配布物とnpm依存を取得するため、ネットワーク接続が必要です。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release.ps1
```

出力先:

```text
dist\WebPFolderConverter\
├─ package.json
├─ package-lock.json
├─ release-manifest.json
├─ THIRD-PARTY-NOTICES.txt
├─ node_modules\
├─ runtime\
│  ├─ node.exe
│  └─ LICENSE
├─ licenses\npm\
├─ src\
└─ scripts\
```

ビルドスクリプトはNode.js公式の `SHASUMS256.txt` でZIPを検証し、固定した `package-lock.json` からWindows x64用の本番依存だけを復元します。同梱Node.jsによるSharp自己診断の後、全配布ファイルのSHA-256を `release-manifest.json` へ記録します。

## 終了コード

- `0`: 致命的エラーなし、個別変換失敗なし。スキップは許容します。
- `1`: 引数、フォルダ列挙、ログ、起動等の致命的エラーです。
- `2`: 全体処理は完了しましたが、1件以上の画像変換に失敗しました。

## 安全設計

- 元画像の削除、移動、書換えを行いません。
- 一時ファイルは出力フォルダ内に作り、WebP形式と寸法を確認してから排他的に確定します。
- NTFS等ではハードリンクの排他的作成を使用し、利用できないファイルシステムでは `COPYFILE_EXCL` へフォールバックします。
- 変換前の既存確認に加え、確定時にも上書きを防ぎます。
- シンボリックリンクを追跡せず、サブフォルダを列挙しません。
- `Invoke-Expression`、`eval`、ファイル名を埋め込んだ動的コマンドを使用しません。
- インストール先、ログ、レジストリはユーザー単位です。HKLMや管理者権限を使用しません。
- 実行時の通信、テレメトリ、自動更新を行いません。

## 実装上の決定

- SHA-256マニフェストは自己参照を避けるため、`release-manifest.json` 自身だけを対象外とし、それ以外の全配布ファイルを記録します。
- 専用アイコンファイルは追加せず、右クリック項目のアイコンには固定インストール先の同梱 `node.exe` を使用します。追加のバイナリアセットを減らすためです。
- 変換後のWebPが大きくなった場合も正常な変換結果として保持し、削減率を負数で表示します。
- テストfixtureは実行ごとにOSの一時フォルダへ生成し、リポジトリ内の原本を変更しません。

## 既知の制約

- Windows 11の新しい右クリックメニュー最上位には表示されません。「その他のオプションを確認」内に表示されます。
- 複数フォルダ同時選択、フォルダ背景、画像ファイル自体の右クリックには対応しません。
- PNG/JPEG以外、アニメーション、再帰変換、リサイズ、画質設定画面には対応しません。
- UNC共有や同期フォルダでは、共有側の権限・ファイルシステム・同期状態によって変換に失敗する場合があります。その場合も元画像と既存WebPは変更しません。
