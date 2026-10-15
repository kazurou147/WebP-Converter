[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Prepare', 'Commit', 'Restore', 'Recover')]
    [string]$Action,
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [Parameter(Mandatory = $true)][string]$BackupDir,
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][string]$UninstallRegistryPath,
    [Parameter(Mandatory = $true)][string]$TrustedManifestPath,
    [string]$ContextRegistryPath = 'Software\Classes\Directory\shell\WebPFolderConverter',
    [switch]$TestMode,
    [string]$TestLocalAppData,
    [string]$TestNodeVersion,
    [ValidateSet('None', 'AfterBackupState', 'AfterBackupCopy', 'AfterFilesRestored', 'BeforeRegistryRestore')]
    [string]$TestFailurePoint = 'None'
)

$ErrorActionPreference = 'Stop'
$ProductName = 'WebP Folder Converter'
$ExpectedVersion = '1.1.0'
$ExpectedAppId = '{A39D662A-4554-4EF0-9E11-541FFAD70C43}_is1'
$RegistryCommandPath = "$ContextRegistryPath\command"
$InstallDir = [IO.Path]::GetFullPath($InstallDir)
$BackupDir = [IO.Path]::GetFullPath($BackupDir)
$StatePath = [IO.Path]::GetFullPath($StatePath)
$TrustedManifestPath = [IO.Path]::GetFullPath($TrustedManifestPath)

if ($TestMode) {
    if ([string]::IsNullOrWhiteSpace($TestLocalAppData)) { throw 'TestModeにはTestLocalAppDataが必要です。' }
    $LocalAppData = [IO.Path]::GetFullPath($TestLocalAppData)
    if (-not $ContextRegistryPath.StartsWith('Software\WebPFolderConverter\MigrationTests\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'TestModeのレジストリキーが隔離されたテスト領域ではありません。'
    }
    if (-not $UninstallRegistryPath.StartsWith('Registry::HKEY_CURRENT_USER\Software\WebPFolderConverter\MigrationTests\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'TestModeのアンインストールキーが隔離されたテスト領域ではありません。'
    }
} else {
    $LocalAppData = [Environment]::GetFolderPath('LocalApplicationData')
    $ExpectedContextRegistryPath = 'Software\Classes\Directory\shell\WebPFolderConverter'
    $ExpectedUninstallRegistryPath = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\$ExpectedAppId"
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($ContextRegistryPath, $ExpectedContextRegistryPath)) {
        throw '製品の右クリックメニューキー以外は操作できません。'
    }
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($UninstallRegistryPath, $ExpectedUninstallRegistryPath)) {
        throw '製品のアンインストールキー以外は操作できません。'
    }
}

$ProgramsRoot = [IO.Path]::GetFullPath((Join-Path $LocalAppData 'Programs'))
$ExpectedInstallDir = [IO.Path]::GetFullPath((Join-Path $ProgramsRoot 'WebPFolderConverter'))
$ExpectedBackupDir = [IO.Path]::GetFullPath((Join-Path $ProgramsRoot '.WebPFolderConverter.v1.0.0-backup'))
$ExpectedStatePath = [IO.Path]::GetFullPath((Join-Path $ProgramsRoot '.WebPFolderConverter.migration.json'))
$UninstallRegistryPrefix = 'Registry::HKEY_CURRENT_USER\'
if (-not $UninstallRegistryPath.StartsWith($UninstallRegistryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'HKCU以外のアンインストールキーは操作できません。'
}
$UninstallRegistryRelativePath = $UninstallRegistryPath.Substring($UninstallRegistryPrefix.Length)

function Assert-ExactPath {
    param([string]$Actual, [string]$Expected, [string]$Label)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($Actual), [IO.Path]::GetFullPath($Expected))) {
        throw "$Label の安全確認に失敗しました: $Actual"
    }
}

