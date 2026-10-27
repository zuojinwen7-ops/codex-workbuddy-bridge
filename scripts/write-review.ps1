[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TaskId,
    [Parameter(Mandatory = $true)][ValidateSet('accepted','rework_required','blocked')][string]$Verdict,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Summary,
    [Parameter(Mandatory = $true)][string[]]$Evidence,
    [string[]]$SourcePaths = @(),
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'bridge.local.json')
)
. (Join-Path $PSScriptRoot 'Bridge.Common.ps1')
$config = Get-BridgeConfig $ConfigPath
if ($Evidence.Count -eq 0 -or @($Evidence | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { throw 'Concrete verification evidence is required.' }
$resultPath = Get-BridgeTaskPath $config 'results' $TaskId
$result = Read-BridgeJson $resultPath
if ([string]$result.task_id -cne $TaskId -or $result.status -notin @('success','failed')) { throw 'Result identity or status is invalid.' }
if ($Verdict -eq 'accepted' -and $result.status -ne 'success') { throw 'A failed execution cannot be accepted.' }
$folder = if ($result.status -eq 'success') { 'done' } else { 'failed' }
$taskPath = Get-BridgeTaskPath $config $folder $TaskId
$task = Read-BridgeJson $taskPath
Assert-BridgeTask $task $TaskId $config
$allPaths = @($taskPath,$resultPath) + @($result.artifacts) + @($SourcePaths)
$sources = @()
foreach ($path in @($allPaths | Select-Object -Unique)) {
    $safe = Assert-BridgePath ([string]$path) $config.workspace_root
    if (-not [IO.File]::Exists($safe)) { throw 'A review source must be an existing regular file.' }
    $sources += [ordered]@{path=$safe;sha256=(Get-FileHash -LiteralPath $safe -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$checks = @()
if ($task.PSObject.Properties['acceptance_checks']) { $checks = @($task.acceptance_checks) }
$review = [ordered]@{schema_version=1;task_id=$TaskId;verdict=$Verdict;summary=$Summary;checks=$checks;evidence=@($Evidence);source_files=$sources;reviewed_at=[DateTimeOffset]::Now.ToString('o');reviewer='Codex';provenance=@{executor_declared=$result.executor;independent_scope='Only the checks described in evidence; recording this review does not run them.'};notification=@{state='pending_chat_report'}}
$path = Get-BridgeTaskPath $config 'reviews' $TaskId
Write-BridgeJson $path $review -Replace
[pscustomobject]@{task_id=$TaskId;verdict=$Verdict;review_path=$path;note='This command records evidence. The reviewer must actually perform the checks.'} | ConvertTo-Json
