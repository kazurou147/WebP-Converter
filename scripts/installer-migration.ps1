[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Prepare', 'Commit', 'Restore')]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$InstallDir,

    [Parameter(Mandatory = $true)]
    [string]$BackupDir,

    [Parameter(Mandatory = $true)]
    [string]$StatePath,

    [Parameter(Mandatory = $true)]
    [string]$UninstallRegistryPath
)

$ErrorActionPreference = 'Stop'
$RegistryPath = 'Software\Classes\Directory\shell\WebPFolderConverter'
$RegistryCommandPath = "$RegistryPath\command"
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
$BackupDir = [IO.Path]::GetFullPath($BackupDir)
$StatePath = [IO.Path]::GetFullPath($StatePath)
$ProgramsRoot = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Programs'))
$ExpectedInstallDir = [IO.Path]::GetFullPath((Join-Path $ProgramsRoot 'WebPFolderConverter'))
$ExpectedBackupDir = [IO.Path]::GetFullPath((Join-Path $ProgramsRoot '.WebPFolderConverter.v1.0.0-backup'))

function Assert-ExactPath {
    param([string]$Actual, [string]$Expected, [string]$Label)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($Actual), [IO.Path]::GetFullPath($Expected))) {
        throw "$Label の安全確認に失敗しました: $Actual"
    }
}

Assert-ExactPath -Actual $InstallDir -Expected $ExpectedInstallDir -Label 'インストール先'
Assert-ExactPath -Actual $BackupDir -Expected $ExpectedBackupDir -Label 'バックアップ先'
Assert-ExactPath -Actual (Split-Path -Parent $StatePath) -Expected $ProgramsRoot -Label '移行状態の保存先'

function Get-RegistrySnapshot {
    $Base = [Microsoft.Win32.Registry]::CurrentUser
    $Verb = $Base.OpenSubKey($RegistryPath, $false)
    $Command = $Base.OpenSubKey($RegistryCommandPath, $false)
    try {
        return [ordered]@{
            exists = $null -ne $Verb
            defaultValue = if ($null -ne $Verb) { [string]$Verb.GetValue('') } else { $null }
            muiVerb = if ($null -ne $Verb) { [string]$Verb.GetValue('MUIVerb') } else { $null }
            icon = if ($null -ne $Verb) { [string]$Verb.GetValue('Icon') } else { $null }
            command = if ($null -ne $Command) { [string]$Command.GetValue('') } else { $null }
        }
    }
    finally {
        if ($null -ne $Verb) { $Verb.Dispose() }
        if ($null -ne $Command) { $Command.Dispose() }
    }
}

function Restore-RegistrySnapshot {
    param($Snapshot)
    $Base = [Microsoft.Win32.Registry]::CurrentUser
    $Base.DeleteSubKeyTree($RegistryPath, $false)
    if (-not $Snapshot.exists) { return }

    $Verb = $Base.CreateSubKey($RegistryPath, $true)
    $Command = $Base.CreateSubKey($RegistryCommandPath, $true)
    try {
        $Verb.SetValue('', [string]$Snapshot.defaultValue, [Microsoft.Win32.RegistryValueKind]::String)
        $Verb.SetValue('MUIVerb', [string]$Snapshot.muiVerb, [Microsoft.Win32.RegistryValueKind]::String)
        $Verb.SetValue('Icon', [string]$Snapshot.icon, [Microsoft.Win32.RegistryValueKind]::String)
        $Command.SetValue('', [string]$Snapshot.command, [Microsoft.Win32.RegistryValueKind]::String)
    }
    finally {
        $Verb.Dispose()
        $Command.Dispose()
    }
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return $null }
    $State = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-ExactPath -Actual ([string]$State.installDir) -Expected $InstallDir -Label '状態ファイル内のインストール先'
    Assert-ExactPath -Actual ([string]$State.backupDir) -Expected $BackupDir -Label '状態ファイル内のバックアップ先'
    return $State
}

function Write-State {
    param($State)
    $TemporaryState = "$StatePath.tmp"
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $TemporaryState -Encoding UTF8
    Move-Item -LiteralPath $TemporaryState -Destination $StatePath -Force
}

function Remove-Backup {
    if (Test-Path -LiteralPath $BackupDir) {
        Assert-ExactPath -Actual $BackupDir -Expected $ExpectedBackupDir -Label '削除するバックアップ'
        Remove-Item -LiteralPath $BackupDir -Recurse -Force
    }
}

function Restore-LegacyInstall {
    param($State)
    if (-not (Test-Path -LiteralPath $BackupDir -PathType Container)) {
        throw "v1.0.0の復旧バックアップが見つかりません: $BackupDir"
    }
    if (Test-Path -LiteralPath $InstallDir) {
        Assert-ExactPath -Actual $InstallDir -Expected $ExpectedInstallDir -Label '復旧時に置換するインストール先'
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
    }
    Move-Item -LiteralPath $BackupDir -Destination $InstallDir
    Restore-RegistrySnapshot -Snapshot $State.registry
    Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
}

