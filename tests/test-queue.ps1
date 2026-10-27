param([string]$RepoRoot = (Split-Path $PSScriptRoot -Parent))
. (Join-Path $RepoRoot 'scripts\Bridge.Common.ps1')
$runRoot = Join-Path $RepoRoot ('.test-runs\queue with spaces 中文-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$workspace = Join-Path $runRoot 'project'
$bridge = Join-Path $workspace '.agent-bridge'
$configPath = Join-Path $runRoot 'test.local.json'
foreach ($folder in @('inbox','processing','done','failed','results','reviews','logs','ids','claims')) { [IO.Directory]::CreateDirectory((Join-Path $bridge $folder)) | Out-Null }
Write-BridgeJson $configPath ([ordered]@{schema_version=1;workspace_root=$workspace;bridge_root=$bridge;thread_id='11111111-1111-4111-8111-111111111111';codex_exe=(Get-Process -Id $PID).Path})
$scripts = Join-Path $RepoRoot 'scripts'
$checks = New-Object 'System.Collections.Generic.List[object]'
function Assert-Test([string]$Name, [bool]$Passed) {
    if (-not $Passed) { throw ('TEST FAILED: ' + $Name) }
    $checks.Add([pscustomobject]@{name=$Name;passed=$true})
}
function Assert-Rejected([string]$Name, [scriptblock]$Action) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert-Test $Name $rejected
}

