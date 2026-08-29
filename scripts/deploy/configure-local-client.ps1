[CmdletBinding()]
param(
    [string]$Distro = 'DwemerAI4Skyrim3',
    [string]$Output = (Join-Path $PSScriptRoot '..\..\.local\lorkhan-client.conf'),
    [string]$MediaCacheRoot = 'C:\Modlists\LORKHAN\Data\LORKHAN\cache',
    [ValidateRange(1024, 65535)]
    [int]$ProxyPort = 7514
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Pull the existing local-only server credential into a private client config without printing it.
$pairingKey = (& wsl -d $Distro -u root -- cat /etc/lorkhanserver/client-pairing-key 2>$null).Trim()
if ($LASTEXITCODE -ne 0 -or $pairingKey -notmatch '^[A-Za-z0-9_-]{43}$') {
    throw 'The deployed LORKHANserver pairing key is unavailable or malformed.'
}

$outputPath = [IO.Path]::GetFullPath($Output)
$cachePath = [IO.Path]::GetFullPath($MediaCacheRoot)
New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($outputPath)), $cachePath | Out-Null

# Preserve the local client identity across deploys so the server does not see every code update as
# a new installation, profile, and playthrough.
$existing = @{}
if (Test-Path -LiteralPath $outputPath -PathType Leaf) {
    foreach ($line in [IO.File]::ReadAllLines($outputPath)) {
        $separator = $line.IndexOf('=')
        if ($separator -gt 0) {
            $existing[$line.Substring(0, $separator)] = $line.Substring($separator + 1)
        }
    }
}

function Get-PreservedGuid {
    param([string]$Name)

    $value = $existing[$Name]
    $parsed = [guid]::Empty
    if ($value -and [guid]::TryParse($value, [ref]$parsed)) {
        return $parsed.ToString().ToLowerInvariant()
    }
    return [guid]::NewGuid().ToString().ToLowerInvariant()
}

$installationId = Get-PreservedGuid -Name 'installation_id'
$profileId = Get-PreservedGuid -Name 'profile_id'
$playthroughId = Get-PreservedGuid -Name 'playthrough_id'
$contentFingerprint = $existing['content_fingerprint']
if ($contentFingerprint -notmatch '^sha256:[0-9a-f]{64}$') {
    $contentFingerprint = 'sha256:0000000000000000000000000000000000000000000000000000000000000000'
}
$lines = @(
    "base_url=http://127.0.0.1:$ProxyPort/LORKHANserver/api/v1",
    "pairing_key=$pairingKey",
    "installation_id=$installationId",
    "profile_id=$profileId",
    "playthrough_id=$playthroughId",
    "content_fingerprint=$contentFingerprint",
    'platform=windows-x86_64',
    "media_cache_root=$cachePath",
    'media_vfs_prefix=LORKHAN/cache'
)
[IO.File]::WriteAllLines($outputPath, $lines, [Text.UTF8Encoding]::new($false))
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls.exe $outputPath /inheritance:r /grant:r "${identity}:(F)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Failed to restrict the LORKHAN client configuration ACL.' }
Write-Output "Configured private LORKHAN client file: $outputPath"
