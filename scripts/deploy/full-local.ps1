[CmdletBinding()]
param(
    [string]$Distro = 'DwemerAI4Skyrim3',
    [string]$ClientRoot = 'C:\Modlists\ALMSIVI',
    [ValidateSet('Debug', 'RelWithDebInfo', 'Release')]
    [string]$Configuration = 'Release',
    [string]$EngineSource,
    [string]$BuildRoot,
    [ValidateRange(1024, 65535)]
    [int]$ServerPort = 8089,
    [switch]$SkipServer,
    [switch]$SkipBuild,
    [switch]$SkipClient
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$monorepoRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '..'))
$serverRoot = Join-Path $monorepoRoot 'ALMSIVIserver'
if (-not $EngineSource) { $EngineSource = Join-Path $repoRoot '.work\openmw-edited' }
if (-not $BuildRoot) { $BuildRoot = Join-Path $EngineSource 'MSVC2022_64' }
$EngineSource = [IO.Path]::GetFullPath($EngineSource)
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$ClientRoot = [IO.Path]::GetFullPath($ClientRoot)
$expectedEnginePin = 'f4bec41444214a7903bebd178389ca22ca13f646'
$stageResults = [System.Collections.Generic.List[object]]::new()
$reservedLocalPorts = @(8020, 8021, 8022, 8023, 8024, 8082, 8085, 8086, 12346)

if ($reservedLocalPorts -contains $ServerPort) {
    throw "Port $ServerPort is reserved by another Dwemer service. ALMSIVI uses dedicated port 8089 by default."
}

function Get-CMakeExecutable {
    $command = Get-Command cmake.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $candidates = @(
        'C:\Program Files\CMake\bin\cmake.exe',
        'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe',
        'C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe',
        'C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe',
        'C:\Program Files\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw 'cmake.exe was not found on PATH or in a known Visual Studio installation.'
}

function Convert-ToWslPath {
    param([Parameter(Mandatory)][string]$WindowsPath)

    $converted = (& wsl.exe -d $Distro -- wslpath -a -u $WindowsPath 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Could not convert to a WSL path: $WindowsPath" }
    return ($converted | Select-Object -Last 1).Trim()
}

function Find-MorrowindDataRoot {
    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add('C:\Program Files (x86)\Steam\steamapps\common\Morrowind\Data Files')
    $openmwConfig = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games\OpenMW\openmw.cfg'
    if (Test-Path -LiteralPath $openmwConfig -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($openmwConfig)) {
            if ($line -notmatch '^\s*data\s*=\s*(.+?)\s*$') { continue }
            $candidate = $Matches[1].Trim().Trim('"')
            if ($candidate -ne '') { $candidates.Add($candidate) }
        }
    }
    foreach ($candidate in $candidates) {
        try { $resolved = [IO.Path]::GetFullPath($candidate) } catch { continue }
        if ((Test-Path -LiteralPath (Join-Path $resolved 'Morrowind.esm') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $resolved 'Sound\Vo') -PathType Container)) { return $resolved }
    }
    throw 'Morrowind Data Files could not be found for the local voice catalog import.'
}

function Invoke-RobocopyMirror {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$ExcludeDirectories = @(),
        [string[]]$ExcludeFiles = @()
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Mirror source directory not found: $Source"
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $arguments = @($Source, $Destination, '/MIR', '/R:1', '/W:1', '/NFL', '/NDL', '/NP')
    if ($ExcludeDirectories.Count -gt 0) { $arguments += '/XD'; $arguments += $ExcludeDirectories }
    if ($ExcludeFiles.Count -gt 0) { $arguments += '/XF'; $arguments += $ExcludeFiles }
    & "$env:SystemRoot\System32\robocopy.exe" @arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -gt 7) { throw "robocopy failed with exit code $exitCode while mirroring $Source" }
}