Assert-ExactPath -Actual $InstallDir -Expected $ExpectedInstallDir -Label 'インストール先'
Assert-ExactPath -Actual $BackupDir -Expected $ExpectedBackupDir -Label 'バックアップ先'
Assert-ExactPath -Actual $StatePath -Expected $ExpectedStatePath -Label '移行状態の保存先'

function Get-Sha256 {
    param([string]$Path)
    $Stream = [IO.File]::OpenRead($Path)
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($Hasher.ComputeHash($Stream))).Replace('-', '').ToLowerInvariant() }
    finally { $Hasher.Dispose(); $Stream.Dispose() }
}

if (-not (Test-Path -LiteralPath $TrustedManifestPath -PathType Leaf)) {
    throw "v1.0.0の信頼済みマニフェストが見つかりません: $TrustedManifestPath"
}
$TrustedManifestHash = Get-Sha256 -Path $TrustedManifestPath
$TrustedManifest = Get-Content -LiteralPath $TrustedManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$TrustedManifest.schemaVersion -ne 1 -or [string]$TrustedManifest.version -ne '1.0.0' -or
    [string]$TrustedManifest.target -ne 'win32-x64' -or [string]$TrustedManifest.nodeVersion -ne '24.21.0' -or
    [string]$TrustedManifest.sharpVersion -ne '0.35.5') {
    throw 'v1.0.0の信頼済みマニフェストの内容が不正です。'
}

function Invoke-TestFailure {
    param([string]$Point)
    if ($TestMode -and $TestFailurePoint -eq $Point) { throw "テスト用障害: $Point" }
}