function Resolve-InterruptedMigration {
    $State = Read-State
    if ($null -eq $State) {
        if (Test-Path -LiteralPath $BackupDir) {
            throw "状態ファイルのない移行バックアップがあります。安全のため処理を中止します: $BackupDir"
        }
        return
    }

    switch ([string]$State.phase) {
        'backing-up' {
            # The original directory was only copied, never moved, in this phase.
            Remove-Backup
            Remove-Item -LiteralPath $StatePath -Force
        }
        'prepared' { Restore-LegacyInstall -State $State }
        'committed' {
            Remove-Backup
            Remove-Item -LiteralPath $StatePath -Force
        }
        default { throw "不明な移行状態です: $($State.phase)" }
    }
}

function Assert-LegacyV1Install {
    $RequiredFiles = @(
        'package.json',
        'runtime\node.exe',
        'src\converter.mjs',
        'src\convert-webp.mjs',
        'invoke.ps1',
        'uninstall.ps1'
    )
    foreach ($RelativePath in $RequiredFiles) {
        $Path = Join-Path $InstallDir $RelativePath
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "既存フォルダは正規のv1.0.0として確認できません。不足: $RelativePath"
        }
    }

    $Package = Get-Content -LiteralPath (Join-Path $InstallDir 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$Package.name -ne 'webp-folder-converter' -or [string]$Package.version -ne '1.0.0') {
        throw "既存フォルダの製品またはバージョンを確認できません: $($Package.name) $($Package.version)"
    }

    $Snapshot = Get-RegistrySnapshot
    $ExpectedCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" "%1"' -f (Join-Path $InstallDir 'invoke.ps1')
    $ExpectedIcon = Join-Path $InstallDir 'runtime\node.exe'
    if (-not $Snapshot.exists -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$Snapshot.muiVerb, 'WebPに変換') -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$Snapshot.icon, $ExpectedIcon) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$Snapshot.command, $ExpectedCommand)) {
        throw '既存の右クリックメニューが正規のv1.0.0登録と一致しません。'
    }
    return $Snapshot
}

try {
    switch ($Action) {
        'Prepare' {
            Resolve-InterruptedMigration
            $HasInstall = Test-Path -LiteralPath $InstallDir -PathType Container
            $HasContextMenu = (Get-RegistrySnapshot).exists
            $HasInnoRegistration = Test-Path -LiteralPath $UninstallRegistryPath

            if ($HasInnoRegistration) {
                if (-not $HasInstall) { throw 'Inno Setupの登録はありますが、アプリ本体が見つかりません。' }
                $Package = Get-Content -LiteralPath (Join-Path $InstallDir 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
                if ([string]$Package.name -ne 'webp-folder-converter' -or [string]$Package.version -ne '1.1.0') {
                    throw '既存のInno Setup管理インストールをv1.1.0として確認できません。'
                }
                exit 0
            }

            if (-not $HasInstall -and -not $HasContextMenu) { exit 0 }
            if (-not $HasInstall -or -not $HasContextMenu) {
                throw 'アプリ本体と右クリックメニューの片方だけが存在します。安全のため自動修復しません。'
            }

            $Snapshot = Assert-LegacyV1Install
            $State = [ordered]@{
                schemaVersion = 1
                phase = 'backing-up'
                installDir = $InstallDir
                backupDir = $BackupDir
                createdAt = [DateTime]::UtcNow.ToString('o')
                registry = $Snapshot
            }
            Write-State -State $State
            Copy-Item -LiteralPath $InstallDir -Destination $BackupDir -Recurse
            $State.phase = 'prepared'
            Write-State -State $State
            exit 10
        }
        'Commit' {
            $State = Read-State
            if ($null -eq $State) { exit 0 }
            if ([string]$State.phase -ne 'prepared') { throw "確定できない移行状態です: $($State.phase)" }
            $State.phase = 'committed'
            Write-State -State $State
            Remove-Item -LiteralPath (Join-Path $InstallDir 'uninstall.ps1') -Force -ErrorAction SilentlyContinue
            Remove-Backup
            Remove-Item -LiteralPath $StatePath -Force
            exit 0
        }
        'Restore' {
            $State = Read-State
            if ($null -eq $State) { exit 0 }
            if ([string]$State.phase -eq 'prepared') {
                Restore-LegacyInstall -State $State
            } elseif ([string]$State.phase -eq 'backing-up') {
                Remove-Backup
                Remove-Item -LiteralPath $StatePath -Force
            }
            exit 0
        }
    }
}
catch {
    Write-Error $_
    exit 20
}
