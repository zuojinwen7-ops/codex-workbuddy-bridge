[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$shellExe = (Get-Process -Id $PID).Path
$parsed = 0
foreach ($directory in @('scripts','tests')) {
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $repoRoot $directory) -Filter '*.ps1' -File) {
        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$parseErrors)
        if (@($parseErrors).Count -gt 0) { throw ('Syntax error in ' + $file.Name + ': ' + ($parseErrors.Message -join '; ')) }
        $parsed++
    }
}
$reports = @()
$totalTests = 0
foreach ($name in @('test-queue.ps1','test-results-watch.ps1','test-delivery.ps1')) {
    $output = & $shellExe -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot $name) -RepoRoot $repoRoot 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Write-Output $output; throw ('Test suite failed: ' + $name) }
    $report = $output | ConvertFrom-Json
    if (-not $report.passed) { throw ('Test suite did not pass: ' + $name) }
    $reports += [ordered]@{suite=$name;passed=$true;tests=@($report.tests).Count;test_root=$report.test_root}
    $totalTests += @($report.tests).Count
}
[pscustomobject]@{passed=$true;powershell=$PSVersionTable.PSVersion.ToString();scripts_parsed=$parsed;test_count=$totalTests;suites=$reports;mode='Isolated synthetic fixtures; no model calls'} | ConvertTo-Json -Depth 8