# Refresh the generated exact-pin OpenMW worktree from every tracked overlay file before compiling.
function Sync-OpenMwOverlay {
    param([Parameter(Mandatory)][string]$Destination)

    $overlayPrefix = 'openmw-patches/overlay/'
    $trackedFiles = @(& git -C $repoRoot ls-files -- 'openmw-patches/overlay')
    if ($LASTEXITCODE -ne 0 -or $trackedFiles.Count -eq 0) { throw 'Tracked OpenMW overlay files could not be listed.' }
    $destinationRoot = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
    foreach ($trackedFile in $trackedFiles) {
        if (-not $trackedFile.StartsWith($overlayPrefix, [StringComparison]::Ordinal)) {
            throw "Unexpected OpenMW overlay path: $trackedFile"
        }
        $relativePath = $trackedFile.Substring($overlayPrefix.Length).Replace('/', '\')
        $sourcePath = Join-Path $repoRoot $trackedFile.Replace('/', '\')
        $targetPath = [IO.Path]::GetFullPath((Join-Path $Destination $relativePath))
        if (-not $targetPath.StartsWith($destinationRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "OpenMW overlay path escapes the pinned worktree: $trackedFile"
        }
        New-Item -ItemType Directory -Force -Path (Split-Path $targetPath -Parent) | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
    }
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Update-OpenMwUserConfiguration {
    param([Parameter(Mandatory)][string]$DataRoot)

    $userRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'My Games\OpenMW'
    $openmwConfig = Join-Path $userRoot 'openmw.cfg'
    if (-not (Test-Path -LiteralPath $openmwConfig -PathType Leaf)) {
        throw "OpenMW user configuration not found: $openmwConfig"
    }

    $dataLine = 'data="' + $DataRoot + '"'
    $updated = [System.Collections.Generic.List[string]]::new()
    $dataAdded = $false
    foreach ($line in [IO.File]::ReadAllLines($openmwConfig)) {
        if ($line -match '(?i)^data=.*(?:Deployments[\\/]+ALMSIVI|Modlists[\\/]+ALMSIVI[\\/]+Data)') {
            if (-not $dataAdded) { $updated.Add($dataLine); $dataAdded = $true }
            continue
        }
        if ($line -eq 'content=ALMSIVI.omwscripts') { continue }
        $updated.Add($line)
    }
    if (-not $dataAdded) { $updated.Add($dataLine) }
    $updated.Add('content=ALMSIVI.omwscripts')
    [IO.File]::WriteAllLines($openmwConfig, $updated, [Text.UTF8Encoding]::new($false))

    $launcherConfig = Join-Path $userRoot 'launcher.cfg'
    if (-not (Test-Path -LiteralPath $launcherConfig -PathType Leaf)) { return }
    $launcherLines = [System.Collections.Generic.List[string]]::new()
    $inProfiles = $false
    $profileWritten = $false
    foreach ($line in [IO.File]::ReadAllLines($launcherConfig)) {
        if ($line -eq '[Profiles]') { $inProfiles = $true; $launcherLines.Add($line); continue }
        if ($inProfiles -and $line -match '^\[') {
            if (-not $profileWritten) {
                $launcherLines.Add("ALMSIVI/data=$DataRoot")
                $launcherLines.Add('ALMSIVI/content=ALMSIVI.omwscripts')
                $profileWritten = $true
            }
            $inProfiles = $false
        }
        if ($inProfiles -and $line -match '(?i)^ALMSIVI/data=.*(?:Deployments[\\/]+ALMSIVI|Modlists[\\/]+ALMSIVI[\\/]+Data)') { continue }
        if ($inProfiles -and $line -eq 'ALMSIVI/content=ALMSIVI.omwscripts') { continue }
        $launcherLines.Add($line)
    }
    if ($inProfiles -and -not $profileWritten) {
        $launcherLines.Add("ALMSIVI/data=$DataRoot")
        $launcherLines.Add('ALMSIVI/content=ALMSIVI.omwscripts')
    }
    [IO.File]::WriteAllLines($launcherConfig, $launcherLines, [Text.UTF8Encoding]::new($false))
}

function Install-LaunchHelpers {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][int]$HttpPort
    )

    $compatibilityProfile = Join-Path $Root 'Profiles\Compatibility'
    New-Item -ItemType Directory -Force -Path $compatibilityProfile | Out-Null
    $compatibilityConfig = Join-Path $compatibilityProfile 'openmw.cfg'
    if (-not (Test-Path -LiteralPath $compatibilityConfig -PathType Leaf)) {
        Write-Utf8NoBom -Path $compatibilityConfig -Content @"
user-data=.
data="$Root\Mods\Dynamic Camera"
data="$Root\Mods\Follower Detection Util"
data="$Root\Mods\H3lp Yours3lf"
content=DynamicCamera.omwscripts
content=FollowerDetectionUtil.omwscripts
content=H3lp Yours3lf.esp
"@
    }
    $compatibilityLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [IO.File]::ReadAllLines($compatibilityConfig)) { $compatibilityLines.Add($line) }
    if (-not ($compatibilityLines | Where-Object { $_ -match '^\s*user-data\s*=' })) {
        $compatibilityLines.Insert(0, 'user-data=.')
        [IO.File]::WriteAllLines($compatibilityConfig, $compatibilityLines, [Text.UTF8Encoding]::new($false))
    }
    $compatibilityLauncherConfig = Join-Path $compatibilityProfile 'launcher.cfg'
    if (-not (Test-Path -LiteralPath $compatibilityLauncherConfig -PathType Leaf)) {
        Write-Utf8NoBom -Path $compatibilityLauncherConfig -Content @"
[Settings]
language=English

[Profiles]
currentprofile=ALMSIVI Compatibility
ALMSIVI Compatibility/data=$Root\Mods\Dynamic Camera
ALMSIVI Compatibility/data=$Root\Mods\Follower Detection Util
ALMSIVI Compatibility/data=$Root\Mods\H3lp Yours3lf
ALMSIVI Compatibility/content=DynamicCamera.omwscripts
ALMSIVI Compatibility/content=FollowerDetectionUtil.omwscripts
ALMSIVI Compatibility/content=H3lp Yours3lf.esp

[General]
firstrun=false
"@
    }

    $launchScript = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$engine = Join-Path $PSScriptRoot 'OpenMW\openmw.exe'
$clientConfig = Join-Path $PSScriptRoot 'Config\almsivi-client.conf'
if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) { throw "The ALMSIVI OpenMW executable is missing: $engine" }
if (-not (Test-Path -LiteralPath $clientConfig -PathType Leaf)) { throw "The private ALMSIVI client configuration is missing: $clientConfig" }

& wsl.exe -d DwemerAI4Skyrim3 -u root -- bash -lc 'service postgresql start >/dev/null; service apache2 start >/dev/null; service almsiviserver-worker start >/dev/null'
if ($LASTEXITCODE -ne 0) { throw 'The ALMSIVI WSL services could not be started.' }
$health = Invoke-RestMethod -Uri 'http://127.0.0.1:@ALMSIVI_HTTP_PORT@/ALMSIVIserver/api/v1/health' -TimeoutSec 5
if ($health.schema -ne 'almsivi.health.v1') { throw 'ALMSIVIserver returned an unexpected health response.' }
$env:ALMSIVI_CLIENT_CONFIG = $clientConfig
& $engine
'@
    $launchScript = $launchScript.Replace('@ALMSIVI_HTTP_PORT@', [string]$HttpPort)
    Write-Utf8NoBom -Path (Join-Path $Root 'Launch-ALMSIVI.ps1') -Content $launchScript
    Write-Utf8NoBom -Path (Join-Path $Root 'Play-ALMSIVI.cmd') -Content "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Launch-ALMSIVI.ps1`"`r`nif errorlevel 1 pause`r`n"

    $compatibilityLaunchScript = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$engine = Join-Path $PSScriptRoot 'OpenMW\openmw.exe'
$clientConfig = Join-Path $PSScriptRoot 'Config\almsivi-client.conf'
$profile = Join-Path $PSScriptRoot 'Profiles\Compatibility'
$requiredMods = @(
    (Join-Path $PSScriptRoot 'Mods\Dynamic Camera\DynamicCamera.omwscripts'),
    (Join-Path $PSScriptRoot 'Mods\Follower Detection Util\FollowerDetectionUtil.omwscripts'),
    (Join-Path $PSScriptRoot 'Mods\H3lp Yours3lf\H3lp Yours3lf.esp')
)
if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) { throw "The ALMSIVI OpenMW executable is missing: $engine" }
if (-not (Test-Path -LiteralPath $clientConfig -PathType Leaf)) { throw "The private ALMSIVI client configuration is missing: $clientConfig" }
if (-not (Test-Path -LiteralPath (Join-Path $profile 'openmw.cfg') -PathType Leaf)) { throw "The ALMSIVI compatibility profile is missing: $profile" }
foreach ($requiredMod in $requiredMods) {
    if (-not (Test-Path -LiteralPath $requiredMod -PathType Leaf)) { throw "A required compatibility mod is missing: $requiredMod" }
}

