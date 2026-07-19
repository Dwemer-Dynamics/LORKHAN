$ErrorActionPreference = 'Stop'
if (-not $env:SOURCE_DATE_EPOCH) { throw 'SOURCE_DATE_EPOCH is required' }
$Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
& python (Join-Path $Root 'scripts/package/package.py') @args
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
