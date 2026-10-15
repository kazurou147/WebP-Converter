[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$MigrationScript = Join-Path $ProjectRoot 'scripts\installer-migration.ps1'
$WindowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ("webp-migration-tests-{0}" -f [Guid]::NewGuid().ToString('N'))
$RegistryTestParent = 'Software\WebPFolderConverter\MigrationTests'
$RegistryTestRoot = "$RegistryTestParent\$([Guid]::NewGuid().ToString('N'))"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT: $Message" }
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $Parent = Split-Path -Parent $Path
    if ($Parent) { New-Item -ItemType Directory -Path $Parent -Force | Out-Null }
    Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8 -NoNewline
}

function Get-Sha256 {
    param([string]$Path)
    $Stream = [IO.File]::OpenRead($Path)
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($Hasher.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant() }
    finally { $Hasher.Dispose(); $Stream.Dispose() }
}

function Set-ContextMenu {
    param($Case, [switch]$V11)
    $Base = [Microsoft.Win32.Registry]::CurrentUser
    $Base.DeleteSubKeyTree($Case.ContextRegistryPath, $false)
    $Verb = $Base.CreateSubKey($Case.ContextRegistryPath, $true)
    $Command = $Base.CreateSubKey("$($Case.ContextRegistryPath)\command", $true)
    try {
        $Verb.SetValue('', 'WebPに変換')
        $Verb.SetValue('MUIVerb', 'WebPに変換')
        $Verb.SetValue('Icon', (Join-Path $Case.InstallDir 'runtime\node.exe'))
        if ($V11) {
            $PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $Command.SetValue('', ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" "%1"' -f $PowerShell, (Join-Path $Case.InstallDir 'invoke.ps1')))
        } else {
            $Command.SetValue('', ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" "%1"' -f (Join-Path $Case.InstallDir 'invoke.ps1')))
        }
    }
    finally { $Verb.Dispose(); $Command.Dispose() }
}

function New-TestCase {
    param([string]$Name)
    $LocalAppData = Join-Path $TestRoot $Name
    $Programs = Join-Path $LocalAppData 'Programs'
    $InstallDir = Join-Path $Programs 'WebPFolderConverter'
    $BackupDir = Join-Path $Programs '.WebPFolderConverter.v1.0.0-backup'
    $StatePath = Join-Path $Programs '.WebPFolderConverter.migration.json'
    $Context = "$RegistryTestRoot\$Name\Context"
    $UninstallRelative = "$RegistryTestRoot\$Name\Uninstall\{A39D662A-4554-4EF0-9E11-541FFAD70C43}_is1"
    $ManifestPath = Join-Path $LocalAppData 'trusted-v1.0.0.json'
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $Contents = [ordered]@{
        'package.json' = '{"name":"webp-folder-converter","version":"1.0.0"}'
        'runtime\node.exe' = 'trusted-node-24.21.0'
        'src\converter.mjs' = "export const TOOL_VERSION = '1.0.0';"
        'src\convert-webp.mjs' = 'trusted-cli'
        'invoke.ps1' = 'trusted-invoke'
        'uninstall.ps1' = 'trusted-uninstall'
    }
    foreach ($Pair in $Contents.GetEnumerator()) { Write-Utf8File -Path (Join-Path $InstallDir $Pair.Key) -Content $Pair.Value }
    $Files = foreach ($RelativePath in $Contents.Keys) {
        [ordered]@{
            path = $RelativePath.Replace('\', '/')
            sha256 = Get-Sha256 -Path (Join-Path $InstallDir $RelativePath)
        }
    }
    $Manifest = [ordered]@{
        schemaVersion = 1; product = 'WebP Folder Converter'; version = '1.0.0'; target = 'win32-x64'
        nodeVersion = '24.21.0'; sharpVersion = '0.35.5'; sourceAsset = 'test-fixture.zip'
        sourceAssetSha256 = ('0' * 64); files = @($Files)
    }
    $Manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
    $Case = [pscustomobject]@{
        Name = $Name; LocalAppData = $LocalAppData; InstallDir = $InstallDir; BackupDir = $BackupDir
        StatePath = $StatePath; ContextRegistryPath = $Context
        UninstallRegistryPath = "Registry::HKEY_CURRENT_USER\$UninstallRelative"
        UninstallRegistryRelativePath = $UninstallRelative; ManifestPath = $ManifestPath
    }
    Set-ContextMenu -Case $Case
    return $Case
}

function Invoke-Migration {
    param($Case, [string]$Action, [string]$FailurePoint = 'None')
    $Arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MigrationScript,
        '-Action', $Action, '-InstallDir', $Case.InstallDir, '-BackupDir', $Case.BackupDir,
        '-StatePath', $Case.StatePath, '-UninstallRegistryPath', $Case.UninstallRegistryPath,
        '-TrustedManifestPath', $Case.ManifestPath, '-ContextRegistryPath', $Case.ContextRegistryPath,
        '-TestMode', '-TestLocalAppData', $Case.LocalAppData, '-TestNodeVersion', '24.21.0',
        '-TestFailurePoint', $FailurePoint
    )
    $PreviousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $WindowsPowerShell @Arguments *> $null
        return $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $PreviousPreference }
}

function Add-IncompleteInnoRegistration {
    param($Case, [switch]$Conflicting)
    $Key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($Case.UninstallRegistryRelativePath, $true)
    try {
        $Key.SetValue('DisplayName', $(if ($Conflicting) { 'Unrelated Application' } else { 'WebP Folder Converter 1.1.0' }))
        $Key.SetValue('DisplayVersion', '1.1.0')
        $Key.SetValue('InstallLocation', $Case.InstallDir)
        $Key.SetValue('UninstallString', ('"{0}"' -f (Join-Path $Case.InstallDir 'unins000.exe')))
    }
    finally { $Key.Dispose() }
}

function Set-V11Fixture {
    param($Case, [switch]$CompleteRegistration)
    Write-Utf8File -Path (Join-Path $Case.InstallDir 'package.json') -Content '{"name":"webp-folder-converter","version":"1.1.0"}'
    Write-Utf8File -Path (Join-Path $Case.InstallDir 'invoke.ps1') -Content 'v1.1-invoke'
    Write-Utf8File -Path (Join-Path $Case.InstallDir 'unins000.exe') -Content 'test-uninstaller'
    $Listed = @('package.json', 'invoke.ps1')
    $Files = foreach ($RelativePath in $Listed) {
        [ordered]@{ path = $RelativePath; sha256 = Get-Sha256 -Path (Join-Path $Case.InstallDir $RelativePath) }
    }
    [ordered]@{ version = '1.1.0'; files = @($Files) } | ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath (Join-Path $Case.InstallDir 'release-manifest.json') -Encoding UTF8
    Set-ContextMenu -Case $Case -V11
    if ($CompleteRegistration) { Add-IncompleteInnoRegistration -Case $Case }
}

function Assert-LegacyRestored {
    param($Case)
    $Package = Get-Content -LiteralPath (Join-Path $Case.InstallDir 'package.json') -Raw | ConvertFrom-Json
    Assert-True ($Package.version -eq '1.0.0') "$($Case.Name): v1.0.0が復元されていません。"
    Assert-True (-not (Test-Path -LiteralPath $Case.StatePath)) "$($Case.Name): 状態ファイルが残っています。"
    Assert-True (-not (Test-Path -LiteralPath $Case.BackupDir)) "$($Case.Name): バックアップが残っています。"
}

function Run-Case {
    param([string]$Name, [scriptblock]$Body)
    & $Body
    Write-Host "PASS: $Name"
}

try {
    New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null

    Run-Case '正常更新' {
        $Case = New-TestCase 'normal'
        Assert-True ((Invoke-Migration $Case 'Prepare') -eq 10) 'Prepareが移行を開始しませんでした。'
        Set-V11Fixture -Case $Case -CompleteRegistration
        Assert-True ((Invoke-Migration $Case 'Commit') -eq 0) 'Commitに失敗しました。'
        Assert-True (-not (Test-Path $Case.StatePath)) 'Commit後に状態ファイルが残っています。'
        Assert-True (-not (Test-Path $Case.BackupDir)) 'Commit後にバックアップが残っています。'
        Assert-True (-not (Test-Path (Join-Path $Case.InstallDir 'uninstall.ps1'))) '旧uninstall.ps1が残っています。'
    }

    Run-Case 'バックアップ中の中断と再実行' {
        foreach ($Point in @('AfterBackupState', 'AfterBackupCopy')) {
            $Case = New-TestCase "backup-$Point"
            Assert-True ((Invoke-Migration $Case 'Prepare' $Point) -eq 20) "$Point が失敗扱いになりませんでした。"
            Assert-True ((Invoke-Migration $Case 'Recover') -eq 0) "$Point の復旧に失敗しました。"
            Assert-LegacyRestored $Case
        }
    }

    Run-Case '準備後の中断とInno登録残存' {
        $Case = New-TestCase 'prepared'
        Assert-True ((Invoke-Migration $Case 'Prepare') -eq 10) 'Prepareに失敗しました。'
        Set-V11Fixture -Case $Case
        Add-IncompleteInnoRegistration -Case $Case
        Assert-True ((Invoke-Migration $Case 'Recover') -eq 0) '準備後の復旧に失敗しました。'
        Assert-LegacyRestored $Case
        Assert-True ($null -eq [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Case.UninstallRegistryRelativePath)) '残存Inno登録が削除されていません。'
    }

    Run-Case '復元途中の再中断と再実行' {
        $Case = New-TestCase 'restore-interrupted'
        Assert-True ((Invoke-Migration $Case 'Prepare') -eq 10) 'Prepareに失敗しました。'
        Set-V11Fixture -Case $Case
        Assert-True ((Invoke-Migration $Case 'Restore' 'AfterFilesRestored') -eq 20) '復元途中の中断を再現できませんでした。'
        Assert-True (-not (Test-Path $Case.BackupDir)) 'バックアップが移動済みになっていません。'
        Assert-True ((Invoke-Migration $Case 'Recover') -eq 0) '復元の再実行に失敗しました。'
        Assert-LegacyRestored $Case
    }

    Run-Case 'バックアップ欠損と破損は安全停止' {
        $Missing = New-TestCase 'backup-missing'
        Assert-True ((Invoke-Migration $Missing 'Prepare') -eq 10) 'Prepareに失敗しました。'
        Remove-Item -LiteralPath $Missing.BackupDir -Recurse -Force
        Set-V11Fixture -Case $Missing
        Assert-True ((Invoke-Migration $Missing 'Recover') -eq 20) 'バックアップ欠損を拒否しませんでした。'
        Assert-True (Test-Path $Missing.StatePath) '診断用状態ファイルが失われました。'

        $Corrupt = New-TestCase 'backup-corrupt'
        Assert-True ((Invoke-Migration $Corrupt 'Prepare') -eq 10) 'Prepareに失敗しました。'
        Write-Utf8File -Path (Join-Path $Corrupt.BackupDir 'invoke.ps1') -Content 'corrupt'
        Set-V11Fixture -Case $Corrupt
        Assert-True ((Invoke-Migration $Corrupt 'Recover') -eq 20) '破損バックアップを拒否しませんでした。'
        Assert-True (Test-Path $Corrupt.BackupDir) '破損バックアップを削除してしまいました。'
    }

    Run-Case 'レジストリ復元失敗と再実行' {
        $Case = New-TestCase 'registry-retry'
        Assert-True ((Invoke-Migration $Case 'Prepare') -eq 10) 'Prepareに失敗しました。'
        Set-V11Fixture -Case $Case
        Add-IncompleteInnoRegistration -Case $Case
        Assert-True ((Invoke-Migration $Case 'Restore' 'BeforeRegistryRestore') -eq 20) 'レジストリ障害を再現できませんでした。'
        Assert-True ((Invoke-Migration $Case 'Recover') -eq 0) 'レジストリ復元の再実行に失敗しました。'
        Assert-LegacyRestored $Case
    }

    Run-Case '無関係なアンインストール登録は削除しない' {
        $Case = New-TestCase 'conflicting-registration'
        Assert-True ((Invoke-Migration $Case 'Prepare') -eq 10) 'Prepareに失敗しました。'
        Set-V11Fixture -Case $Case
        Add-IncompleteInnoRegistration -Case $Case -Conflicting
        Assert-True ((Invoke-Migration $Case 'Recover') -eq 20) '無関係な登録を拒否しませんでした。'
        Assert-True ($null -ne [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Case.UninstallRegistryRelativePath)) '無関係な登録を削除しました。'
    }

    Run-Case '改変されたv1.0.0とNode不一致を拒否' {
        $Modified = New-TestCase 'modified-v1'
        Write-Utf8File -Path (Join-Path $Modified.InstallDir 'invoke.ps1') -Content 'modified'
        Assert-True ((Invoke-Migration $Modified 'Prepare') -eq 20) '改変ファイルを拒否しませんでした。'
        Assert-True (-not (Test-Path $Modified.BackupDir)) '改変ファイルをバックアップ対象にしました。'

        $NodeMismatch = New-TestCase 'node-mismatch'
        $Arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MigrationScript, '-Action', 'Prepare',
            '-InstallDir', $NodeMismatch.InstallDir, '-BackupDir', $NodeMismatch.BackupDir, '-StatePath', $NodeMismatch.StatePath,
            '-UninstallRegistryPath', $NodeMismatch.UninstallRegistryPath, '-TrustedManifestPath', $NodeMismatch.ManifestPath,
            '-ContextRegistryPath', $NodeMismatch.ContextRegistryPath, '-TestMode', '-TestLocalAppData', $NodeMismatch.LocalAppData,
            '-TestNodeVersion', '99.0.0')
        $PreviousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & $WindowsPowerShell @Arguments *> $null
            $ExitCode = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $PreviousPreference }
        Assert-True ($ExitCode -eq 20) 'Node.jsバージョン不一致を拒否しませんでした。'
    }
}
finally {
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($RegistryTestRoot, $false)
    $TestParentKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegistryTestParent, $false)
    if ($null -ne $TestParentKey) {
        try { $RemoveTestParent = $TestParentKey.SubKeyCount -eq 0 -and $TestParentKey.ValueCount -eq 0 }
        finally { $TestParentKey.Dispose() }
        if ($RemoveTestParent) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($RegistryTestParent, $false) }
    }
    $ProductTestKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\WebPFolderConverter', $false)
    if ($null -ne $ProductTestKey) {
        try { $RemoveProductTestKey = $ProductTestKey.SubKeyCount -eq 0 -and $ProductTestKey.ValueCount -eq 0 }
        finally { $ProductTestKey.Dispose() }
        if ($RemoveProductTestKey) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey('Software\WebPFolderConverter', $false) }
    }
    if (Test-Path -LiteralPath $TestRoot) { Remove-Item -LiteralPath $TestRoot -Recurse -Force }
}
