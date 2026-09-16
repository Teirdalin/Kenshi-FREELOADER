#requires -Version 5.1
[CmdletBinding()]
param([string]$KenshiRoot = 'E:\SteamLibrary\steamapps\common\Kenshi')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$KenshiRoot = (Resolve-Path -LiteralPath $KenshiRoot).ProviderPath
$stage = Join-Path $project 'mod\Freeloader'
$target = Join-Path $KenshiRoot 'mods\Freeloader'

function Assert-KenshiClosed {
    $running = @(Get-Process -ErrorAction Stop | Where-Object { $_.ProcessName -match '^kenshi(?:_x64|_x32)?$' })
    if ($running.Count -gt 0) { throw 'Close Kenshi before deployment. No game process will be stopped by this script.' }
}

function Get-Hash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

Assert-KenshiClosed
$installedMod = Join-Path $target 'Freeloader.mod'
if (-not (Test-Path -LiteralPath $installedMod -PathType Leaf) -or (Get-Item -LiteralPath $installedMod).Length -ne 46) {
    throw 'Expected the existing genuine 46-byte installed Freeloader.mod. Deployment never creates or replaces it.'
}
$recordPath = Join-Path $stage 'build-record.json'
$record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
if ($record.SchemaVersion -ne 1 -or $record.Status -ne 'verified' -or -not $record.TestsPassed) {
    throw 'Deployment requires a verified build record with passing offline tests.'
}
if ($record.KenshiRoot -ne $KenshiRoot) { throw 'Rebuild with this KenshiRoot so the native contract matches the deployment target.' }
$retainedRecord = Join-Path $record.BuildDirectory 'build-record.json'
$recordHash = Get-Hash $recordPath
if ($recordHash -ne (Get-Hash $retainedRecord)) { throw 'Staged build record differs from the retained build record.' }
foreach ($runtimeFile in $record.RuntimeInputs) {
    if ((Get-Hash $runtimeFile.Path) -ne $runtimeFile.SHA256) {
        throw "Installed binary/RVAs changed since native verification: $($runtimeFile.Path). Rebuild before deploying."
    }
}
$expected = @{}
foreach ($artifact in $record.Artifacts) {
    if ($artifact.Name -ne [IO.Path]::GetFileName($artifact.Name) -or $expected.ContainsKey($artifact.Name)) {
        throw 'Invalid or duplicate artifact name in build record.'
    }
    $expected[$artifact.Name] = $artifact.File.SHA256
    if ((Get-Hash (Join-Path $stage $artifact.Name)) -ne $artifact.File.SHA256 -or
        (Get-Hash $artifact.File.Path) -ne $artifact.File.SHA256) {
        throw "Staged or retained artifact changed: $($artifact.Name). Rebuild before deploying."
    }
}
foreach ($name in @('Freeloader.dll', 'Freeloader.pdb', 'RE_Kenshi.json', 'Freeloader.ini', 'native-contract.json', 'Freeloader.mod', 'README.txt')) {
    if (-not $expected.ContainsKey($name)) { throw "Build record is missing: $name" }
}
if ((Get-Hash $installedMod) -ne $expected['Freeloader.mod']) { throw 'Installed Freeloader.mod changed since this build.' }

# Install user-facing files only; native-contract/build-record evidence stays in the project.
$copyNames = @('Freeloader.dll', 'RE_Kenshi.json', 'README.txt')
$installedIni = Join-Path $target 'Freeloader.ini'
if (-not (Test-Path -LiteralPath $installedIni)) { $copyNames += 'Freeloader.ini' }
$backupId = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$backup = Join-Path $project "build\deployments\$backupId"
$previous = Join-Path $backup 'previous-install'
$null = New-Item -ItemType Directory -Path $previous
$before = @{}
$report = [ordered]@{
    BuildId = $record.BuildId; BuildDirectory = $record.BuildDirectory
    Target = $target; StartedUtc = [DateTime]::UtcNow.ToString('o'); Status = 'preparing'
    PreviousFiles = @(); InstalledFiles = @()
}
$reportPath = Join-Path $backup 'deployment-record.json'
try {
    Assert-KenshiClosed
    foreach ($name in @('Freeloader.dll', 'RE_Kenshi.json', 'README.txt', 'Freeloader.ini', 'Freeloader.mod')) {
        $path = Join-Path $target $name
        if (Test-Path -LiteralPath $path) {
            $file = Get-Item -LiteralPath $path
            if ($file.PSIsContainer) { throw "Expected a file: $path" }
            $hash = Get-Hash $path
            $saved = Join-Path $previous $name
            Copy-Item -LiteralPath $path -Destination $saved
            if ((Get-Hash $saved) -ne $hash) { throw "Backup hash mismatch: $name" }
            $before[$name] = $hash
            $report.PreviousFiles += [pscustomobject]@{
                Name = $name; SHA256 = $hash; Backup = $saved; LastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
            }
        }
    }
    $report.Status = 'backed-up'
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    foreach ($name in $copyNames) {
        Assert-KenshiClosed
        $sourcePath = Join-Path $stage $name
        $destination = Join-Path $target $name
        if ((Get-Hash $sourcePath) -ne $expected[$name]) { throw "Stage changed during deployment: $name" }
        if ($before.ContainsKey($name)) {
            if ((Get-Hash $destination) -ne $before[$name]) { throw "Installed file changed after backup: $name" }
        } elseif (Test-Path -LiteralPath $destination) {
            throw "Installed file appeared after preflight: $name"
        }
        Copy-Item -LiteralPath $sourcePath -Destination $destination -Force
        if ((Get-Hash $destination) -ne $expected[$name]) { throw "Installed hash mismatch: $name" }
        $report.InstalledFiles += [pscustomobject]@{ Name = $name; SHA256 = $expected[$name] }
        $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    }
    foreach ($name in @('Freeloader.mod', 'Freeloader.ini')) {
        if ($before.ContainsKey($name) -and (Get-Hash (Join-Path $target $name)) -ne $before[$name]) {
            throw "Preserved file changed during deployment: $name"
        }
    }
    foreach ($file in $report.InstalledFiles) {
        if ((Get-Hash (Join-Path $target $file.Name)) -ne $file.SHA256) { throw "Final installed hash mismatch: $($file.Name)" }
    }
    $report.Status = 'deployed'
    $report.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-Host "DEPLOY_OK: $target"
    Write-Host "Previous files and SHA256 evidence: $backup"
    Write-Host "Matching DLL/PDB retained at: $($record.BuildDirectory)"
} catch {
    $report.Status = 'failed'
    $report.Error = $_.Exception.Message
    $report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    Write-Warning "Deployment did not complete. Exact previous files and any completed copies are recorded at $backup"
    throw
}
