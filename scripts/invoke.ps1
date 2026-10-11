[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$FolderPath
)

$ErrorActionPreference = 'Stop'
$NodePath = Join-Path $PSScriptRoot 'runtime\node.exe'
$CliPath = Join-Path $PSScriptRoot 'src\convert-webp.mjs'
$ResultPath = Join-Path ([IO.Path]::GetTempPath()) ("webp-folder-converter-{0}.json" -f [Guid]::NewGuid().ToString('N'))
$ExitCode = 1

function Format-FileSize {
    param([double]$Bytes)
    $Units = @('B', 'KB', 'MB', 'GB', 'TB')
    $Index = 0
    $Value = [Math]::Abs($Bytes)
    while ($Value -ge 1024 -and $Index -lt ($Units.Count - 1)) {
        $Value = $Value / 1024
        $Index++
    }
    $Prefix = if ($Bytes -lt 0) { '-' } else { '' }
    if ($Index -eq 0) { return ('{0}{1:0} {2}' -f $Prefix, $Value, $Units[$Index]) }
    return ('{0}{1:0.##} {2}' -f $Prefix, $Value, $Units[$Index])
}

function Show-ResultDialog {
    param(
        [string]$Message,
        [bool]$HasError
    )
    Add-Type -AssemblyName System.Windows.Forms
    $Icon = if ($HasError) {
        [System.Windows.Forms.MessageBoxIcon]::Warning
    } else {
        [System.Windows.Forms.MessageBoxIcon]::Information
    }
    [void][System.Windows.Forms.MessageBox]::Show(
        $Message,
        'WebP Folder Converter',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        $Icon
    )
}

try {
    if (-not (Test-Path -LiteralPath $NodePath -PathType Leaf)) {
        throw "同梱Node.jsが見つかりません: $NodePath"
    }
    if (-not (Test-Path -LiteralPath $CliPath -PathType Leaf)) {
        throw "変換プログラムが見つかりません: $CliPath"
    }

    $NodeArguments = @($CliPath, '--folder', $FolderPath, '--json-result', $ResultPath)
    & $NodePath $NodeArguments
    $ExitCode = $LASTEXITCODE

    if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        throw "変換結果を読み取れませんでした。コンソールのエラーを確認してください。"
    }

    $Result = Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $Rate = if ($null -eq $Result.sizeSummary.reductionRate) {
        '-'
    } else {
        '{0:0.0}%' -f [double]$Result.sizeSummary.reductionRate
    }
    $Heading = if ([int]$Result.exitCode -eq 1) { 'WebP変換を完了できませんでした。' } else { 'WebP変換が完了しました。' }
    $Lines = @(
        $Heading,
        "対象: $($Result.targetCount)",
        "成功: $($Result.convertedCount)",
        "既存のためスキップ: $($Result.skippedExistingCount)",
        "名前競合のためスキップ: $($Result.skippedConflictCount)",
        "失敗: $($Result.failedCount)",
        "変換前容量（成功分）: $(Format-FileSize ([double]$Result.sizeSummary.inputBytes))",
        "変換後容量（成功分）: $(Format-FileSize ([double]$Result.sizeSummary.outputBytes))",
        "削減率（成功分合計）: $Rate",
        ('所要時間: {0:0.00} 秒' -f ([double]$Result.durationMs / 1000)),
        "ログ: $($Result.logPath)"
    )
    if ($null -ne $Result.fatalError) {
        $Lines += "原因: $($Result.fatalError.message)"
    }
    Show-ResultDialog -Message ($Lines -join [Environment]::NewLine) -HasError ([int]$Result.exitCode -ne 0)
}
catch {
    Write-Error $_
    try {
        Show-ResultDialog -Message ("WebP変換を開始または完了できませんでした。`r`n`r`n$($_.Exception.Message)") -HasError $true
    }
    catch {
        # The console error remains available if a GUI dialog cannot be shown.
    }
    $ExitCode = 1
}
finally {
    Remove-Item -LiteralPath $ResultPath -Force -ErrorAction SilentlyContinue
}

exit $ExitCode
