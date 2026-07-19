$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if (-not $env:ALMSIVI_CACHE_DIR) { $env:ALMSIVI_CACHE_DIR = Join-Path $Root '.cache/almsivi' }
if (-not $env:ALMSIVI_SOURCE_DIR) { $env:ALMSIVI_SOURCE_DIR = Join-Path $Root '.work/openmw' }
if (-not $env:ALMSIVI_RUN_MANIFEST) { $env:ALMSIVI_RUN_MANIFEST = Join-Path $Root '.runs/bootstrap.json' }
$Python = if ($env:PYTHON) { $env:PYTHON } else { 'python' }
& $Python (Join-Path $Root 'scripts/bootstrap/bootstrap.py') bootstrap --cache-dir $env:ALMSIVI_CACHE_DIR --source-dir $env:ALMSIVI_SOURCE_DIR --manifest $env:ALMSIVI_RUN_MANIFEST @args
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