& wsl.exe -d DwemerAI4Skyrim3 -u root -- bash -lc 'service postgresql start >/dev/null; service apache2 start >/dev/null; service almsiviserver-worker start >/dev/null'
if ($LASTEXITCODE -ne 0) { throw 'The ALMSIVI WSL services could not be started.' }
$health = Invoke-RestMethod -Uri 'http://127.0.0.1:@ALMSIVI_HTTP_PORT@/ALMSIVIserver/api/v1/health' -TimeoutSec 5
if ($health.schema -ne 'almsivi.health.v1') { throw 'ALMSIVIserver returned an unexpected health response.' }
$env:ALMSIVI_CLIENT_CONFIG = $clientConfig
& $engine --config $profile
'@
    $compatibilityLaunchScript = $compatibilityLaunchScript.Replace('@ALMSIVI_HTTP_PORT@', [string]$HttpPort)
    Write-Utf8NoBom -Path (Join-Path $Root 'Launch-ALMSIVI-Compatibility.ps1') -Content $compatibilityLaunchScript
    Write-Utf8NoBom -Path (Join-Path $Root 'Play-ALMSIVI-Compatibility.cmd') -Content "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Launch-ALMSIVI-Compatibility.ps1`"`r`nif errorlevel 1 pause`r`n"
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\tools\manage-openmw-profile.ps1') -Destination (Join-Path $Root 'Manage-ALMSIVI-Profile.ps1') -Force
    Write-Utf8NoBom -Path (Join-Path $Root 'Manage-ALMSIVI-Mods.cmd') -Content "@echo off`r`nset `"ALMSIVI_CLIENT_CONFIG=%~dp0Config\almsivi-client.conf`"`r`nwsl.exe -d DwemerAI4Skyrim3 -u root -- bash -lc `"service postgresql start >/dev/null; service apache2 start >/dev/null; service almsiviserver-worker start >/dev/null`"`r`nif errorlevel 1 (`r`n  echo The ALMSIVI WSL services could not be started.`r`n  pause`r`n  exit /b 1`r`n)`r`nstart `"ALMSIVI OpenMW Launcher`" `"%~dp0OpenMW\openmw-launcher.exe`"`r`n"
    Write-Utf8NoBom -Path (Join-Path $Root 'Manage-ALMSIVI-Compatibility-Mods.cmd') -Content "@echo off`r`nstart `"ALMSIVI Compatibility Mod Manager`" powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Manage-ALMSIVI-Profile.ps1`" -Root `"%~dp0`" -ProfileName Compatibility`r`n"
    Write-Utf8NoBom -Path (Join-Path $Root 'README.txt') -Content @"
