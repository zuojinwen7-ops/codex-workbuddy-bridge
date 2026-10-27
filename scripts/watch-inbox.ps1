[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'bridge.local.json'),
    [ValidateRange(1,86400)][int]$TimeoutSeconds = 3600
)
. (Join-Path $PSScriptRoot 'Bridge.Common.ps1')
$config = Get-BridgeConfig $ConfigPath
$inbox = Join-Path $config.bridge_root 'inbox'
function Get-PendingNames { return @(Get-ChildItem -LiteralPath $inbox -Filter '*.json' -File | Sort-Object Name | Select-Object -ExpandProperty Name) }
$watcher = New-Object IO.FileSystemWatcher($inbox, '*.json')
$watcher.NotifyFilter = [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::Size
$eventId = 'BridgeInbox-' + [guid]::NewGuid().ToString('N')
try {
    $null = Register-ObjectEvent -InputObject $watcher -EventName Created -SourceIdentifier ($eventId + '-Created')
    $null = Register-ObjectEvent -InputObject $watcher -EventName Renamed -SourceIdentifier ($eventId + '-Renamed')
    $null = Register-ObjectEvent -InputObject $watcher -EventName Changed -SourceIdentifier ($eventId + '-Changed')
    $null = Register-ObjectEvent -InputObject $watcher -EventName Error -SourceIdentifier ($eventId + '-Error')
    $watcher.EnableRaisingEvents = $true
    $pending = @(Get-PendingNames)
    if ($pending.Count -gt 0) { Write-Output ('PENDING|' + ($pending -join ',')); return }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        # Wait only for this watcher's events. No scan on a periodic schedule.
        $remaining = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalSeconds)
        $event = Wait-Event -Timeout ([Math]::Max(1,$remaining)) | Where-Object { $_.SourceIdentifier.StartsWith($eventId) } | Select-Object -First 1
        if ($null -eq $event) { break }
        if ($event.SourceIdentifier -eq ($eventId + '-Error')) { Write-Output 'ERROR|watcher-buffer|Inspect inbox before restarting the wait.'; return }
        $pending = @(Get-PendingNames)
        if ($pending.Count -gt 0) { Write-Output ('EVENT|' + ($pending -join ',')); return }
        Get-Event | Where-Object { $_.SourceIdentifier.StartsWith($eventId) } | Remove-Event
    }
    Write-Output ('TIMEOUT|' + $TimeoutSeconds)
} finally {
    $watcher.EnableRaisingEvents = $false
    Get-EventSubscriber | Where-Object { $_.SourceIdentifier.StartsWith($eventId) } | Unregister-Event
    Get-Event | Where-Object { $_.SourceIdentifier.StartsWith($eventId) } | Remove-Event
    $watcher.Dispose()
}
