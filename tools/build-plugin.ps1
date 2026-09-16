#requires -Version 5.1
[CmdletBinding()]
param([string]$KenshiRoot = 'E:\SteamLibrary\steamapps\common\Kenshi')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$parent = Split-Path -Parent $project
$KenshiRoot = (Resolve-Path -LiteralPath $KenshiRoot).ProviderPath
$stage = Join-Path $project 'mod\Freeloader'
$deps = Join-Path $parent 'KenshiLib_Examples_deps'
$toolchain = Join-Path $parent 'toolchain'
$vc64 = Join-Path $toolchain 'vc100-extract\Program Files(64)\Microsoft Visual Studio 10.0\VC'
$vcHeaders = Join-Path $toolchain 'vc100-x86-extract\Program Files\Microsoft Visual Studio 10.0\VC\include'
$sdk = Join-Path $toolchain 'sdk71-build-extract\Program Files\Microsoft SDKs\Windows\v7.1'
$compiler = Join-Path $vc64 'bin\amd64\cl.exe'
$linker = Join-Path $vc64 'bin\amd64\link.exe'
$dumpbin = Join-Path $vc64 'bin\amd64\dumpbin.exe'
$source = Join-Path $project 'plugin\Freeloader.cpp'
$tests = Join-Path $project 'tests\StreamingPolicyTests.cpp'
$verifier = Join-Path $PSScriptRoot 'verify-native.py'
$installedMod = Join-Path $KenshiRoot 'mods\Freeloader\Freeloader.mod'
$readme = Join-Path $stage 'README.txt'
$includes = @(
    (Join-Path $deps 'KenshiLib\Include'),
    (Join-Path $deps 'KenshiLib\Include\ogre'),
    (Join-Path $deps 'KenshiLib\Include\mygui'),
    (Join-Path $deps 'boost_1_60_0'), $vcHeaders, (Join-Path $sdk 'Include')
)
$libraries = @(
    (Join-Path $deps 'KenshiLib\Libraries'),
    (Join-Path $vc64 'lib\amd64'), (Join-Path $sdk 'Lib\x64')
)

function Get-Evidence([string]$Path) {
    $file = Get-Item -LiteralPath $Path
    [pscustomobject]@{
        Path = $file.FullName
        Length = $file.Length
        LastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
        SHA256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
}

foreach ($path in @($compiler, $linker, $dumpbin, $source, $tests, $verifier,
        $installedMod, $readme, (Join-Path $stage 'RE_Kenshi.json'),
        (Join-Path $stage 'Freeloader.ini'))) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing build input: $path" }
}
foreach ($path in ($includes + $libraries)) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Missing toolchain/dependency directory: $path" }
}
if ((Get-Item -LiteralPath $installedMod).Length -ne 46) {
    throw 'The installed genuine Freeloader.mod must be 46 bytes; no replacement will be synthesized.'
}
$compilerVersion = (Get-Item -LiteralPath $compiler).VersionInfo.FileVersion
if ($compilerVersion -notmatch '^16\.') { throw "Expected VC10 compiler, found: $compilerVersion" }
$python = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$manifest = Get-Content -LiteralPath (Join-Path $stage 'RE_Kenshi.json') -Raw | ConvertFrom-Json
if (@($manifest.Plugins).Count -ne 1 -or $manifest.Plugins[0] -cne 'Freeloader.dll') {
    throw 'RE_Kenshi.json must name exactly Freeloader.dll.'
}

# Every invocation retains its own DLL, linker PDB, logs, inputs and package.
$buildId = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$buildDir = Join-Path $project "build\releases\$buildId"
$package = Join-Path $buildDir 'package'
$null = New-Item -ItemType Directory -Path $package
$commands = New-Object 'System.Collections.Generic.List[object]'

function Invoke-Recorded([string]$Executable, [string[]]$Arguments, [string]$LogName) {
    $log = Join-Path $buildDir $LogName
    # Windows PowerShell can classify native stderr as an ErrorRecord even on success.
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $Executable @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    $lines = @($output | ForEach-Object { $_.ToString() })
    $lines | Set-Content -LiteralPath $log -Encoding UTF8
    $commands.Add([pscustomobject]@{ Executable = $Executable; Arguments = $Arguments; ExitCode = $code; Log = $log })
    if ($code -ne 0) { throw "Command failed ($code): $Executable. See $log`n$($lines -join [Environment]::NewLine)" }
    return ($lines -join [Environment]::NewLine)
}

