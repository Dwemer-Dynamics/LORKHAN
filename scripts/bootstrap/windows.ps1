$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if (-not $env:LORKHAN_CACHE_DIR) { $env:LORKHAN_CACHE_DIR = Join-Path $Root '.cache/lorkhan' }
if (-not $env:LORKHAN_SOURCE_DIR) { $env:LORKHAN_SOURCE_DIR = Join-Path $Root '.work/openmw' }
if (-not $env:LORKHAN_RUN_MANIFEST) { $env:LORKHAN_RUN_MANIFEST = Join-Path $Root '.runs/bootstrap.json' }
$Python = if ($env:PYTHON) { $env:PYTHON } else { 'python' }
& $Python (Join-Path $Root 'scripts/bootstrap/bootstrap.py') bootstrap --cache-dir $env:LORKHAN_CACHE_DIR --source-dir $env:LORKHAN_SOURCE_DIR --manifest $env:LORKHAN_RUN_MANIFEST @args
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
