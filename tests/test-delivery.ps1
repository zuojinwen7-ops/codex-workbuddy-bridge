param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$runRoot = Join-Path $RepoRoot ('.test-runs\delivery-' + [guid]::NewGuid().ToString('N').Substring(0,8))
foreach ($folder in @('results','done','failed','reviews','logs')) { [IO.Directory]::CreateDirectory((Join-Path $runRoot $folder)) | Out-Null }
$shellExe = (Get-Process -Id $PID).Path
$watcherScript = Join-Path $RepoRoot 'scripts\watch-results.ps1'
# The Windows file locator always fails on queue's options. It cannot call a model.
$failureExe = Join-Path $env:SystemRoot 'System32\where.exe'
$resultPath = Join-Path $runRoot 'results\delivery-fixture.json'
$taskPath = Join-Path $runRoot 'done\delivery-fixture.json'
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($taskPath, '{"task_id":"delivery-fixture","instruction":"SYNTHETIC FIXTURE"}', $utf8)
[IO.File]::WriteAllText($resultPath, '{"task_id":"delivery-fixture","status":"success","artifacts":[]}', $utf8)
$arguments = @('-NoProfile','-File',('"' + $watcherScript + '"'),'-BridgeRoot',('"' + $runRoot + '"'),'-WorkspaceRoot',('"' + $runRoot + '"'),'-ThreadId','11111111-1111-4111-8111-111111111111','-CodexExe',('"' + $failureExe + '"')) -join ' '
$watcherProcess = $null
function Read-Failures {
    $path = Join-Path $runRoot 'logs\watch-results.jsonl'
    if (-not [IO.File]::Exists($path)) { return @() }
    return @(Get-Content -LiteralPath $path -Encoding UTF8 | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} } | Where-Object { $_.event -eq 'queue_failed' })
}
try {
    $watcherProcess = Start-Process -FilePath $shellExe -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runRoot 'logs\first.out') -RedirectStandardError (Join-Path $runRoot 'logs\first.err')
    $null = $watcherProcess.Handle
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while (@(Read-Failures).Count -eq 0 -and [DateTime]::UtcNow -lt $deadline -and -not $watcherProcess.HasExited) { Start-Sleep -Milliseconds 100 }
    if (@(Read-Failures).Count -ne 1) { throw 'Expected one recorded queue failure.' }
    [IO.File]::SetLastWriteTimeUtc($resultPath,[DateTime]::UtcNow)
    Start-Sleep -Milliseconds 1500
    if (@(Read-Failures).Count -ne 1) { throw 'An unchanged failed delivery was retried.' }
    [IO.File]::WriteAllText((Join-Path $runRoot 'watch-results.stop'),'test stop', $utf8)
    if (-not $watcherProcess.WaitForExit(8000) -or $watcherProcess.ExitCode -ne 0) { throw 'Watcher failed to stop gracefully.' }
    [IO.File]::Delete((Join-Path $runRoot 'watch-results.stop'))
    $watcherProcess = Start-Process -FilePath $shellExe -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runRoot 'logs\second.out') -RedirectStandardError (Join-Path $runRoot 'logs\second.err')
    $null = $watcherProcess.Handle
    Start-Sleep -Milliseconds 2000
    if ($watcherProcess.HasExited -or @(Read-Failures).Count -ne 1) { throw 'Restart lost the no-retry delivery boundary.' }
    [IO.File]::WriteAllText((Join-Path $runRoot 'watch-results.stop'),'test stop', $utf8)
    if (-not $watcherProcess.WaitForExit(8000) -or $watcherProcess.ExitCode -ne 0) { throw 'Restarted watcher failed to stop.' }
    $tests = @('Failed delivery is recorded','Unchanged events do not retry failed delivery','No-retry boundary survives restart','Both listeners stop gracefully') | ForEach-Object { [ordered]@{name=$_;passed=$true} }
    $report = [ordered]@{passed=$true;tests=@($tests);test_root=$runRoot;mode='where.exe failure fixture; no Codex or model calls'}
    [IO.File]::WriteAllText((Join-Path $runRoot 'test-report.json'),($report | ConvertTo-Json -Depth 8),$utf8)
    $report | ConvertTo-Json -Depth 8
} catch {
    [IO.File]::WriteAllText((Join-Path $runRoot 'watch-results.stop'),'cleanup after test failure',$utf8)
    if ($watcherProcess -and -not $watcherProcess.HasExited) { [void]$watcherProcess.WaitForExit(8000) }
    [pscustomobject]@{passed=$false;error=$_.Exception.Message;test_root=$runRoot} | ConvertTo-Json
    exit 1
}