function Get-RegistrySnapshot {
    $Base = [Microsoft.Win32.Registry]::CurrentUser
    $Verb = $Base.OpenSubKey($ContextRegistryPath, $false)
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
    $Base.DeleteSubKeyTree($ContextRegistryPath, $false)
    if (-not $Snapshot.exists) { return }
    $Verb = $Base.CreateSubKey($ContextRegistryPath, $true)
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

function Get-UninstallRegistration {
    $Key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($UninstallRegistryRelativePath, $false)
    if ($null -eq $Key) { return $null }
    try {
        return [ordered]@{
            displayName = [string]$Key.GetValue('DisplayName')
            displayVersion = [string]$Key.GetValue('DisplayVersion')
            installLocation = [string]$Key.GetValue('InstallLocation')
            uninstallString = [string]$Key.GetValue('UninstallString')
        }
    }
    finally { $Key.Dispose() }
}

function Remove-IncompleteUninstallRegistration {
    param($State)
    if ([bool]$State.innoRegistrationExistedBefore) { throw '移行前から存在したアンインストール登録は自動削除しません。' }
    $Registration = Get-UninstallRegistration
    if ($null -eq $Registration) { return }
    if ($Registration.displayName -and $Registration.displayName -notin @($ProductName, "$ProductName $ExpectedVersion")) {
        throw '残存したアンインストール登録が本製品のものと確認できないため、自動削除しません。'
    }
    if ($Registration.displayVersion -and $Registration.displayVersion -ne $ExpectedVersion) {
        throw '残存したアンインストール登録のバージョンが一致しないため、自動削除しません。'
    }
    if ($Registration.installLocation -and
        -not [StringComparer]::OrdinalIgnoreCase.Equals($Registration.installLocation.TrimEnd('\'), $InstallDir.TrimEnd('\'))) {
        throw '残存したアンインストール登録のインストール先が一致しないため、自動削除しません。'
    }
    if ($Registration.uninstallString -and
        $Registration.uninstallString.IndexOf($InstallDir, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw '残存したアンインストール登録のコマンドが本製品を指していないため、自動削除しません。'
    }
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($UninstallRegistryRelativePath, $false)
}

function Assert-TrustedLegacyInstall {
    param([string]$Root)
    $Root = [IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "v1.0.0のフォルダが見つかりません: $Root" }
    $ExpectedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($File in $TrustedManifest.files) {
        $RelativePath = ([string]$File.path).Replace('/', '\')
        if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains('..')) {
            throw "信頼済みマニフェストに不正なパスがあります: $RelativePath"
        }
        [void]$ExpectedPaths.Add($RelativePath)
        $FilePath = Join-Path $Root $RelativePath
        if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { throw "v1.0.0の必須ファイルが不足しています: $RelativePath" }
        $ActualHash = Get-Sha256 -Path $FilePath
        if ($ActualHash -ne ([string]$File.sha256).ToLowerInvariant()) {
            throw "v1.0.0のファイル内容が公開版と一致しません: $RelativePath"
        }
    }
    $ActualPaths = @(Get-ChildItem -LiteralPath $Root -File -Recurse | ForEach-Object { $_.FullName.Substring($Root.Length + 1) })
    foreach ($RelativePath in $ActualPaths) {
        if (-not $ExpectedPaths.Contains($RelativePath)) { throw "v1.0.0のフォルダに公開版にないファイルがあります: $RelativePath" }
    }
    if ($ActualPaths.Count -ne $ExpectedPaths.Count) { throw 'v1.0.0のファイル数が公開版と一致しません。' }
    $NodeVersion = if ($TestMode -and $TestNodeVersion) { $TestNodeVersion } else {
        (& (Join-Path $Root 'runtime\node.exe') --version | Select-Object -First 1).Trim().TrimStart('v')
    }
    if ($NodeVersion.TrimStart('v') -ne [string]$TrustedManifest.nodeVersion) {
        throw "同梱Node.jsのバージョンが一致しません: $NodeVersion"
    }
}

function Test-TrustedLegacyInstall {
    param([string]$Root)
    try { Assert-TrustedLegacyInstall -Root $Root; return $true } catch { return $false }
}

function Assert-LegacyRegistry {
    $Snapshot = Get-RegistrySnapshot
    $ExpectedCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" "%1"' -f (Join-Path $InstallDir 'invoke.ps1')
    $ExpectedIcon = Join-Path $InstallDir 'runtime\node.exe'
    if (-not $Snapshot.exists -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$Snapshot.defaultValue, 'WebPに変換') -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$Snapshot.muiVerb, 'WebPに変換') -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$Snapshot.icon, $ExpectedIcon) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$Snapshot.command, $ExpectedCommand)) {
        throw '既存の右クリックメニューが正規のv1.0.0登録と一致しません。'
    }
    return $Snapshot
}

