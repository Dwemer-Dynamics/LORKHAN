[CmdletBinding()]
param(
    [string]$Distro = 'DwemerAI4Skyrim3',
    [ValidateRange(1024, 65535)][int]$Port = 8089
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Portproxy configuration is machine-wide, so fail before changing anything unless elevated.
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell window.'
}

$addressText = ((& wsl.exe -d $Distro -e hostname -I) -split '\s+')[0]
$address = $null
if (-not [Net.IPAddress]::TryParse($addressText, [ref]$address) -or
    $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
    throw 'Could not resolve the WSL IPv4 address.'
}

# Replace only ALMSIVI's exact loopback mapping; do not touch other portproxy entries.
& netsh.exe interface portproxy delete v4tov4 listenaddress=127.0.0.1 listenport=$Port 2>$null | Out-Null
& netsh.exe interface portproxy add v4tov4 listenaddress=127.0.0.1 listenport=$Port connectaddress=$addressText connectport=$Port | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Failed to configure the ALMSIVI WSL loopback proxy.' }

$health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/ALMSIVIserver/api/v1/health" -TimeoutSec 5
if ($health.schema -ne 'almsivi.health.v1') { throw 'ALMSIVIserver did not pass the Windows loopback health check.' }
Write-Output "ALMSIVIserver is available at http://127.0.0.1:$Port/ALMSIVIserver"
