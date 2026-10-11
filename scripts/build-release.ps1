[CmdletBinding()]
param(
    [string]$NodeVersion = '24.21.0'
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$DistRoot = Join-Path $ProjectRoot 'dist'
$ReleaseRoot = Join-Path $DistRoot 'WebPFolderConverter'
$DownloadRoot = Join-Path $DistRoot '.downloads'
$NodeArchiveName = "node-v$NodeVersion-win-x64.zip"
$NodeArchive = Join-Path $DownloadRoot $NodeArchiveName
$NodeBaseUrl = "https://nodejs.org/dist/v$NodeVersion"

if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'Windows x64環境でリリースを作成してください。'
}

New-Item -ItemType Directory -Path $DistRoot -Force | Out-Null
New-Item -ItemType Directory -Path $DownloadRoot -Force | Out-Null
if (Test-Path -LiteralPath $ReleaseRoot) {
    $Expected = [IO.Path]::GetFullPath((Join-Path $DistRoot 'WebPFolderConverter'))
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($ReleaseRoot), $Expected)) {
        throw 'リリース削除対象の安全確認に失敗しました。'
    }
    Remove-Item -LiteralPath $ReleaseRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $ReleaseRoot -Force | Out-Null

Write-Host "Node.js v$NodeVersion を取得して公式SHA-256を確認しています..."
$ShasumsPath = Join-Path $DownloadRoot "SHASUMS256-v$NodeVersion.txt"
Invoke-WebRequest -UseBasicParsing -Uri "$NodeBaseUrl/SHASUMS256.txt" -OutFile $ShasumsPath
if (-not (Test-Path -LiteralPath $NodeArchive)) {
    Invoke-WebRequest -UseBasicParsing -Uri "$NodeBaseUrl/$NodeArchiveName" -OutFile $NodeArchive
}
$ExpectedLine = Get-Content -LiteralPath $ShasumsPath | Where-Object { $_ -match ([regex]::Escape($NodeArchiveName) + '$') } | Select-Object -First 1
if (-not $ExpectedLine) { throw "Node.js公式SHA-256に $NodeArchiveName がありません。" }
$ExpectedHash = ($ExpectedLine -split '\s+')[0].ToLowerInvariant()
$ActualHash = (Get-FileHash -LiteralPath $NodeArchive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ActualHash -ne $ExpectedHash) { throw 'Node.js ZIPのSHA-256が公式値と一致しません。' }

$ExtractRoot = Join-Path $DownloadRoot "node-v$NodeVersion-extracted"
if (Test-Path -LiteralPath $ExtractRoot) { Remove-Item -LiteralPath $ExtractRoot -Recurse -Force }
Expand-Archive -LiteralPath $NodeArchive -DestinationPath $ExtractRoot
$ExtractedNodeRoot = Join-Path $ExtractRoot "node-v$NodeVersion-win-x64"
$RuntimeRoot = Join-Path $ReleaseRoot 'runtime'
New-Item -ItemType Directory -Path $RuntimeRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $ExtractedNodeRoot 'node.exe') -Destination $RuntimeRoot
Copy-Item -LiteralPath (Join-Path $ExtractedNodeRoot 'LICENSE') -Destination $RuntimeRoot

foreach ($Name in @('package.json', 'package-lock.json', 'README.md', 'THIRD-PARTY-NOTICES.txt')) {
    Copy-Item -LiteralPath (Join-Path $ProjectRoot $Name) -Destination $ReleaseRoot
}
foreach ($Name in @('src', 'scripts')) {
    Copy-Item -LiteralPath (Join-Path $ProjectRoot $Name) -Destination $ReleaseRoot -Recurse
}

Push-Location $ReleaseRoot
try {
    Write-Host 'Windows x64用の本番依存を固定ロックファイルから復元しています...'
    & npm.cmd ci --omit=dev --os=win32 --cpu=x64
    if ($LASTEXITCODE -ne 0) { throw 'npm ciによる本番依存の復元に失敗しました。' }
}
finally {
    Pop-Location
}

$LicensesRoot = Join-Path $ReleaseRoot 'licenses\npm'
New-Item -ItemType Directory -Path $LicensesRoot -Force | Out-Null
$NoticeRows = @()
$PackageFiles = Get-ChildItem -LiteralPath (Join-Path $ReleaseRoot 'node_modules') -Filter package.json -File -Recurse
foreach ($PackageFile in $PackageFiles) {
    if ($PackageFile.FullName -match '\\node_modules\\[^\\]+\\node_modules\\') { continue }
    $Package = Get-Content -LiteralPath $PackageFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $Package.name -or -not $Package.version) { continue }
    $SafeName = ([string]$Package.name).Replace('@', '').Replace('/', '__')
    $Destination = Join-Path $LicensesRoot ("{0}-{1}" -f $SafeName, $Package.version)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $LicenseFile = Get-ChildItem -LiteralPath $PackageFile.DirectoryName -File | Where-Object { $_.Name -match '^(LICENSE|LICENCE|COPYING)(\..*)?$' } | Select-Object -First 1
    if ($LicenseFile) { Copy-Item -LiteralPath $LicenseFile.FullName -Destination (Join-Path $Destination $LicenseFile.Name) }
    $NoticeRows += ('- {0} {1}: {2}' -f $Package.name, $Package.version, $Package.license)
}

$NoticePath = Join-Path $ReleaseRoot 'THIRD-PARTY-NOTICES.txt'
$NoticeHeader = @(
    'WebP Folder Converter - Third-Party Notices',
    '',
    "Node.js v$NodeVersion license: runtime\LICENSE",
    'npm package license files: licenses\npm',
    '',
    'Included production packages:'
)
Set-Content -LiteralPath $NoticePath -Value ($NoticeHeader + ($NoticeRows | Sort-Object -Unique)) -Encoding UTF8

Write-Host '同梱ランタイムでSharpを自己診断しています...'
& (Join-Path $RuntimeRoot 'node.exe') (Join-Path $ReleaseRoot 'src\self-check.mjs')
if ($LASTEXITCODE -ne 0) { throw '同梱Node.jsによるSharp自己診断に失敗しました。' }

$Files = Get-ChildItem -LiteralPath $ReleaseRoot -File -Recurse | Where-Object { $_.Name -ne 'release-manifest.json' } | ForEach-Object {
    [pscustomobject]@{
        path = $_.FullName.Substring($ReleaseRoot.Length + 1).Replace('\', '/')
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
} | Sort-Object path
$Manifest = [ordered]@{
    product = 'WebP Folder Converter'
    version = '1.0.0'
    target = 'win32-x64'
    nodeVersion = $NodeVersion
    sharpVersion = '0.35.5'
    generatedAt = [DateTime]::UtcNow.ToString('o')
    manifestExcludesItself = $true
    files = @($Files)
}
$Manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ReleaseRoot 'release-manifest.json') -Encoding UTF8

Write-Host "自己完結リリースを作成しました: $ReleaseRoot"
