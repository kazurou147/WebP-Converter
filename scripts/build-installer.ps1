[CmdletBinding()]
param(
    [string]$NodeVersion = '24.21.0',
    [string]$IsccPath
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$PackagePath = Join-Path $ProjectRoot 'package.json'
$Package = Get-Content -LiteralPath $PackagePath -Raw -Encoding UTF8 | ConvertFrom-Json
$AppVersion = [string]$Package.version
$ExpectedName = "WebP-Converter-Setup-$AppVersion.exe"
$InstallerSource = Join-Path $ProjectRoot 'installer\WebPFolderConverter.iss'
$PayloadRoot = Join-Path $ProjectRoot 'dist\WebPFolderConverter'
$OutputRoot = Join-Path $ProjectRoot 'dist\installer'

function Resolve-IsccPath {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        $Resolved = [IO.Path]::GetFullPath($RequestedPath)
        if (-not (Test-Path -LiteralPath $Resolved -PathType Leaf)) {
            throw "指定されたISCC.exeが見つかりません: $Resolved"
        }
        return $Resolved
    }

    $Command = Get-Command iscc.exe -ErrorAction SilentlyContinue
    if ($Command) { return $Command.Source }

    $Candidates = @(@(
            (Join-Path $env:ProgramFiles 'Inno Setup 7\ISCC.exe'),
            (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 7\ISCC.exe'),
            (Join-Path $env:USERPROFILE 'AppData\Local\Programs\Inno Setup 7\ISCC.exe')
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($Candidates.Count -gt 0) { return $Candidates[0] }

    throw (@(
        'Inno Setup 7.1.0 64-bitのISCC.exeが見つかりません。',
        '先にInno Setup 7.1.0 64-bitを導入するか、-IsccPathでISCC.exeを指定してください。',
        'ペイロードや既存のdist出力は変更していません。'
    ) -join [Environment]::NewLine)
}

$Compiler = Resolve-IsccPath -RequestedPath $IsccPath
$CompilerVersion = (& $Compiler --version | Select-Object -First 1).Trim()
if (($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) -or
    -not $CompilerVersion.StartsWith('7.1.0', [StringComparison]::OrdinalIgnoreCase)) {
    throw "再現ビルドにはInno Setup 7.1.0が必要です。検出バージョン: $CompilerVersion ($Compiler)"
}

& (Join-Path $PSScriptRoot 'build-release.ps1') -NodeVersion $NodeVersion
if ($LASTEXITCODE -ne 0) { throw 'リリースペイロードの作成に失敗しました。' }

$ManifestPath = Join-Path $PayloadRoot 'release-manifest.json'
$Manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$Manifest.version -ne $AppVersion) {
    throw "リリースマニフェストのバージョンが一致しません: $($Manifest.version)"
}

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$OutputPath = Join-Path $OutputRoot $ExpectedName
$ChecksumPath = "$OutputPath.sha256"
foreach ($Path in @($OutputPath, $ChecksumPath)) {
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
}

& $Compiler "/DAppVersion=$AppVersion" "/DSourceRoot=$PayloadRoot" "/DOutputDir=$OutputRoot" $InstallerSource
if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw 'Inno Setupによるコンパイルに失敗しました。' }
if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
    throw "期待するインストーラーが生成されませんでした: $OutputPath"
}

$VersionInfo = (Get-Item -LiteralPath $OutputPath).VersionInfo
if (-not $VersionInfo.FileVersion.StartsWith($AppVersion, [StringComparison]::OrdinalIgnoreCase)) {
    throw "インストーラーのファイルバージョンが一致しません: $($VersionInfo.FileVersion)"
}
$Signature = Get-AuthenticodeSignature -LiteralPath $OutputPath
if ($Signature.Status -ne [System.Management.Automation.SignatureStatus]::NotSigned) {
    throw "v1.1.0は未署名配布の想定ですが、署名状態が異なります: $($Signature.Status)"
}

$Hash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath $ChecksumPath -Value ("{0}  {1}" -f $Hash, $ExpectedName) -Encoding ascii
Write-Host "インストーラー: $OutputPath"
Write-Host "SHA-256:       $Hash"
Write-Host "チェックサム:   $ChecksumPath"
