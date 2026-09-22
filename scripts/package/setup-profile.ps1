[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$GameData,
    [Parameter(Mandatory = $true)][string]$ProfileRoot,
    [string]$Distro = 'DwemerAI4Skyrim3',
    [ValidateRange(1024, 65535)][int]$ProxyPort = 7514
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$packageRoot = Split-Path $PSScriptRoot -Parent
$engine = Join-Path $packageRoot 'bin\lorkhan-openmw.exe'
$GameData = [IO.Path]::GetFullPath($GameData)
$ProfileRoot = [IO.Path]::GetFullPath($ProfileRoot)
foreach ($path in @($GameData, $ProfileRoot, $packageRoot)) {
    if ($path -match '[\r\n"&]') { throw 'Choose paths without quotes, ampersands or line breaks.' }
}
if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) { throw 'Run this script from the extracted LORKHAN runtime package.' }
if (-not (Test-Path -LiteralPath (Join-Path $GameData 'Morrowind.esm') -PathType Leaf)) { throw 'GameData must point to your legally installed Morrowind Data Files directory.' }
if (Test-Path -LiteralPath $ProfileRoot) { throw 'Choose a new, empty profile path. Existing profiles and saves are never overwritten.' }

# A separate config chain and data directory keep stock OpenMW and older ALMSIVI profiles untouched.
New-Item -ItemType Directory -Path $ProfileRoot | Out-Null
$aiData = Join-Path $ProfileRoot 'AIData'
$cache = Join-Path $aiData 'LORKHAN\cache'
$privateConfig = Join-Path $ProfileRoot 'lorkhan-client.conf'
& (Join-Path $PSScriptRoot 'configure-local-client.ps1') -Distro $Distro -Output $privateConfig -MediaCacheRoot $cache -ProxyPort $ProxyPort
$lines = @(
    'replace=config', 'replace=content', 'replace=data', 'replace=fallback-archive',
    ('user-data="' + $ProfileRoot + '"'),
    ('data="' + $GameData + '"'),
    ('data="' + (Join-Path $packageRoot 'bin\resources\vfs-mw') + '"'),
    ('data="' + (Join-Path $packageRoot 'lorkhan\files') + '"'),
    ('data="' + $aiData + '"')
)
foreach ($master in @('Morrowind', 'Tribunal', 'Bloodmoon')) {
    if (Test-Path -LiteralPath (Join-Path $GameData "$master.esm") -PathType Leaf) {
        $lines += "content=$master.esm"
        if (Test-Path -LiteralPath (Join-Path $GameData "$master.bsa") -PathType Leaf) { $lines += "fallback-archive=$master.bsa" }
    }
}
$lines += 'content=LORKHAN.omwscripts'
[IO.File]::WriteAllLines((Join-Path $ProfileRoot 'openmw.cfg'), $lines, [Text.UTF8Encoding]::new($false))
$launch = @'
$ErrorActionPreference = 'Stop'
$env:LORKHAN_CLIENT_CONFIG = Join-Path $PSScriptRoot 'lorkhan-client.conf'
$engine = '@ENGINE@'
$process = Start-Process -FilePath $engine -ArgumentList @('--replace', 'config', '--config', ('"' + $PSScriptRoot + '"')) -WorkingDirectory (Split-Path $engine -Parent) -Wait -PassThru
exit $process.ExitCode
'@
$launch = $launch.Replace('@ENGINE@', $engine.Replace("'", "''"))
[IO.File]::WriteAllText((Join-Path $ProfileRoot 'Launch-LORKHAN.ps1'), $launch, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $ProfileRoot 'Play-LORKHAN.cmd'), "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Launch-LORKHAN.ps1`"`r`nif errorlevel 1 pause`r`n", [Text.UTF8Encoding]::new($false))
Write-Output "Created isolated LORKHAN profile: $ProfileRoot"
Write-Output 'Start DwemerDistro, then use Play-LORKHAN.cmd in that profile. No game data was copied.'