function Assert-CompleteV11Install {
    if (-not (Test-Path -LiteralPath $InstallDir -PathType Container)) { throw 'Inno Setupの登録はありますが、アプリ本体が見つかりません。' }
    $PackagePath = Join-Path $InstallDir 'package.json'
    $ManifestPath = Join-Path $InstallDir 'release-manifest.json'
    if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf) -or -not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw 'v1.1.0のパッケージ情報または配布マニフェストがありません。'
    }
    $Package = Get-Content -LiteralPath $PackagePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$Package.name -ne 'webp-folder-converter' -or [string]$Package.version -ne $ExpectedVersion -or
        [string]$Manifest.version -ne $ExpectedVersion) { throw '既存のInno Setup管理インストールをv1.1.0として確認できません。' }
    foreach ($File in $Manifest.files) {
        $ManifestPath = ([string]$File.path).Replace('\', '/')
        $InstalledPath = if ($ManifestPath -in @('package.json', 'package-lock.json', 'README.md', 'LICENSE', 'THIRD-PARTY-NOTICES.txt')) {
            $ManifestPath
        } elseif ($ManifestPath -match '^(runtime|src|node_modules|licenses)/') {
            $ManifestPath
        } elseif ($ManifestPath -eq 'scripts/invoke.ps1') {
            'invoke.ps1'
        } else {
            $null
        }
        if ($null -eq $InstalledPath) { continue }
        $FilePath = Join-Path $InstallDir $InstalledPath.Replace('/', '\')
        if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) { throw "v1.1.0のファイルが不足しています: $($File.path)" }
        if ((Get-Sha256 -Path $FilePath) -ne ([string]$File.sha256).ToLowerInvariant()) {
            throw "v1.1.0のファイル内容が一致しません: $($File.path)"
        }
    }
    $Registration = Get-UninstallRegistration
    if ($null -eq $Registration -or $Registration.displayName -notin @($ProductName, "$ProductName $ExpectedVersion") -or
        $Registration.displayVersion -ne $ExpectedVersion -or -not $Registration.uninstallString -or
        $Registration.uninstallString.IndexOf($InstallDir, [StringComparison]::OrdinalIgnoreCase) -lt 0 -or
        ($Registration.installLocation -and
            -not [StringComparer]::OrdinalIgnoreCase.Equals($Registration.installLocation.TrimEnd('\'), $InstallDir.TrimEnd('\')))) {
        throw 'v1.1.0のアンインストール登録が完全ではありません。'
    }
    $Snapshot = Get-RegistrySnapshot
    $ExpectedPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $ExpectedCommand = '"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" "%1"' -f $ExpectedPowerShell, (Join-Path $InstallDir 'invoke.ps1')
    if (-not $Snapshot.exists -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$Snapshot.muiVerb, 'WebPに変換') -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$Snapshot.icon, (Join-Path $InstallDir 'runtime\node.exe')) -or
        -not [StringComparer]::OrdinalIgnoreCase.Equals([string]$Snapshot.command, $ExpectedCommand)) {
        throw 'v1.1.0の右クリックメニュー登録が完全ではありません。'
    }
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return $null }
    $State = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$State.schemaVersion -ne 2) { throw '未対応の移行状態ファイルです。' }
    Assert-ExactPath -Actual ([string]$State.installDir) -Expected $InstallDir -Label '状態ファイル内のインストール先'
    Assert-ExactPath -Actual ([string]$State.backupDir) -Expected $BackupDir -Label '状態ファイル内のバックアップ先'
    if ([string]$State.trustedManifestSha256 -ne $TrustedManifestHash) { throw '移行状態とv1.0.0信頼済みマニフェストが一致しません。' }
    return $State
}

function Write-State {
    param($State)
    $TemporaryState = "$StatePath.tmp"
    $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $TemporaryState -Encoding UTF8
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
    if ([string]$State.phase -notin @('restoring-files', 'restoring-registry', 'restored')) {
        $State.phase = 'restoring-files'; Write-State -State $State
    }
    if ([string]$State.phase -eq 'restoring-files') {
        if (Test-Path -LiteralPath $BackupDir -PathType Container) {
            Assert-TrustedLegacyInstall -Root $BackupDir
            if (Test-Path -LiteralPath $InstallDir) {
                Assert-ExactPath -Actual $InstallDir -Expected $ExpectedInstallDir -Label '復旧時に置換するインストール先'
                Remove-Item -LiteralPath $InstallDir -Recurse -Force
            }
            Move-Item -LiteralPath $BackupDir -Destination $InstallDir
        } elseif (-not (Test-TrustedLegacyInstall -Root $InstallDir)) {
            throw '復旧バックアップが見つからず、インストール先も正規のv1.0.0ではありません。手動復旧手順を参照してください。'
        }
        Assert-TrustedLegacyInstall -Root $InstallDir
        $State.phase = 'restoring-registry'; Write-State -State $State
        Invoke-TestFailure -Point 'AfterFilesRestored'
    }
    if ([string]$State.phase -eq 'restoring-registry') {
        Assert-TrustedLegacyInstall -Root $InstallDir
        Remove-IncompleteUninstallRegistration -State $State
        Invoke-TestFailure -Point 'BeforeRegistryRestore'
        Restore-RegistrySnapshot -Snapshot $State.registry
        $State.phase = 'restored'; Write-State -State $State
    }
    if ([string]$State.phase -eq 'restored') {
        Assert-TrustedLegacyInstall -Root $InstallDir
        Remove-Item -LiteralPath $StatePath -Force
    }
}