ALMSIVI OpenMW local installation

Play: Play-ALMSIVI.cmd
Play with the recommended compatibility mods: Play-ALMSIVI-Compatibility.cmd
Manage OpenMW content: Manage-ALMSIVI-Mods.cmd
Manage compatibility mods and native OpenMW content: Manage-ALMSIVI-Compatibility-Mods.cmd
Management UI: http://127.0.0.1:$HttpPort/ALMSIVIserver/manage

Install a mod by extracting it into its own Mods\Mod Name folder. Open the
ALMSIVI Compatibility Mod Manager, enable the folder and its content files,
set their order, then save. The manager backs up the profile before changes.
Use Manage-ALMSIVI-Mods.cmd for OpenMW engine and general launcher settings.

F6 opens typed conversation. F7 stops current ALMSIVI work. F8 opens Actor Actions.
The Master Menu is linked inside the conversation and action panels.
Rebind all ALMSIVI inputs under Options > Scripts > ALMSIVI.
"@

    $desktop = [Environment]::GetFolderPath('Desktop')
    $shell = New-Object -ComObject WScript.Shell
    foreach ($shortcut in @(
        @{ Name = 'Play ALMSIVI.lnk'; Target = (Join-Path $Root 'Play-ALMSIVI.cmd'); Icon = (Join-Path $Root 'OpenMW\openmw.exe') },
        @{ Name = 'Play ALMSIVI - Compatibility.lnk'; Target = (Join-Path $Root 'Play-ALMSIVI-Compatibility.cmd'); Icon = (Join-Path $Root 'OpenMW\openmw.exe') },
        @{ Name = 'ALMSIVI Mod Manager.lnk'; Target = (Join-Path $Root 'Manage-ALMSIVI-Mods.cmd'); Icon = (Join-Path $Root 'OpenMW\openmw-launcher.exe') },
        @{ Name = 'ALMSIVI Compatibility Mod Manager.lnk'; Target = (Join-Path $Root 'Manage-ALMSIVI-Compatibility-Mods.cmd'); Icon = (Join-Path $Root 'OpenMW\openmw-launcher.exe') }
    )) {
        $link = $shell.CreateShortcut((Join-Path $desktop $shortcut.Name))
        $link.TargetPath = $shortcut.Target
        $link.WorkingDirectory = $Root
        $link.IconLocation = $shortcut.Icon
        $link.Save()
    }
}

