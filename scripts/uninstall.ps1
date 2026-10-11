[CmdletBinding()]
param(
    [switch]$KeepLogs
)

$ErrorActionPreference = 'Stop'
$LocalAppData = [Environment]::GetFolderPath('LocalApplicationData')
$ExpectedInstallDir = [IO.Path]::GetFullPath((Join-Path $LocalAppData 'Programs\WebPFolderConverter'))
$ExpectedDataDir = [IO.Path]::GetFullPath((Join-Path $LocalAppData 'WebPFolderConverter'))
$RegistryPath = 'Software\Classes\Directory\shell\WebPFolderConverter'

function Remove-ExpectedDirectory {
    param([string]$Path, [string]$Expected)
    $ResolvedPath = [IO.Path]::GetFullPath($Path)
    $ResolvedExpected = [IO.Path]::GetFullPath($Expected)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($ResolvedPath, $ResolvedExpected)) {
        throw "安全確認に失敗しました。削除対象が期待値と一致しません: $ResolvedPath"
    }
    if (Test-Path -LiteralPath $ResolvedPath) {
        Write-Host "削除: $ResolvedPath"
        Remove-Item -LiteralPath $ResolvedPath -Recurse -Force
    }
}

Write-Host "右クリックメニュー登録を削除します: HKCU\$RegistryPath"
[Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($RegistryPath, $false)
Remove-ExpectedDirectory -Path $ExpectedInstallDir -Expected $ExpectedInstallDir
if ($KeepLogs) {
    Write-Host "ログを保持しました: $ExpectedDataDir"
} else {
    Remove-ExpectedDirectory -Path $ExpectedDataDir -Expected $ExpectedDataDir
}

Write-Host 'アンインストールが完了しました。元画像と生成済みWebPは削除していません。'
