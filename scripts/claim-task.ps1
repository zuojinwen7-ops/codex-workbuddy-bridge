[CmdletBinding()]
param([string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'bridge.local.json'))
. (Join-Path $PSScriptRoot 'Bridge.Common.ps1')
$config = Get-BridgeConfig $ConfigPath
$candidates = @()
foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $config.bridge_root 'inbox') -Filter '*.json' -File)) {
    $path = Assert-BridgePath $file.FullName $config.workspace_root
    $task = Read-BridgeJson $path
    Assert-BridgeTask $task $file.BaseName $config
    $rank = if ($task.PSObject.Properties['priority'] -and $task.priority -eq 'high') { 0 } else { 1 }
    $candidates += [pscustomobject]@{file=$file;task=$task;rank=$rank;created=[DateTimeOffset]::Parse($task.created_at)}
}
foreach ($candidate in @($candidates | Sort-Object rank,created)) {
    $id = [string]$candidate.task.task_id
    foreach ($folder in @('done','failed','results','reviews','claims')) {
        if (Test-Path -LiteralPath (Get-BridgeTaskPath $config $folder $id)) { throw 'A task with this ID was already claimed or archived; inspect it before continuing.' }
    }
    $processing = Get-BridgeTaskPath $config 'processing' $id
    try { [IO.File]::Move($candidate.file.FullName, $processing) }
    catch [IO.IOException] {
        if (-not [IO.File]::Exists($candidate.file.FullName) -or [IO.File]::Exists($processing)) { continue }
        throw
    }
    $claim = [ordered]@{task_id=$id;claimed_at=[DateTimeOffset]::Now.ToString('o');claim_process_id=$PID;provenance='Filesystem claim only; does not authenticate the executing model.'}
    Write-BridgeJson (Get-BridgeTaskPath $config 'claims' $id) $claim
    [pscustomobject]@{state='claimed';task=$candidate.task;task_path=$processing;claim=$claim} | ConvertTo-Json -Depth 15
    return
}
[pscustomobject]@{state='empty'} | ConvertTo-Json