function Invoke-Stage {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Action)

    Write-Host "`n=== $Name ===" -ForegroundColor Cyan
    try {
        & $Action
        $stageResults.Add([pscustomobject]@{ Stage = $Name; Status = 'SUCCESS' })
        Write-Host "SUCCESS: $Name" -ForegroundColor Green
    } catch {
        $stageResults.Add([pscustomobject]@{ Stage = $Name; Status = 'FAILED' })
        Write-Host "FAILED: $Name" -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

try {
    if (-not $SkipServer) {
        Invoke-Stage -Name 'Stage 1 - ALMSIVIserver to WSL' -Action {
            $serverDeploy = Join-Path $serverRoot 'scripts\deploy-local-wsl.sh'
            if (-not (Test-Path -LiteralPath $serverDeploy -PathType Leaf)) { throw "Server deploy script not found: $serverDeploy" }
            $serverDeployWsl = Convert-ToWslPath -WindowsPath $serverDeploy
            $serverRootWsl = Convert-ToWslPath -WindowsPath $serverRoot
            & wsl.exe -d $Distro -u root -- env "ALMSIVI_HTTP_PORT=$ServerPort" bash $serverDeployWsl $serverRootWsl
            if ($LASTEXITCODE -ne 0) { throw "ALMSIVIserver WSL deploy failed with exit code $LASTEXITCODE." }

            $gameDataRoot = Find-MorrowindDataRoot
            $gameDataWsl = Convert-ToWslPath -WindowsPath $gameDataRoot
            & wsl.exe -d $Distro -u root -- env ALMSIVI_CONFIG=/etc/almsiviserver/server.php php /var/www/html/ALMSIVIserver/scripts/import-morrowind-voices.php $gameDataWsl
            if ($LASTEXITCODE -ne 0) { throw "Morrowind voice catalog import failed with exit code $LASTEXITCODE." }
        }
    }

    if (-not $SkipClient) {
        Invoke-Stage -Name 'Stage 2 - Build and Deploy ALMSIVI OpenMW Client' -Action {
            if (-not (Test-Path -LiteralPath (Join-Path $EngineSource '.git'))) { throw "Pinned OpenMW source not found: $EngineSource" }
            $engineHead = (& git -C $EngineSource rev-parse HEAD).Trim()
            if ($LASTEXITCODE -ne 0 -or $engineHead -ne $expectedEnginePin) {
                throw "Expected OpenMW pin $expectedEnginePin, found $engineHead"
            }
            Sync-OpenMwOverlay -Destination $EngineSource
            if (-not $SkipBuild) {
                $cmake = Get-CMakeExecutable
                foreach ($target in @('openmw', 'openmw-launcher')) {
                    & $cmake --build $BuildRoot --config $Configuration --target $target
                    if ($LASTEXITCODE -ne 0) { throw "OpenMW target '$target' failed with exit code $LASTEXITCODE." }
                }
            }

            $runtimeSource = Join-Path $BuildRoot $Configuration
            $dataSource = Join-Path $repoRoot 'almsivi\files'
            $runtimeTarget = Join-Path $ClientRoot 'OpenMW'
            $dataTarget = Join-Path $ClientRoot 'Data'
            $configTarget = Join-Path $ClientRoot 'Config\almsivi-client.conf'
            foreach ($required in @((Join-Path $runtimeSource 'openmw.exe'), (Join-Path $runtimeSource 'openmw-launcher.exe'), (Join-Path $dataSource 'ALMSIVI.omwscripts'))) {
                if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required client artifact not found: $required" }
            }

            $driveRoot = [IO.Path]::GetPathRoot($ClientRoot)
            if ($ClientRoot.TrimEnd('\') -eq $driveRoot.TrimEnd('\')) { throw "Refusing to deploy to a drive root: $ClientRoot" }
            New-Item -ItemType Directory -Force -Path $ClientRoot, (Join-Path $ClientRoot 'Mods'), (Split-Path $configTarget -Parent) | Out-Null
            Invoke-RobocopyMirror -Source $runtimeSource -Destination $runtimeTarget -ExcludeFiles @('*_tests.exe', '*.pdb')

            $cacheTarget = Join-Path $dataTarget 'ALMSIVI\cache'
            $cacheBackup = $null
            try {
                if (Test-Path -LiteralPath $cacheTarget -PathType Container) {
                    $cacheBackup = Join-Path ([IO.Path]::GetTempPath()) ('almsivi-cache-' + [guid]::NewGuid().ToString('N'))
                    New-Item -ItemType Directory -Force -Path $cacheBackup | Out-Null
                    Invoke-RobocopyMirror -Source $cacheTarget -Destination $cacheBackup
                }
                Invoke-RobocopyMirror -Source $dataSource -Destination $dataTarget -ExcludeDirectories @((Join-Path $dataSource 'scripts\ALMSIVI\tests'))
                if ($cacheBackup) {
                    New-Item -ItemType Directory -Force -Path $cacheTarget | Out-Null
                    Invoke-RobocopyMirror -Source $cacheBackup -Destination $cacheTarget
                }
            } finally {
                if ($cacheBackup -and (Test-Path -LiteralPath $cacheBackup)) { Remove-Item -LiteralPath $cacheBackup -Recurse -Force }
            }

            & (Join-Path $PSScriptRoot 'configure-local-client.ps1') -Distro $Distro -Output $configTarget -MediaCacheRoot $cacheTarget -ServerPort $ServerPort
            Update-OpenMwUserConfiguration -DataRoot $dataTarget
            Install-LaunchHelpers -Root $ClientRoot -HttpPort $ServerPort

            $sourceHash = (Get-FileHash -LiteralPath (Join-Path $runtimeSource 'openmw.exe') -Algorithm SHA256).Hash
            $deployedHash = (Get-FileHash -LiteralPath (Join-Path $runtimeTarget 'openmw.exe') -Algorithm SHA256).Hash
            if ($sourceHash -ne $deployedHash) { throw 'The deployed openmw.exe hash does not match the build output.' }
            $env:ALMSIVI_CLIENT_CONFIG = $configTarget
            & (Join-Path $runtimeTarget 'openmw.exe') --version
            if ($LASTEXITCODE -ne 0) { throw 'The deployed ALMSIVI OpenMW executable failed its version probe.' }
            Write-Host "Client: $ClientRoot"
            Write-Host "Private config: $configTarget"
        }
    }
} catch {
    Write-Host "`n=== Deployment Summary ===" -ForegroundColor White
    foreach ($result in $stageResults) {
        $color = if ($result.Status -eq 'SUCCESS') { 'Green' } else { 'Red' }
        Write-Host ("{0} - {1}" -f $result.Status, $result.Stage) -ForegroundColor $color
    }
    Write-Host 'Deployment finished with failures.' -ForegroundColor Red
    exit 1
}

Write-Host "`n=== Deployment Summary ===" -ForegroundColor White
foreach ($result in $stageResults) {
    Write-Host ("{0} - {1}" -f $result.Status, $result.Stage) -ForegroundColor Green
}
Write-Host 'Deployment completed successfully.' -ForegroundColor Green
exit 0
