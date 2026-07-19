$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
& python (Join-Path $Root 'scripts/audit/package_audit.py') --repository $Root @args
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
