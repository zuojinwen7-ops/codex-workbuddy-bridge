# Shared filesystem helpers. Windows PowerShell 5.1 / PowerShell 7, no dependencies.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:BridgeUtf8 = New-Object Text.UTF8Encoding($false)

function Get-BridgeFullPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) { throw 'An absolute path is required.' }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -ne [IO.Path]::GetPathRoot($full)) { $full = $full.TrimEnd('\') }
    return $full
}

function Assert-BridgePath([string]$Path, [string]$Root, [switch]$AllowMissing, [switch]$AllowConfig) {
    $full = Get-BridgeFullPath $Path
    $rootPath = Get-BridgeFullPath $Root
    $prefix = $rootPath.TrimEnd('\') + '\'
    if (-not ($full.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))) {
        throw 'Path is outside the authorized directory.'
    }
    if (-not $AllowConfig -and ($full -match '(?i)[\\/](\.codex|\.workbuddy|\.ssh|\.aws|\.azure|\.gnupg)([\\/]|$)' -or
        [IO.Path]::GetFileName($full) -match '(?i)^(\.env(?:\..*)?|auth\.json|credentials?(?:\..*)?|secrets?(?:\..*)?|.*\.(pem|key))$')) {
        throw 'Credential/configuration paths are not allowed as task evidence.'
    }
    $cursor = $full
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse points and directory junctions are not supported.' }
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { break }
        $cursor = $parent.FullName
    }
    if (-not $AllowMissing -and -not (Test-Path -LiteralPath $full)) { throw 'Required file or directory is missing.' }
    return $full
}

function Read-BridgeJson([string]$Path) {
    if ((Get-Item -LiteralPath $Path).Length -gt 1048576) { throw 'Queue JSON exceeds the 1 MiB limit.' }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-BridgeJson([string]$Path, $Value, [switch]$Replace) {
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 25), $script:BridgeUtf8)
        if ($Replace -and [IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function Get-BridgeConfig([string]$Path) {
    $full = Get-BridgeFullPath $Path
    $null = Assert-BridgePath $full ([IO.Path]::GetPathRoot($full)) -AllowConfig
    $config = Read-BridgeJson $full
    $workspace = Assert-BridgePath ([string]$config.workspace_root) ([IO.Path]::GetPathRoot([string]$config.workspace_root))
    $bridge = Assert-BridgePath ([string]$config.bridge_root) $workspace
    if (-not [IO.Directory]::Exists($workspace) -or -not [IO.Directory]::Exists($bridge)) { throw 'Workspace and bridge must be existing directories.' }
    $thread = [guid]::Empty
    if (-not [guid]::TryParse([string]$config.thread_id, [ref]$thread)) { throw 'thread_id must be a Codex chat UUID.' }
    foreach ($folder in @('inbox','processing','done','failed','results','reviews','logs','ids','claims')) {
        $null = Assert-BridgePath (Join-Path $bridge $folder) $workspace
    }
    return $config
}

function Assert-BridgeTaskId([string]$TaskId) {
    if ($TaskId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$') { throw 'Invalid task ID. Use 1-128 letters, digits, hyphens or underscores.' }
}

function Assert-BridgeTask($Task, [string]$TaskId, $Config) {
    Assert-BridgeTaskId $TaskId
    if ([string]$Task.task_id -cne $TaskId) { throw 'The task ID must exactly match its filename.' }
    if ([string]::IsNullOrWhiteSpace([string]$Task.instruction)) { throw 'instruction is required.' }
    $date = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$Task.created_at, [ref]$date)) { throw 'created_at must be an ISO timestamp.' }
    $work = Assert-BridgePath ([string]$Task.work_dir) ([string]$Config.workspace_root)
    if (-not [IO.Directory]::Exists($work)) { throw 'work_dir must be an existing directory.' }
    if (@($Task.allowed_scope).Count -eq 0) { throw 'allowed_scope is required.' }
    foreach ($scope in @($Task.allowed_scope)) {
        if ($scope -notin @('read_file','write_file','analyze','generate_report','run_project_command')) { throw 'Unknown allowed_scope value.' }
    }
    if ($Task.PSObject.Properties['priority'] -and $Task.priority -notin @('normal','high')) { throw 'priority must be normal or high.' }
}

function Get-BridgeTaskPath($Config, [string]$Folder, [string]$TaskId) {
    Assert-BridgeTaskId $TaskId
    return Assert-BridgePath (Join-Path (Join-Path ([string]$Config.bridge_root) $Folder) ($TaskId + '.json')) ([string]$Config.workspace_root) -AllowMissing
}