try {
    $config = Get-BridgeConfig $configPath
    Assert-Test 'Configuration works with spaces and Unicode' ($config.workspace_root -eq $workspace)
    $id = 'fixture-success-001'
    $submitted = & (Join-Path $scripts 'submit-task.ps1') -ConfigPath $configPath -TaskId $id -Instruction 'SYNTHETIC TEST ONLY: create fixture.txt' -AllowedScope write_file -Checks 'Check fixture content' | Out-String | ConvertFrom-Json
    Assert-Test 'Task is published atomically with a durable ID reservation' ($submitted.state -eq 'queued' -and (Test-Path -LiteralPath (Join-Path $bridge ('ids\' + $id + '.json'))))
    Assert-Rejected 'Duplicate submission does not overwrite or publish twice' { & (Join-Path $scripts 'submit-task.ps1') -ConfigPath $configPath -TaskId $id -Instruction 'different' -AllowedScope write_file -Checks 'x' }
    $claim = & (Join-Path $scripts 'claim-task.ps1') -ConfigPath $configPath | Out-String | ConvertFrom-Json
    Assert-Test 'Claim moves the task out of inbox and preserves the instruction' ($claim.state -eq 'claimed' -and $claim.task.task_id -eq $id -and -not (Test-Path -LiteralPath $submitted.task_path))
    $empty = & (Join-Path $scripts 'claim-task.ps1') -ConfigPath $configPath | Out-String | ConvertFrom-Json
    Assert-Test 'Already claimed work cannot be claimed again' ($empty.state -eq 'empty')
    $artifact = Join-Path $workspace 'fixture.txt'
    [IO.File]::WriteAllText($artifact, 'SYNTHETIC TEST DATA; NOT REAL WORKBUDDY EXECUTION', $script:BridgeUtf8)
    $reported = & (Join-Path $scripts 'report-result.ps1') -ConfigPath $configPath -TaskId $id -Status success -Summary 'Synthetic fixture' -ArtifactPaths $artifact | Out-String | ConvertFrom-Json
    Assert-Test 'Reporting archives the task and requires independent review' ($reported.state -eq 'needs_review' -and (Test-Path -LiteralPath (Join-Path $bridge ('done\' + $id + '.json'))) -and -not (Test-Path -LiteralPath $claim.task_path))
    $record = & (Join-Path $scripts 'write-review.ps1') -ConfigPath $configPath -TaskId $id -Verdict accepted -Summary 'Synthetic review fixture' -Evidence 'Test read the actual fixture bytes and checked the synthetic label.' | Out-String | ConvertFrom-Json
    $review = Read-BridgeJson $record.review_path
    $artifactHash = (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Test 'Review includes actual artifact, task and result hashes' ($review.source_files.Count -eq 3 -and @($review.source_files | Where-Object { $_.path -eq $artifact -and $_.sha256 -eq $artifactHash }).Count -eq 1)
    Assert-Rejected 'Evidence cannot be empty' { & (Join-Path $scripts 'write-review.ps1') -ConfigPath $configPath -TaskId $id -Verdict accepted -Summary 'x' -Evidence @('') }
    Assert-Rejected 'Result cannot be overwritten by a second report' { & (Join-Path $scripts 'report-result.ps1') -ConfigPath $configPath -TaskId $id -Status success -Summary 'duplicate' }
    Assert-Rejected 'Path traversal task IDs are rejected' { & (Join-Path $scripts 'submit-task.ps1') -ConfigPath $configPath -TaskId '..\escape' -Instruction 'x' -AllowedScope read_file -Checks 'x' }
    Assert-Rejected 'Sibling directory prefix is not accepted as inside workspace' { Assert-BridgePath ($workspace + '-other\file.txt') $workspace -AllowMissing }
    Assert-Rejected 'Credential evidence is rejected' { Assert-BridgePath (Join-Path $workspace '.env') $workspace -AllowMissing }
    Assert-Rejected 'Working directory outside the workspace is rejected' { & (Join-Path $scripts 'submit-task.ps1') -ConfigPath $configPath -WorkDir $runRoot -Instruction 'x' -AllowedScope read_file -Checks 'x' }
    $outside = Join-Path $runRoot 'outside'
    [IO.Directory]::CreateDirectory($outside) | Out-Null
    $junction = Join-Path $workspace 'linked-outside'
    New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
    Assert-Rejected 'Directory junctions cannot bypass path boundaries' { Assert-BridgePath (Join-Path $junction 'file.txt') $workspace -AllowMissing }

    & (Join-Path $scripts 'submit-task.ps1') -ConfigPath $configPath -TaskId 'normal-001' -Instruction 'fixture' -AllowedScope read_file -Checks 'fixture' | Out-Null
    & (Join-Path $scripts 'submit-task.ps1') -ConfigPath $configPath -TaskId 'high-001' -Priority high -Instruction 'fixture' -AllowedScope read_file -Checks 'fixture' | Out-Null
    $high = & (Join-Path $scripts 'claim-task.ps1') -ConfigPath $configPath | Out-String | ConvertFrom-Json
    Assert-Test 'High priority tasks are claimed first' ($high.task.task_id -eq 'high-001')
    & (Join-Path $scripts 'report-result.ps1') -ConfigPath $configPath -TaskId 'high-001' -Status failed -Summary 'Synthetic failure' -ErrorMessage 'Test-only failure' | Out-Null
    Assert-Rejected 'A failed execution cannot be accepted' { & (Join-Path $scripts 'write-review.ps1') -ConfigPath $configPath -TaskId 'high-001' -Verdict accepted -Summary 'x' -Evidence 'x' }
    $blocked = & (Join-Path $scripts 'write-review.ps1') -ConfigPath $configPath -TaskId 'high-001' -Verdict blocked -Summary 'Synthetic failure preserved' -Evidence 'Read failure result' | Out-String | ConvertFrom-Json
    Assert-Test 'Failed work can be recorded as blocked' ($blocked.verdict -eq 'blocked')
    $inboxWake = & (Join-Path $scripts 'watch-inbox.ps1') -ConfigPath $configPath -TimeoutSeconds 1 | Out-String
    Assert-Test 'Inbox watcher immediately reports existing pending work' ($inboxWake -match 'PENDING\|normal-001.json')
    & (Join-Path $scripts 'claim-task.ps1') -ConfigPath $configPath | Out-Null
    $timeout = & (Join-Path $scripts 'watch-inbox.ps1') -ConfigPath $configPath -TimeoutSeconds 1 | Out-String
    Assert-Test 'Empty inbox waits and returns a bounded timeout' ($timeout -match 'TIMEOUT\|1')
    $shellExe = (Get-Process -Id $PID).Path
    $watchArguments = @('-NoProfile','-File',('"' + (Join-Path $scripts 'watch-inbox.ps1') + '"'),'-ConfigPath',('"' + $configPath + '"'),'-TimeoutSeconds','10') -join ' '
    $inboxChild = Start-Process -FilePath $shellExe -ArgumentList $watchArguments -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $runRoot 'inbox-event.out') -RedirectStandardError (Join-Path $runRoot 'inbox-event.err')
    Start-Sleep -Milliseconds 1000
    & (Join-Path $scripts 'submit-task.ps1') -ConfigPath $configPath -TaskId 'new-event-001' -Instruction 'SYNTHETIC EVENT TEST' -AllowedScope read_file -Checks 'fixture' | Out-Null
    Assert-Test 'An inbox file event ends the background wait' ($inboxChild.WaitForExit(12000) -and $inboxChild.ExitCode -eq 0)
    $inboxOutput = Get-Content -LiteralPath (Join-Path $runRoot 'inbox-event.out') -Raw
    Assert-Test 'Inbox event names the new published task' ($inboxOutput -match '(EVENT|PENDING)\|new-event-001.json')
    & (Join-Path $scripts 'claim-task.ps1') -ConfigPath $configPath | Out-Null
    $invalid = Join-Path $bridge 'inbox\invalid-json.json'
    [IO.File]::WriteAllText($invalid, '{unfinished', $script:BridgeUtf8)
    Assert-Rejected 'Malformed task is not moved to processing' { & (Join-Path $scripts 'claim-task.ps1') -ConfigPath $configPath }
    Assert-Test 'Malformed input remains available for inspection' ([IO.File]::Exists($invalid) -and -not [IO.File]::Exists((Join-Path $bridge 'processing\invalid-json.json')))

    $manager = Join-Path $scripts 'manage-results-watch.ps1'
    $null = & $manager -ConfigPath $configPath -Action Start -DryRun | Out-String | ConvertFrom-Json
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        $status = & $manager -ConfigPath $configPath -Action Status | Out-String | ConvertFrom-Json
        if ($status.healthy) { break }
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    Assert-Test 'Manager verifies the relocated watcher script and chat binding' ([bool]$status.healthy -and [bool]$status.identity_verified -and [bool]$status.dry_run)
    $again = & $manager -ConfigPath $configPath -Action Start -DryRun | Out-String | ConvertFrom-Json
    Assert-Test 'Repeated manager Start reuses the verified process' ($again.pid -eq $status.pid -and $again.healthy)
    $stopped = & $manager -ConfigPath $configPath -Action Stop | Out-String | ConvertFrom-Json
    Assert-Test 'Manager stops only its own listener through a stop marker' (-not $stopped.process_alive -and $stopped.status -eq 'stopped')
    $report = [ordered]@{passed=$true;tests=@($checks.ToArray());test_root=$runRoot;mode='Synthetic queue fixtures; no model calls'}
    Write-BridgeJson (Join-Path $runRoot 'test-report.json') $report
    $report | ConvertTo-Json -Depth 8
} catch {
    [pscustomobject]@{passed=$false;error=$_.Exception.Message;test_root=$runRoot;line=$_.InvocationInfo.ScriptLineNumber} | ConvertTo-Json
    exit 1
}
