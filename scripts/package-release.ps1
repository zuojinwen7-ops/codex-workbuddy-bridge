[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist'))
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$version = (Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid VERSION.' }
$tracked = @(& git -C $repoRoot ls-files)
if ($LASTEXITCODE -ne 0 -or $tracked.Count -eq 0) { throw 'Initialize Git and stage the reviewed source files before packaging.' }
foreach ($path in $tracked) {
    if ($path -match '(?i)(^|/)(\.test-runs|\.agent-bridge|runtime|dist|logs|inbox|results|reviews|processing|claims|ids)(/|$)' -or
        $path -match '(?i)(\.local\.json|\.log|\.zip|\.png|\.jpg|\.tmp)$' -or $path -match '(?i)(^|/)\.env') { throw ('Refusing to package private/runtime file: ' + $path) }
    if ((Get-Item -LiteralPath (Join-Path $repoRoot $path) -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Refusing a reparse-point source.' }
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$zipPath = Join-Path $OutputDirectory ('codex-workbuddy-bridge-v' + $version + '.zip')
if (Test-Path -LiteralPath $zipPath) { throw 'Release archive already exists; it was not overwritten.' }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stream = [IO.File]::Open($zipPath,[IO.FileMode]::CreateNew)
try {
    $zip = New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    try {
        foreach ($path in $tracked) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,(Join-Path $repoRoot $path),('codex-workbuddy-bridge/' + $path),[IO.Compression.CompressionLevel]::Optimal) }
    } finally { $zip.Dispose() }
} finally { $stream.Dispose() }
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[IO.File]::WriteAllText(($zipPath + '.sha256'),($hash + '  ' + [IO.Path]::GetFileName($zipPath) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
[pscustomobject]@{archive=$zipPath;files=$tracked.Count;sha256=$hash;scope='Tracked source files only; no runtime or real execution records'} | ConvertTo-Json
