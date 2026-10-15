# WebP Folder Converter v1.1.0 リリースノート

## 主な変更

- Windows 11 x64向けのEXEインストーラーを追加しました。
- EXEをダブルクリックするだけで、ユーザー単位でインストールできます。管理者権限は不要です。
- Windowsの「インストールされているアプリ」からアンインストールできるようになりました。
- v1.0.0のPowerShell版が既定の場所に導入されている場合、手動アンインストールなしで更新できます。
- Node.js 24.21.0、Sharp 0.35.5、Windows x64用libvipsを引き続き同梱しています。

画像変換処理の仕様はv1.0.0から変更していません。PNG/JPG/JPEG、非再帰、元画像保持、既存WebP非上書き、画質80、アルファ品質100、最大4件の並列処理、結果ダイアログ、ログ保存を維持しています。

## インストールと更新

`WebP-Converter-Setup-1.1.0.exe` をダブルクリックし、ウィザードに従ってください。インストール先は次の固定パスです。

```text
%LOCALAPPDATA%\Programs\WebPFolderConverter
```

v1.0.0から更新する場合も同じEXEを実行します。セットアップは正規のv1.0.0構成を検証してバックアップした後に置き換えます。検証できない既存構成は自動変更しません。

## アンインストール

Windows 11の「設定」→「アプリ」→「インストールされているアプリ」からアンインストールしてください。右クリックメニューとアプリ本体は削除されますが、次のデータは削除されません。

- 元画像と生成済みWebP
- Web制作案件内のファイル
- `%LOCALAPPDATA%\WebPFolderConverter\logs` の変換ログ

## SHA-256と署名

配布物には `WebP-Converter-Setup-1.1.0.exe.sha256` を添付します。PowerShellの `Get-FileHash` でEXEのSHA-256が一致することを確認できます。

v1.1.0のEXEはAuthenticode未署名です。そのため、Windows SmartScreenが「不明な発行元」と表示する場合があります。GitHub ReleasesのURLとSHA-256を確認してください。

## 配布予定ファイル

- `WebP-Converter-Setup-1.1.0.exe`
- `WebP-Converter-Setup-1.1.0.exe.sha256`

GitHub Release、タグ、配布ファイルの公開は実機確認後に行います。
