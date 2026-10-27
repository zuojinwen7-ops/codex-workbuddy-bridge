[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Instruction,
    [Parameter(Mandatory = $true)][ValidateSet('read_file','write_file','analyze','generate_report','run_project_command')][string[]]$AllowedScope,
    [Parameter(Mandatory = $true)][string[]]$Checks,
    [string]$WorkDir,
    [string]$TaskId = ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)),
    [ValidateSet('normal','high')][string]$Priority = 'normal',
    [string]$Context = '',
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'bridge.local.json')
)
. (Join-Path $PSScriptRoot 'Bridge.Common.ps1')
$config = Get-BridgeConfig $ConfigPath
if (-not $WorkDir) { $WorkDir = [string]$config.workspace_root }
if (@($Checks | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -ne $Checks.Count -or $Checks.Count -eq 0) { throw 'Provide concrete nonempty acceptance checks.' }
$task = [pscustomobject][ordered]@{schema_version=1;task_id=$TaskId;created_at=[DateTimeOffset]::Now.ToString('o');priority=$Priority;work_dir=(Get-BridgeFullPath $WorkDir);allowed_scope=@($AllowedScope);instruction=$Instruction;acceptance_checks=@($Checks);context=$Context}
Assert-BridgeTask $task $TaskId $config
foreach ($folder in @('inbox','processing','done','failed','results','reviews','ids')) {
    if (Test-Path -LiteralPath (Get-BridgeTaskPath $config $folder $TaskId)) { throw 'Task ID already exists. Inspect the original task; it was not sent again.' }
}
# CreateNew reserves the ID even if another producer races with this one.
$reservation = Get-BridgeTaskPath $config 'ids' $TaskId
$stream = [IO.File]::Open($reservation, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $bytes = $script:BridgeUtf8.GetBytes(($task | ConvertTo-Json -Depth 12)); $stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
$destination = Get-BridgeTaskPath $config 'inbox' $TaskId
Write-BridgeJson $destination $task
[pscustomobject]@{task_id=$TaskId;state='queued';task_path=$destination;note='Queued is not execution or acceptance.'} | ConvertTo-Json
