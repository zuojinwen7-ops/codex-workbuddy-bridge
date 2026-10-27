[CmdletBinding()]
param(
    [ValidateSet('Start', 'Stop', 'Status')]
    [string]$Action = 'Status',
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'bridge.local.json'),
    [string]$BridgeRoot,
    [string]$WorkspaceRoot,
    [string]$ThreadId,
    [string]$CodexExe,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not $BridgeRoot -or -not $WorkspaceRoot -or -not $ThreadId) {
    . (Join-Path $PSScriptRoot 'Bridge.Common.ps1')
    $localConfig = Get-BridgeConfig $ConfigPath
    if (-not $BridgeRoot) { $BridgeRoot = [string]$localConfig.bridge_root }
    if (-not $WorkspaceRoot) { $WorkspaceRoot = [string]$localConfig.workspace_root }
    if (-not $ThreadId) { $ThreadId = [string]$localConfig.thread_id }
    if (-not $CodexExe) { $CodexExe = [string]$localConfig.codex_exe }
}

function Get-NormalizedDirectory {
    param([string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'An absolute directory path is required.' }
    $directory = Get-Item -LiteralPath ([IO.Path]::GetFullPath($Path)) -ErrorAction Stop
    if (-not $directory.PSIsContainer) { throw 'The supplied path is not a directory.' }
    $fullPath = $directory.FullName
    $driveRoot = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath -eq $driveRoot) { return $driveRoot }
    return $fullPath.TrimEnd('\')
}

function Assert-NoReparsePath {
    param([string]$Path)
    $cursor = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $cursor) {
        if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'A watcher management path crosses a reparse point; no process or marker was changed.'
        }
        if ($cursor -is [IO.FileInfo]) { $cursor = $cursor.Directory } else { $cursor = $cursor.Parent }
    }
}

function Get-StateValue {
    param($State, [string]$Name)
    if ($null -ne $State -and $null -ne $State.PSObject.Properties[$Name]) {
        return $State.PSObject.Properties[$Name].Value
    }
    return $null
}

