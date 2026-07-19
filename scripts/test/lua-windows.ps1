[CmdletBinding()]
param(
  [string]$TestRoot = $env:ALMSIVI_LUA_TEST_ROOT,
  [switch]$Required
)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if (-not $TestRoot) { $TestRoot = Join-Path $Root 'tests/lua' }
if (-not $Required -and $env:ALMSIVI_REQUIRE_LUA_TESTS -eq '1') { $Required = $true }
$Lua = if ($env:LUA) { Get-Command $env:LUA -ErrorAction SilentlyContinue } else { Get-Command lua54,lua -ErrorAction SilentlyContinue | Select-Object -First 1 }
if (-not (Test-Path -LiteralPath $TestRoot -PathType Container)) {
  if ($Required) { throw "required Lua test root missing: $TestRoot" }
  Write-Host 'skip: Lua test root not present; no Lua proof claimed'; exit 0
}
if (-not $Lua) {
  if ($Required) { throw 'Lua interpreter required but unavailable' }
  Write-Host 'skip: Lua interpreter unavailable; no Lua proof claimed'; exit 0
}
$Tests = @(Get-ChildItem -LiteralPath $TestRoot -Recurse -File -Filter '*_test.lua' | Sort-Object FullName)
if ($Tests.Count -eq 0) {
  if ($Required) { throw 'required Lua tests not found' }
  Write-Host 'skip: no *_test.lua files discovered; no Lua proof claimed'; exit 0
}
foreach ($Test in $Tests) { & $Lua.Source $Test.FullName; if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE } }
