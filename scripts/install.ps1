[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProductName = 'WebPFolderConverter'
$SourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$ManifestPath = Join-Path $SourceRoot 'release-manifest.json'
$LocalAppData = [Environment]::GetFolderPath('LocalApplicationData')
$ProgramsRoot = Join-Path $LocalAppData 'Programs'
$InstallDir = [IO.Path]::GetFullPath((Join-Path $ProgramsRoot $ProductName))
$StageDir = [IO.Path]::GetFullPath((Join-Path $ProgramsRoot ('.{0}.stage.{1}' -f $ProductName, [Guid]::NewGuid().ToString('N'))))
$BackupDir = [IO.Path]::GetFullPath((Join-Path $ProgramsRoot ('.{0}.backup.{1}' -f $ProductName, [Guid]::NewGuid().ToString('N'))))
$RegistryPath = 'Software\Classes\Directory\shell\WebPFolderConverter'
$RegistryCommandPath = "$RegistryPath\command"
$Switched = $false
$HadExistingInstall = Test-Path -LiteralPath $InstallDir

function Assert-ExpectedPath {
    param([string]$Actual, [string]$Expected)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($Actual), [IO.Path]::GetFullPath($Expected))) {
        throw "安全確認に失敗しました。対象パスが期待値と一致しません: $Actual"
    }
}

function Get-RegistrySnapshot {
    $Base = [Microsoft.Win32.Registry]::CurrentUser
    $Verb = $Base.OpenSubKey($RegistryPath, $false)
    $Command = $Base.OpenSubKey($RegistryCommandPath, $false)
    try {
        return [pscustomobject]@{
            Exists = $null -ne $Verb
            DefaultValue = if ($null -ne $Verb) { $Verb.GetValue('') } else { $null }
            MUIVerb = if ($null -ne $Verb) { $Verb.GetValue('MUIVerb') } else { $null }
            Icon = if ($null -ne $Verb) { $Verb.GetValue('Icon') } else { $null }
            Command = if ($null -ne $Command) { $Command.GetValue('') } else { $null }
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
    if (-not $Snapshot.Exists) {
        $Base.DeleteSubKeyTree($RegistryPath, $false)
        return
    }
    $Verb = $Base.CreateSubKey($RegistryPath, $true)
    $Command = $Base.CreateSubKey($RegistryCommandPath, $true)
    try {
        $Verb.SetValue('', [string]$Snapshot.DefaultValue, [Microsoft.Win32.RegistryValueKind]::String)
        $Verb.SetValue('MUIVerb', [string]$Snapshot.MUIVerb, [Microsoft.Win32.RegistryValueKind]::String)
        $Verb.SetValue('Icon', [string]$Snapshot.Icon, [Microsoft.Win32.RegistryValueKind]::String)
        $Command.SetValue('', [string]$Snapshot.Command, [Microsoft.Win32.RegistryValueKind]::String)
    }
    finally {
        $Verb.Dispose()
        $Command.Dispose()
    }
}

if (-not [Environment]::Is64BitOperatingSystem -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw 'Windows 11 64ビット（x64）で実行してください。'
}
$Os = Get-CimInstance Win32_OperatingSystem
if ([int]$Os.BuildNumber -lt 22000) {
    throw 'このツールはWindows 11を対象としています。'
}
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "配布マニフェストが見つかりません: $ManifestPath"
}

Write-Host '配布ファイルの整合性を確認しています...'
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$ListedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($File in $Manifest.files) {
    $RelativePath = [string]$File.path
    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath.Contains('..')) {
        throw "配布マニフェストに不正なパスがあります: $RelativePath"
    }
    [void]$ListedPaths.Add($RelativePath.Replace('/', '\'))
    $FilePath = Join-Path $SourceRoot $RelativePath
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "配布ファイルが不足しています: $RelativePath"
    }
    $Hash = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Hash -ne ([string]$File.sha256).ToLowerInvariant()) {
        throw "配布ファイルの整合性確認に失敗しました: $RelativePath"
    }
}
$ActualFiles = Get-ChildItem -LiteralPath $SourceRoot -File -Recurse | ForEach-Object {
    $_.FullName.Substring($SourceRoot.Length + 1)
} | Where-Object { $_ -ne 'release-manifest.json' }
foreach ($RelativePath in $ActualFiles) {
    if (-not $ListedPaths.Contains($RelativePath)) {
        throw "マニフェストにない配布ファイルがあります: $RelativePath"
    }
}

$RegistrySnapshot = Get-RegistrySnapshot
try {
    New-Item -ItemType Directory -Path $StageDir -Force | Out-Null
    foreach ($Name in @('package.json', 'package-lock.json', 'THIRD-PARTY-NOTICES.txt')) {
        Copy-Item -LiteralPath (Join-Path $SourceRoot $Name) -Destination $StageDir
    }
    foreach ($Name in @('src', 'runtime', 'node_modules', 'licenses')) {
        Copy-Item -LiteralPath (Join-Path $SourceRoot $Name) -Destination $StageDir -Recurse
    }
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'scripts\invoke.ps1') -Destination (Join-Path $StageDir 'invoke.ps1')
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'scripts\uninstall.ps1') -Destination (Join-Path $StageDir 'uninstall.ps1')

    $StageNode = Join-Path $StageDir 'runtime\node.exe'
    Write-Host '同梱Node.jsとSharpを自己診断しています...'
    & $StageNode (Join-Path $StageDir 'src\self-check.mjs')
    if ($LASTEXITCODE -ne 0) { throw 'Sharp自己診断に失敗しました。' }

    if ($HadExistingInstall) {
        Move-Item -LiteralPath $InstallDir -Destination $BackupDir
    }
    Move-Item -LiteralPath $StageDir -Destination $InstallDir
    $Switched = $true

    $InstalledInvoke = Join-Path $InstallDir 'invoke.ps1'
    $InstalledNode = Join-Path $InstallDir 'runtime\node.exe'
    $CommandText = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" "%1"' -f $InstalledInvoke
    $Base = [Microsoft.Win32.Registry]::CurrentUser
    $Verb = $Base.CreateSubKey($RegistryPath, $true)
    $Command = $Base.CreateSubKey($RegistryCommandPath, $true)
    try {
        $Verb.SetValue('', 'WebPに変換', [Microsoft.Win32.RegistryValueKind]::String)
        $Verb.SetValue('MUIVerb', 'WebPに変換', [Microsoft.Win32.RegistryValueKind]::String)
        $Verb.SetValue('Icon', $InstalledNode, [Microsoft.Win32.RegistryValueKind]::String)
        $Command.SetValue('', $CommandText, [Microsoft.Win32.RegistryValueKind]::String)
    }
    finally {
        $Verb.Dispose()
        $Command.Dispose()
    }

    $ReadBack = Get-RegistrySnapshot
    if ($ReadBack.Command -ne $CommandText -or $ReadBack.MUIVerb -ne 'WebPに変換') {
        throw '右クリックメニュー登録の読戻し確認に失敗しました。'
    }
    if (-not (Test-Path -LiteralPath $InstalledInvoke -PathType Leaf)) {
        throw '登録した起動スクリプトが見つかりません。'
    }

    if (Test-Path -LiteralPath $BackupDir) {
        Assert-ExpectedPath $BackupDir $BackupDir
        Remove-Item -LiteralPath $BackupDir -Recurse -Force
    }
    Write-Host ''
    Write-Host 'インストールが完了しました。'
    Write-Host 'フォルダを右クリックし、「その他のオプションを確認」から「WebPに変換」を選択してください。'
}
catch {
    Restore-RegistrySnapshot $RegistrySnapshot
    if ($Switched -and (Test-Path -LiteralPath $InstallDir)) {
        Assert-ExpectedPath $InstallDir ([IO.Path]::GetFullPath((Join-Path $ProgramsRoot $ProductName)))
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
    }
    if (Test-Path -LiteralPath $BackupDir) {
        Move-Item -LiteralPath $BackupDir -Destination $InstallDir
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $StageDir) {
        Assert-ExpectedPath $StageDir $StageDir
        Remove-Item -LiteralPath $StageDir -Recurse -Force
    }
}
