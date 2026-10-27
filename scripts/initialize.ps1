[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$ThreadId,
    [string]$BridgeRoot,
    [string]$CodexExe,
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'bridge.local.json')
)
. (Join-Path $PSScriptRoot 'Bridge.Common.ps1')
$repoRoot = Split-Path $PSScriptRoot -Parent
$WorkspaceRoot = Assert-BridgePath $WorkspaceRoot ([IO.Path]::GetPathRoot($WorkspaceRoot))
if (-not [IO.Directory]::Exists($WorkspaceRoot)) { throw 'WorkspaceRoot must already exist.' }
$parsedThread = [guid]::Empty
if (-not [guid]::TryParse($ThreadId, [ref]$parsedThread)) { throw 'ThreadId must be the UUID of your existing Codex chat.' }
if (-not $BridgeRoot) { $BridgeRoot = Join-Path $WorkspaceRoot '.agent-bridge' }
$BridgeRoot = Assert-BridgePath $BridgeRoot $WorkspaceRoot -AllowMissing
$ConfigPath = Assert-BridgePath $ConfigPath ([IO.Path]::GetPathRoot($ConfigPath)) -AllowMissing -AllowConfig
if (Test-Path -LiteralPath $ConfigPath) { throw 'Configuration already exists; it was not overwritten.' }
if (Test-Path -LiteralPath $BridgeRoot) { throw 'BridgeRoot already exists; choose a new empty runtime path to preserve existing tasks.' }
if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($ConfigPath))) { throw 'The configuration parent directory must exist.' }
if (-not $CodexExe) { $CodexExe = (Get-Command codex.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source }
$CodexExe = Get-BridgeFullPath $CodexExe
if (-not [IO.File]::Exists($CodexExe) -or [IO.Path]::GetExtension($CodexExe) -ne '.exe') { throw 'CodexExe must be an installed native codex.exe.' }
$queueHelp = (& $CodexExe queue --help 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $queueHelp -notmatch '--thread' -or $queueHelp -notmatch '--message') { throw 'This Codex executable does not support queue --thread --message. No runtime was created.' }
foreach ($folder in @('inbox','processing','done','failed','results','reviews','logs','ids','claims')) { [IO.Directory]::CreateDirectory((Join-Path $BridgeRoot $folder)) | Out-Null }
$config = [ordered]@{schema_version=1; workspace_root=$WorkspaceRoot; bridge_root=$BridgeRoot; thread_id=$parsedThread.ToString(); codex_exe=$CodexExe}
foreach ($entry in @(@('ACCEPTANCE.md','ACCEPTANCE.md'), @('WORKBUDDY-PROMPT.md','WORKBUDDY-PROMPT.md'), @('CODEX-PROMPT.md','CODEX-PROMPT.md'))) {
    $source = Get-Content -LiteralPath (Join-Path $repoRoot ('docs\' + $entry[0])) -Raw -Encoding UTF8
    $source = $source.Replace('{{BRIDGE_ROOT}}', $BridgeRoot).Replace('{{WORKSPACE_ROOT}}', $WorkspaceRoot).Replace('{{SCRIPTS_ROOT}}', $PSScriptRoot).Replace('{{CONFIG_PATH}}', $ConfigPath)
    [IO.File]::WriteAllText((Join-Path $BridgeRoot $entry[1]), $source, $script:BridgeUtf8)
}
Write-BridgeJson $ConfigPath $config
[pscustomobject]@{initialized=$true; config=$ConfigPath; bridge_root=$BridgeRoot; watcher_started=$false; next_step='Read the generated WORKBUDDY-PROMPT.md and CODEX-PROMPT.md. Start the results watcher explicitly.'} | ConvertTo-Json
