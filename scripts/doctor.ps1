[CmdletBinding()]
param([string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'bridge.local.json'))
. (Join-Path $PSScriptRoot 'Bridge.Common.ps1')
$config = Get-BridgeConfig $ConfigPath
$help = (& $config.codex_exe queue --help 2>&1 | Out-String)
$queueSupported = $LASTEXITCODE -eq 0 -and $help -match '--thread' -and $help -match '--message'
$counts = [ordered]@{}
foreach ($folder in @('inbox','processing','done','failed','results','reviews')) {
    $counts[$folder] = @(Get-ChildItem -LiteralPath (Join-Path $config.bridge_root $folder) -Filter '*.json' -File).Count
}
$watcher = & (Join-Path $PSScriptRoot 'manage-results-watch.ps1') -Action Status -ConfigPath $ConfigPath | Out-String | ConvertFrom-Json
[pscustomobject]@{configuration_valid=$true;powershell=$PSVersionTable.PSVersion.ToString();codex_queue_supported=[bool]$queueSupported;queue_counts=$counts;results_watcher=$watcher;note='Does not prove WorkBuddy login, a live worker, model quota or end-to-end acceptance. Inspect processing tasks before retrying interrupted work.'} | ConvertTo-Json -Depth 10
