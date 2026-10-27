[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TaskId,
    [Parameter(Mandatory = $true)][ValidateSet('success','failed')][string]$Status,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Summary,
    [string[]]$ArtifactPaths = @(),
    [string]$ErrorMessage,
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'bridge.local.json')
)
. (Join-Path $PSScriptRoot 'Bridge.Common.ps1')
$config = Get-BridgeConfig $ConfigPath
$processing = Get-BridgeTaskPath $config 'processing' $TaskId
$task = Read-BridgeJson $processing
Assert-BridgeTask $task $TaskId $config
$claim = Read-BridgeJson (Get-BridgeTaskPath $config 'claims' $TaskId)
$artifacts = @()
foreach ($path in $ArtifactPaths) {
    $safe = Assert-BridgePath $path $task.work_dir
    if (-not [IO.File]::Exists($safe)) { throw 'An artifact must be an existing regular file.' }
    $artifacts += $safe
}
if ($Status -eq 'failed' -and [string]::IsNullOrWhiteSpace($ErrorMessage)) { throw 'A failed task needs an error description.' }
$resultPath = Get-BridgeTaskPath $config 'results' $TaskId
if ([IO.File]::Exists($resultPath)) { throw 'A result already exists; it was not overwritten.' }
$result = [ordered]@{schema_version=1;task_id=$TaskId;status=$Status;summary=$Summary;artifacts=@($artifacts);error=$ErrorMessage;started_at=$claim.claimed_at;finished_at=[DateTimeOffset]::Now.ToString('o');executor='WorkBuddy';provenance='Executor declaration; independently review artifacts and any native execution evidence.'}
$folder = if ($Status -eq 'success') { 'done' } else { 'failed' }
[IO.File]::Move($processing, (Get-BridgeTaskPath $config $folder $TaskId))
Write-BridgeJson $resultPath $result
[pscustomobject]@{task_id=$TaskId;state='needs_review';result_path=$resultPath} | ConvertTo-Json