function Read-WatcherState {
    if (-not (Test-Path -LiteralPath $script:statePath -PathType Leaf)) { return $null }
    try {
        return Get-Content -LiteralPath $script:statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

# Parse the Windows command-line quoting used by Start-Process, without executing it.
function Get-NativeArguments {
    param([string]$CommandLine)
    $items = New-Object 'System.Collections.Generic.List[string]'
    $index = 0
    while ($index -lt $CommandLine.Length) {
        while ($index -lt $CommandLine.Length -and [char]::IsWhiteSpace($CommandLine[$index])) { $index++ }
        if ($index -ge $CommandLine.Length) { break }
        $builder = New-Object Text.StringBuilder
        $quoted = $false
        while ($index -lt $CommandLine.Length) {
            if (-not $quoted -and [char]::IsWhiteSpace($CommandLine[$index])) { break }
            $slashes = 0
            while ($index -lt $CommandLine.Length -and $CommandLine[$index] -eq '\') {
                $slashes++
                $index++
            }
            if ($index -lt $CommandLine.Length -and $CommandLine[$index] -eq '"') {
                if ($slashes -gt 1) { [void]$builder.Append(('\' * [int][Math]::Floor($slashes / 2))) }
                if (($slashes % 2) -eq 1) {
                    [void]$builder.Append('"')
                } elseif ($quoted -and $index + 1 -lt $CommandLine.Length -and $CommandLine[$index + 1] -eq '"') {
                    [void]$builder.Append('"')
                    $index++
                } else {
                    $quoted = -not $quoted
                }
                $index++
                continue
            }
            if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)) }
            if ($index -ge $CommandLine.Length) { break }
            if (-not $quoted -and [char]::IsWhiteSpace($CommandLine[$index])) { break }
            [void]$builder.Append($CommandLine[$index])
            $index++
        }
        $items.Add($builder.ToString())
        while ($index -lt $CommandLine.Length -and [char]::IsWhiteSpace($CommandLine[$index])) { $index++ }
    }
    return ,$items.ToArray()
}

function Get-ArgumentValue {
    param([string[]]$Arguments, [string]$Name)
    for ($position = 0; $position -lt $Arguments.Length - 1; $position++) {
        if ($Arguments[$position].Equals($Name, [StringComparison]::OrdinalIgnoreCase)) {
            return $Arguments[$position + 1]
        }
    }
    return $null
}

function Test-SamePath {
    param([string]$Left, [string]$Right)
    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
    try {
        return [IO.Path]::GetFullPath($Left).TrimEnd('\').Equals(
            [IO.Path]::GetFullPath($Right).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Get-WatcherStatus {
    $state = Read-WatcherState
    $watcherPid = 0
    $pidValue = Get-StateValue $state 'pid'
    if ($null -ne $pidValue) { [void][int]::TryParse([string]$pidValue, [ref]$watcherPid) }
    $identityVerified = $false
    $processAlive = $false
    $commandThread = $null
    $reason = 'No valid watcher state is available.'
    if ($watcherPid -gt 0) {
        $process = Get-Process -Id $watcherPid -ErrorAction SilentlyContinue
        if ($null -eq $process) {
            $reason = 'The recorded watcher process no longer exists.'
        } elseif ($process.ProcessName -notin @('powershell', 'pwsh')) {
            $processAlive = $true
            $reason = 'The recorded PID belongs to a different executable.'
        } else {
            $processAlive = $true
            try {
                $nativeProcess = Get-CimInstance Win32_Process -Filter ('ProcessId = ' + $watcherPid) -ErrorAction Stop
                $arguments = Get-NativeArguments ([string]$nativeProcess.CommandLine)
                $fileArgument = Get-ArgumentValue $arguments '-File'
                $bridgeArgument = Get-ArgumentValue $arguments '-BridgeRoot'
                $commandThread = Get-ArgumentValue $arguments '-ThreadId'
                $stateBridge = [string](Get-StateValue $state 'bridge_root')
                $identityVerified = (Test-SamePath $fileArgument $script:watcherPath) -and
                    (Test-SamePath $bridgeArgument $script:normalizedBridge) -and
                    (Test-SamePath $stateBridge $script:normalizedBridge)
                if (-not $identityVerified) { $reason = 'The recorded PID does not match this watcher and bridge directory.' }
            } catch {
                $reason = 'The watcher process identity could not be verified.'
            }
        }
    }
    $stateStatus = [string](Get-StateValue $state 'status')
    $stateThread = [string](Get-StateValue $state 'thread_id')
    $threadMatches = $identityVerified -and $stateThread -eq $ThreadId -and $commandThread -eq $ThreadId
    $workspaceMatches = Test-SamePath ([string](Get-StateValue $state 'workspace_root')) $script:normalizedWorkspace
    $stopRequested = Test-Path -LiteralPath $script:stopPath
    $healthy = $identityVerified -and $threadMatches -and $workspaceMatches -and
        $stateStatus -eq 'running' -and -not $stopRequested
    if ($identityVerified) {
        if (-not $threadMatches) { $reason = 'A watcher is running for this directory but is bound to a different thread.' }
        elseif (-not $workspaceMatches) { $reason = 'The running watcher has a different workspace root.' }
        elseif ($stopRequested) { $reason = 'A graceful stop has been requested.' }
        elseif ($stateStatus -ne 'running') { $reason = 'The watcher state is not running.' }
        else { $reason = 'The recorded PID and watcher identity are verified.' }
    }
    return [pscustomobject][ordered]@{
        action = $Action
        healthy = [bool]$healthy
        identity_verified = [bool]$identityVerified
        process_alive = [bool]$processAlive
        pid = $watcherPid
        bridge_root = $script:normalizedBridge
        workspace_root = $script:normalizedWorkspace
        thread_id = $stateThread
        thread_matches = [bool]$threadMatches
        status = $stateStatus
        dry_run = Get-StateValue $state 'dry_run'
        updated_at = Get-StateValue $state 'updated_at'
        stop_requested = [bool]$stopRequested
        message = $reason
    }
}

function Quote-NativeArgument {
    param([string]$Value)
    if ($Value.IndexOfAny([char[]]@([char]0, [char]10, [char]13, [char]34)) -ge 0) {
        throw 'An argument contains an unsupported control character or quote.'
    }
    # Quotes cannot occur in Windows paths; double trailing backslashes before the closing quote.
    $trailingSlashes = [regex]::Match($Value, '\\+$').Value
    return '"' + $Value + $trailingSlashes + '"'
}

try {
    $script:normalizedBridge = Get-NormalizedDirectory $BridgeRoot
    $script:normalizedWorkspace = Get-NormalizedDirectory $WorkspaceRoot
    Assert-NoReparsePath $script:normalizedBridge
    Assert-NoReparsePath $script:normalizedWorkspace
    $workspacePrefix = $script:normalizedWorkspace.TrimEnd('\') + '\'
    if (-not ($script:normalizedBridge.Equals($script:normalizedWorkspace, [StringComparison]::OrdinalIgnoreCase) -or
        $script:normalizedBridge.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase))) {
        throw 'BridgeRoot must be inside WorkspaceRoot.'
    }
    $parsedThreadId = [guid]::Empty
    if (-not [guid]::TryParse($ThreadId, [ref]$parsedThreadId)) { throw 'ThreadId must be a session UUID.' }
    $ThreadId = $parsedThreadId.ToString()
    $script:watcherPath = Join-Path $PSScriptRoot 'watch-results.ps1'
    $script:logsPath = Join-Path $script:normalizedBridge 'logs'
    $script:statePath = Join-Path $script:logsPath 'watch-results-state.json'
    $script:stopPath = Join-Path $script:normalizedBridge 'watch-results.stop'
    if (Test-Path -LiteralPath $script:logsPath) { Assert-NoReparsePath $script:logsPath }
    if (Test-Path -LiteralPath $script:statePath) { Assert-NoReparsePath $script:statePath }
    $current = Get-WatcherStatus

    switch ($Action) {
        'Status' { $current | ConvertTo-Json -Depth 5 }
        'Start' {
            if ($current.identity_verified) {
                $current.message = 'A verified watcher already exists. No second process was started. ' + $current.message
                if ([bool]$current.dry_run -ne $DryRun.IsPresent) {
                    $current.message += ' Its DryRun setting differs from this request; stop it before changing modes.'
                    $current | ConvertTo-Json -Depth 5
                    exit 1
                }
                $current | ConvertTo-Json -Depth 5
                if (-not $current.healthy) { exit 1 }
                break
            }
            if (-not (Test-Path -LiteralPath $script:watcherPath -PathType Leaf)) { throw 'watch-results.ps1 was not found in BridgeRoot.' }
            if ([string]::IsNullOrWhiteSpace($CodexExe)) {
                $CodexExe = (Get-Command codex.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
            }
            $resolvedCodex = Get-Item -LiteralPath $CodexExe -ErrorAction Stop
            if ($resolvedCodex.PSIsContainer -or $resolvedCodex.Extension -ne '.exe') { throw 'CodexExe must be an existing executable file.' }
            $CodexExe = $resolvedCodex.FullName
            $powerShellExe = Join-Path $PSHOME 'pwsh.exe'
            if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) {
                $powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            }
            if (-not (Test-Path -LiteralPath $powerShellExe -PathType Leaf)) { throw 'A PowerShell executable was not found.' }
            [void][IO.Directory]::CreateDirectory($script:logsPath)
            if (Test-Path -LiteralPath $script:stopPath) {
                $stopItem = Get-Item -LiteralPath $script:stopPath -Force
                if ($stopItem.PSIsContainer -or ($stopItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw 'The stop marker is not a regular file; it was not removed.'
                }
                Remove-Item -LiteralPath $script:stopPath -ErrorAction Stop
            }
            $nativeArguments = @('-NoProfile', '-NonInteractive', '-File', (Quote-NativeArgument $script:watcherPath),
                '-BridgeRoot', (Quote-NativeArgument $script:normalizedBridge),
                '-WorkspaceRoot', (Quote-NativeArgument $script:normalizedWorkspace),
                '-ThreadId', (Quote-NativeArgument $ThreadId), '-CodexExe', (Quote-NativeArgument $CodexExe))
            if ($DryRun) { $nativeArguments += '-DryRun' }
            $child = Start-Process -FilePath $powerShellExe -ArgumentList ($nativeArguments -join ' ') -WindowStyle Hidden -WorkingDirectory $script:normalizedWorkspace -PassThru `
                -RedirectStandardOutput (Join-Path $script:logsPath 'watch-results.stdout.log') `
                -RedirectStandardError (Join-Path $script:logsPath 'watch-results.stderr.log')
            if ($child.WaitForExit(1500)) {
                throw ('Watcher startup exited with code ' + $child.ExitCode + '. Inspect logs/watch-results.stderr.log; no healthy process is claimed.')
            }
            $afterStart = Get-WatcherStatus
            if (-not $afterStart.identity_verified -or $afterStart.pid -ne $child.Id) {
                $afterStart.message = 'A watcher process was launched; state registration is not yet verified. Run Status to confirm.'
                $afterStart.status = 'starting'
                $afterStart.healthy = $false
            }
            $afterStart | ConvertTo-Json -Depth 5
        }
        'Stop' {
            if (-not $current.identity_verified) {
                $current.message = 'No matching live watcher was verified. No process was stopped and no stop marker was written.'
                $current | ConvertTo-Json -Depth 5
                break
            }
            if (Test-Path -LiteralPath $script:stopPath) {
                $stopItem = Get-Item -LiteralPath $script:stopPath -Force
                if ($stopItem.PSIsContainer -or ($stopItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'The stop marker is not a regular file.' }
            }
            [IO.File]::WriteAllText($script:stopPath, [DateTimeOffset]::UtcNow.ToString('o'), [Text.UTF8Encoding]::new($false))
            $watcherProcess = Get-Process -Id $current.pid -ErrorAction SilentlyContinue
            if ($null -ne $watcherProcess) { [void]$watcherProcess.WaitForExit(5000) }
            $afterStop = Get-WatcherStatus
            $afterStop.message = 'A graceful stop marker was written. No process was terminated. ' + $afterStop.message
            $afterStop | ConvertTo-Json -Depth 5
        }
    }
} catch {
    [pscustomobject][ordered]@{ action = $Action; healthy = $false; status = 'error'; message = $_.Exception.Message } | ConvertTo-Json -Depth 3
    exit 1
}
