param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference = 'Stop'
$watcherScript = Join-Path $RepoRoot 'scripts\watch-results.ps1'
$shellExe = (Get-Process -Id $PID).Path
$codexExe = $shellExe # DryRun never invokes it; CI needs no Codex installation.
$runRoot = Join-Path $RepoRoot ('.test-runs\watch-results-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6))
foreach ($name in @('results','done','failed','reviews','logs','artifacts')) { [IO.Directory]::CreateDirectory((Join-Path $runRoot $name)) | Out-Null }
$testResults = [Collections.Generic.List[object]]::new()
$watcherProcess = $null

function Write-JsonFile([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}
function Assert-Test([string]$Name, [bool]$Condition) {
    if (-not $Condition) { throw ('TEST FAILED: ' + $Name) }
    $testResults.Add([pscustomobject]@{name=$Name;passed=$true})
}
function Read-Events {
    $logPath = Join-Path $runRoot 'logs\watch-results.jsonl'
    if (-not (Test-Path -LiteralPath $logPath)) { return @() }
    return @(Get-Content -LiteralPath $logPath -Encoding utf8 | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} })
}
function Wait-EventCount([string]$EventName, [int]$Minimum, [int]$TimeoutSeconds = 15) {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $matching = @((Read-Events) | Where-Object { $_.event -eq $EventName })
        if ($matching.Count -ge $Minimum) { return $matching }
        if ($watcherProcess -and $watcherProcess.HasExited) { throw ('Watcher stopped early: ' + $watcherProcess.ExitCode) }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw ('Timed out waiting for ' + $EventName + ' count ' + $Minimum)
}
function New-Fixture([string]$TaskId) {
    $artifactPath = Join-Path $runRoot ('artifacts\' + $TaskId + '.txt')
    [IO.File]::WriteAllText($artifactPath, 'ISOLATED LISTENER TEST; NOT A WORKBUDDY BUSINESS RESULT', [Text.UTF8Encoding]::new($false))
    $taskPath = Join-Path $runRoot ('done\' + $TaskId + '.json')
    $resultPath = Join-Path $runRoot ('results\' + $TaskId + '.json')
    Write-JsonFile $taskPath ([ordered]@{task_id=$TaskId;created_at=[DateTimeOffset]::Now.ToString('o');work_dir=(Join-Path $runRoot 'artifacts');allowed_scope=@('write_file');instruction='ISOLATED EVENT TEST ONLY; do not execute';context='listener test fixture'})
    $result = [ordered]@{task_id=$TaskId;status='success';summary='ISOLATED TEST FIXTURE, NOT REAL EXECUTION';artifacts=@($artifactPath);executor='TEST-FIXTURE'}
    return [pscustomobject]@{id=$TaskId;task=$taskPath;result=$resultPath;artifact=$artifactPath;resultValue=$result}
}
function Write-FixtureReview($Fixture) {
    $files = @($Fixture.task,$Fixture.result,$Fixture.artifact) | ForEach-Object { [ordered]@{path=$_;sha256=(Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()} }
    Write-JsonFile (Join-Path $runRoot ('reviews\' + $Fixture.id + '.json')) ([ordered]@{task_id=$Fixture.id;verdict='accepted';source_files=@($files);notification=@{already_reported_in_chat=$true};reviewer='ISOLATED-TEST'})
}

try {
    $baseline = New-Fixture '20261027-190000-aabb01'
    Write-JsonFile $baseline.result $baseline.resultValue
    Write-FixtureReview $baseline
    $startArguments = @('-NoProfile','-File',('"' + $watcherScript + '"'),'-BridgeRoot',('"' + $runRoot + '"'),'-WorkspaceRoot',('"' + $runRoot + '"'),'-ThreadId','11111111-1111-4111-8111-111111111111','-CodexExe',('"' + $codexExe + '"'),'-DryRun')
    $watcherProcess = Start-Process -FilePath $shellExe -ArgumentList $startArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runRoot 'logs\stdout.txt') -RedirectStandardError (Join-Path $runRoot 'logs\stderr.txt')
    Wait-EventCount 'started' 1 | Out-Null
    Start-Sleep -Milliseconds 1000
    Assert-Test 'Previously reviewed unchanged files are skipped on startup' (@((Read-Events) | Where-Object { $_.event -eq 'would_queue' }).Count -eq 0)

    $fresh = New-Fixture '20261027-190001-aabb02'
    $tempPath = $fresh.result + '.tmp'
    Write-JsonFile $tempPath $fresh.resultValue
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Move-Item -LiteralPath $tempPath -Destination $fresh.result
    Wait-EventCount 'would_queue' 1 | Out-Null
    $timer.Stop()
    Assert-Test 'Atomic result publication triggers an event without a schedule' ($timer.Elapsed.TotalSeconds -lt 15)
    Start-Sleep -Milliseconds 1000
    $before = @((Read-Events) | Where-Object { $_.event -eq 'would_queue' }).Count
    [IO.File]::SetLastWriteTimeUtc($fresh.result,[DateTime]::UtcNow)
    Start-Sleep -Milliseconds 1200
    Assert-Test 'Repeated events with unchanged content do not enqueue again' (@((Read-Events) | Where-Object { $_.event -eq 'would_queue' }).Count -eq $before)

    [IO.File]::AppendAllText($fresh.artifact,'; CHANGED', [Text.UTF8Encoding]::new($false))
    Wait-EventCount 'would_queue' ($before + 1) | Out-Null
    Assert-Test 'A referenced artifact content change triggers a new fingerprint' ($true)
    Write-FixtureReview $fresh
    Start-Sleep -Milliseconds 1200
    $after = @((Read-Events) | Where-Object { $_.event -eq 'would_queue' }).Count
    [IO.File]::SetLastWriteTimeUtc($fresh.result,[DateTime]::UtcNow)
    Start-Sleep -Milliseconds 1200
    Assert-Test 'Review acknowledgement prevents redundant model calls' (@((Read-Events) | Where-Object { $_.event -eq 'would_queue' }).Count -eq $after)

    $duplicate = Start-Process -FilePath $shellExe -ArgumentList $startArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runRoot 'logs\duplicate-stdout.txt') -RedirectStandardError (Join-Path $runRoot 'logs\duplicate-stderr.txt')
    Assert-Test 'Second listener for the same bridge exits rather than duplicating dispatch' ($duplicate.WaitForExit(8000))
    Assert-Test 'DryRun never calls codex queue' (@((Read-Events) | Where-Object { $_.event -eq 'queued' }).Count -eq 0)
    [IO.File]::WriteAllText((Join-Path $runRoot 'watch-results.stop'),'isolated test finished')
    Assert-Test 'Stop marker ends the listener gracefully' ($watcherProcess.WaitForExit(8000))
    Assert-Test 'Listener exits successfully' ($watcherProcess.ExitCode -eq 0)
    $report = [ordered]@{passed=$true;tests=@($testResults.ToArray());event_latency_seconds=[Math]::Round($timer.Elapsed.TotalSeconds,3);test_root=$runRoot;mode='DryRun; no messages or business artifacts generated'}
    Write-JsonFile (Join-Path $runRoot 'test-report.json') $report
    $report | ConvertTo-Json -Depth 8
} catch {
    [IO.File]::WriteAllText((Join-Path $runRoot 'watch-results.stop'),'test cleanup after failure')
    if ($watcherProcess -and -not $watcherProcess.HasExited) { $watcherProcess.WaitForExit(8000) | Out-Null }
    [pscustomobject]@{passed=$false;error=$_.Exception.Message;test_root=$runRoot} | ConvertTo-Json
    exit 1
}