function Resolve-InterruptedMigration {
    $State = Read-State
    if ($null -eq $State) {
        if (Test-Path -LiteralPath $BackupDir) { throw "状態ファイルのない移行バックアップがあります。自動削除せず停止します: $BackupDir" }
        return
    }
    switch ([string]$State.phase) {
        'backing-up' { Assert-TrustedLegacyInstall -Root $InstallDir; Remove-Backup; Remove-Item -LiteralPath $StatePath -Force }
        'prepared' { Restore-LegacyInstall -State $State }
        'restoring-files' { Restore-LegacyInstall -State $State }
        'restoring-registry' { Restore-LegacyInstall -State $State }
        'restored' { Restore-LegacyInstall -State $State }
        'committed' { Assert-CompleteV11Install; Remove-Backup; Remove-Item -LiteralPath $StatePath -Force }
        default { throw "不明な移行状態です: $($State.phase)" }
    }
}

try {
    switch ($Action) {
        'Recover' { Resolve-InterruptedMigration; exit 0 }
        'Prepare' {
            Resolve-InterruptedMigration
            $HasInstall = Test-Path -LiteralPath $InstallDir -PathType Container
            $HasContextMenu = (Get-RegistrySnapshot).exists
            $Registration = Get-UninstallRegistration
            if ($null -ne $Registration) { Assert-CompleteV11Install; exit 0 }
            if (-not $HasInstall -and -not $HasContextMenu) { exit 0 }
            if (-not $HasInstall -or -not $HasContextMenu) { throw 'アプリ本体と右クリックメニューの片方だけが存在します。安全のため自動修復しません。' }
            Assert-TrustedLegacyInstall -Root $InstallDir
            $Snapshot = Assert-LegacyRegistry
            $State = [ordered]@{
                schemaVersion = 2; phase = 'backing-up'; installDir = $InstallDir; backupDir = $BackupDir
                createdAt = [DateTime]::UtcNow.ToString('o'); trustedManifestSha256 = $TrustedManifestHash
                innoRegistrationExistedBefore = $false; registry = $Snapshot
            }
            Write-State -State $State
            Invoke-TestFailure -Point 'AfterBackupState'
            Copy-Item -LiteralPath $InstallDir -Destination $BackupDir -Recurse
            Assert-TrustedLegacyInstall -Root $BackupDir
            Invoke-TestFailure -Point 'AfterBackupCopy'
            $State.phase = 'prepared'; Write-State -State $State
            exit 10
        }
        'Commit' {
            $State = Read-State
            if ($null -eq $State) { exit 0 }
            if ([string]$State.phase -ne 'prepared') { throw "確定できない移行状態です: $($State.phase)" }
            Assert-CompleteV11Install
            $State.phase = 'committed'; Write-State -State $State
            Remove-Item -LiteralPath (Join-Path $InstallDir 'uninstall.ps1') -Force -ErrorAction SilentlyContinue
            Remove-Backup
            Remove-Item -LiteralPath $StatePath -Force
            exit 0
        }
        'Restore' {
            $State = Read-State
            if ($null -eq $State) { exit 0 }
            if ([string]$State.phase -eq 'backing-up') {
                Assert-TrustedLegacyInstall -Root $InstallDir; Remove-Backup; Remove-Item -LiteralPath $StatePath -Force
            } else { Restore-LegacyInstall -State $State }
            exit 0
        }
    }
}
catch {
    Write-Error ("{0}{1}自動処理を続行しません。現在のファイル、バックアップ、状態ファイルを保持し、docs\05_v1.1.0_インストーラー実機確認.mdの手動復旧手順を参照してください。" -f $_, [Environment]::NewLine) -ErrorAction Continue
    exit 20
}