$savedEnvironment = @{}
foreach ($name in @('PATH', 'INCLUDE', 'LIB', 'LIBPATH', 'CL', '_CL_', 'LINK', '_LINK_', 'PYTHONOPTIMIZE')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$record = [ordered]@{
    SchemaVersion = 1; BuildId = $buildId; Status = 'building'
    StartedUtc = [DateTime]::UtcNow.ToString('o'); KenshiRoot = $KenshiRoot
    Configuration = 'Release'; Architecture = 'x64'; CompilerVersion = $compilerVersion
    BuildDirectory = $buildDir; Commands = $commands
}
$recordPath = Join-Path $buildDir 'build-record.json'
Push-Location $project
try {
    Write-Host "Verifying native contract; evidence directory: $buildDir"
    # The native verifier uses assertions; inherited Python optimization must not disable them.
    [Environment]::SetEnvironmentVariable('PYTHONOPTIMIZE', $null, 'Process')
    $null = Invoke-Recorded $python @($verifier, '--game', $KenshiRoot) 'verify-native.log'
    $contractHeader = Join-Path $project 'plugin\NativeContract.h'
    $contractJson = Join-Path $project 'build\native-contract.json'
    foreach ($path in @($contractHeader, $contractJson)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Verifier did not produce: $path" }
    }
    $contract = Get-Content -LiteralPath $contractJson -Raw | ConvertFrom-Json
    if ($contract.result -cne 'PASS') { throw 'Native contract did not report PASS.' }
    $record.RuntimeInputs = @(
        Get-Evidence $contract.engine
        Get-Evidence (Join-Path $KenshiRoot 'KenshiLib.dll')
        Get-Evidence (Join-Path $KenshiRoot 'RE_Kenshi\RVAs\Steam_1.0.65.br')
    )
    if ($record.RuntimeInputs[0].SHA256 -ne $contract.engine_sha256 -or
        $record.RuntimeInputs[1].SHA256 -ne $contract.kenshilib_sha256 -or
        $record.RuntimeInputs[2].SHA256 -ne $contract.rva_sha256) {
        throw 'Installed binaries/RVAs changed during native verification.'
    }
    Copy-Item -LiteralPath $contractHeader -Destination (Join-Path $buildDir 'NativeContract.h')
    Copy-Item -LiteralPath $contractJson -Destination (Join-Path $package 'native-contract.json')
    $record.Inputs = @(
        Get-Evidence $verifier
        Get-Evidence (Join-Path $PSScriptRoot 'inspect-loading.py')
        Get-Evidence $PSCommandPath
        Get-Evidence $compiler
        Get-Evidence $linker
        Get-Evidence $dumpbin
        Get-Evidence $contractJson
        Get-Evidence $installedMod
        Get-ChildItem -LiteralPath (Join-Path $project 'plugin'), (Join-Path $project 'tests'), (Join-Path $project 'src') -Recurse -File |
            Where-Object { $_.Extension -in @('.cpp', '.h', '.hpp') } |
            ForEach-Object { Get-Evidence $_.FullName }
    )
    foreach ($name in @('RE_Kenshi.json', 'Freeloader.ini')) {
        Copy-Item -LiteralPath (Join-Path $stage $name) -Destination (Join-Path $package $name)
    }
    Copy-Item -LiteralPath $readme -Destination (Join-Path $package 'README.txt')
    Copy-Item -LiteralPath $installedMod -Destination (Join-Path $package 'Freeloader.mod')
    if ((Get-Evidence $installedMod).SHA256 -ne (Get-Evidence (Join-Path $package 'Freeloader.mod')).SHA256) {
        throw 'Freeloader.mod copy hash mismatch.'
    }

    $env:PATH = (Join-Path $vc64 'bin\amd64') + ';' + $env:PATH
    $env:INCLUDE = $includes -join ';'
    $env:LIB = $libraries -join ';'
    foreach ($name in @('LIBPATH', 'CL', '_CL_', 'LINK', '_LINK_')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    Push-Location $buildDir
    try {
        # Keep test assertions enabled and test exception semantics separate from the plugin.
        Write-Host 'Compiling and running portable streaming policy tests...'
        $null = Invoke-Recorded $compiler @('/nologo', '/O2', '/EHsc', '/MD', '/W3', '/Zi',
            '/FoStreamingPolicyTests.obj', '/FdStreamingPolicyTests-compile.pdb',
            '/FeStreamingPolicyTests.exe', $tests, '/link', '/MACHINE:X64', '/DEBUG',
            '/INCREMENTAL:NO', '/PDB:StreamingPolicyTests.pdb') 'test-compile.log'
        $testOutput = Invoke-Recorded (Join-Path $buildDir 'StreamingPolicyTests.exe') @() 'tests.log'
        Write-Host $testOutput
        $record.TestsPassed = $true

        # /GL and /LTCG preserve the member-function addresses used by GetRealAddress.
        Write-Host 'Compiling Freeloader with VC10 Release x64...'
        $null = Invoke-Recorded $compiler @('/nologo', '/c', '/O2', '/GL', '/Gy', '/Oi',
            '/MD', '/EHsc', '/W3', '/Zi', '/DNDEBUG', '/D_WINDOWS', '/DWIN32', '/D_WIN64',
            '/DUNICODE', '/D_UNICODE', '/D_CRT_SECURE_NO_WARNINGS', '/DBOOST_ALL_NO_LIB',
            '/DBOOST_ERROR_CODE_HEADER_ONLY', '/DBOOST_SYSTEM_NO_DEPRECATED',
            '/FoFreeloader.obj', '/FdFreeloader-compile.pdb', $source) 'plugin-compile.log'
        $null = Invoke-Recorded $linker @('/nologo', '/DLL', '/MACHINE:X64', '/SUBSYSTEM:WINDOWS',
            '/LTCG', '/DEBUG', '/INCREMENTAL:NO', '/OPT:REF', '/OPT:ICF', '/MANIFEST:NO',
            '/OUT:Freeloader.dll', '/IMPLIB:Freeloader.lib', '/PDB:Freeloader.pdb',
            'Freeloader.obj', 'KenshiLib.lib', 'OgreMain_x64.lib', 'MyGUIEngine_x64.lib',
            'kernel32.lib', 'user32.lib', 'advapi32.lib') 'plugin-link.log'

        $exports = Invoke-Recorded $dumpbin @('/nologo', '/exports', 'Freeloader.dll') 'exports.log'
        $headers = Invoke-Recorded $dumpbin @('/nologo', '/headers', 'Freeloader.dll') 'headers.log'
        $imports = Invoke-Recorded $dumpbin @('/nologo', '/imports', 'Freeloader.dll') 'imports.log'
        $dependents = Invoke-Recorded $dumpbin @('/nologo', '/dependents', 'Freeloader.dll') 'dependents.log'
        if ($exports -cnotmatch '(?m)^[ \t]*\d+[ \t]+[0-9A-Fa-f]+[ \t]+[0-9A-Fa-f]+[ \t]+\?startPlugin@@YAXXZ(?:[ \t]+=[ \t]+[^\r\n]+)?[ \t]*\r?$') {
            throw 'Missing C++ export ?startPlugin@@YAXXZ.'
        }
        if ($headers -notmatch '(?im)^\s*8664 machine \(x64\)' -or $headers -notmatch '(?im)^\s*20B magic # \(PE32\+\)') {
            throw 'Freeloader.dll is not PE32+ x64.'
        }
        $importNames = @([regex]::Matches($dependents, '(?im)^\s*([a-z0-9_.-]+\.dll)\s*$') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        if ($importNames -notcontains 'KenshiLib.dll' -or $importNames -notcontains 'MSVCR100.dll') {
            throw 'Expected KenshiLib.dll and Release VC10 MSVCR100.dll imports.'
        }
        foreach ($name in $importNames) {
            if ($name -match '^(msvc[pr]|vcruntime|ucrtbase|api-ms-win-crt)' -and
                $name -notmatch '^MSVC[PR]100\.dll$') {
                throw "Unexpected non-Release/VC10 runtime import: $name"
            }
        }
        $record.BinaryChecks = [ordered]@{ Export = '?startPlugin@@YAXXZ'; Machine = '8664'; Imports = $importNames }
    } finally { Pop-Location }

    # Detect source changes during compilation before publishing a mixed build.
    foreach ($inputFile in ($record.Inputs + $record.RuntimeInputs)) {
        if ((Get-Evidence $inputFile.Path).SHA256 -ne $inputFile.SHA256) {
            throw "Build input changed during compilation: $($inputFile.Path)"
        }
    }
    foreach ($name in @('Freeloader.dll', 'Freeloader.pdb')) {
        Copy-Item -LiteralPath (Join-Path $buildDir $name) -Destination (Join-Path $package $name)
    }
    $record.Artifacts = @(Get-ChildItem -LiteralPath $package -File | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; File = (Get-Evidence $_.FullName) }
    })
    $record.Evidence = @(Get-ChildItem -LiteralPath $buildDir -Filter '*.log' -File | ForEach-Object { Get-Evidence $_.FullName })
    $record.Status = 'verified'
    $record.CompletedUtc = [DateTime]::UtcNow.ToString('o')
    $record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $recordPath -Encoding UTF8
    foreach ($artifact in $record.Artifacts) {
        $destination = Join-Path $stage $artifact.Name
        Copy-Item -LiteralPath $artifact.File.Path -Destination $destination -Force
        if ((Get-Evidence $destination).SHA256 -ne $artifact.File.SHA256) { throw "Stage hash mismatch: $destination" }
    }
    # Publish the record last so deployment rejects an incomplete stage update.
    Copy-Item -LiteralPath $recordPath -Destination (Join-Path $stage 'build-record.json') -Force
    Write-Host "BUILD_OK: $stage"
    Write-Host "Retained DLL/PDB and evidence: $buildDir"
} catch {
    $record.Status = 'failed'
    $record.Error = $_.Exception.Message
    $record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $recordPath -Encoding UTF8
    throw
} finally {
    Pop-Location
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
}
