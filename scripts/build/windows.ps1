[CmdletBinding()]
param(
  [ValidateSet('control','patched')][string]$State = $env:ALMSIVI_PATCH_STATE,
  [string]$Source = $env:ALMSIVI_SOURCE_DIR,
  [string]$Build = $env:ALMSIVI_BUILD_DIR,
  [string]$Install = $env:ALMSIVI_INSTALL_DIR,
  [string]$Output = $env:ALMSIVI_OUTPUT_DIR,
  [ValidateSet('Debug','RelWithDebInfo','Release')][string]$Config = $(if ($env:ALMSIVI_BUILD_CONFIG) { $env:ALMSIVI_BUILD_CONFIG } else { 'RelWithDebInfo' }),
  [ValidateSet('msvc','clang')][string]$Compiler = $(if ($env:ALMSIVI_COMPILER) { $env:ALMSIVI_COMPILER } else { 'msvc' }),
  [string]$Target = $env:ALMSIVI_BUILD_TARGET,
  [string]$TestTarget = $env:ALMSIVI_REQUIRED_TEST_TARGET,
  [string]$ExpectedPin = $(if ($env:ALMSIVI_EXPECTED_PIN) { $env:ALMSIVI_EXPECTED_PIN } else { 'f4bec41444214a7903bebd178389ca22ca13f646' }),
  [long]$Epoch = $(if ($env:SOURCE_DATE_EPOCH) { [long]$env:SOURCE_DATE_EPOCH } else { 1784442566 }),
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$CMakeArgument
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
foreach ($item in @{'State'=$State;'Source'=$Source;'Build'=$Build;'Install'=$Install;'Output'=$Output}.GetEnumerator()) {
  if ([string]::IsNullOrWhiteSpace($item.Value)) { throw "$($item.Key) is required" }
}
foreach ($tool in @('git','cmake')) { if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "required tool missing: $tool" } }
$Source = (Resolve-Path -LiteralPath $Source).Path
if (-not (Test-Path -LiteralPath (Join-Path $Source '.git'))) { throw "source is not a git work tree: $Source" }
$head = (& git -C $Source rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head -ne $ExpectedPin) { throw "expected pin $ExpectedPin, found $head" }
$status = (& git -C $Source status --porcelain=v1 --untracked-files=all) -join "`n"
if ($State -eq 'control' -and $status) { throw "control source is not pristine:`n$status" }
if ($State -eq 'patched' -and -not $status) { throw 'patched state declared but source has no changes' }
$Build = [IO.Path]::GetFullPath($Build); $Install = [IO.Path]::GetFullPath($Install); $Output = [IO.Path]::GetFullPath($Output)
foreach ($path in @($Build,$Install,$Output)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
if ($Build.StartsWith($Source + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $Install.StartsWith($Source + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'build and install roots must be outside source root' }
$env:SOURCE_DATE_EPOCH = "$Epoch"; $env:TZ = 'UTC'; $env:LANG = 'C'; $env:LC_ALL = 'C'
$generatorArgs = @('-G','Visual Studio 17 2022','-A','x64')
$mapFlags = "/Brepro /pathmap:$Source=C:\src\almsivi /pathmap:$Build=C:\src\almsivi-build"
if ($Compiler -eq 'clang') { $generatorArgs += @('-T','ClangCL'); $mapFlags = "-Xclang -ffile-prefix-map=$Source=C:/src/almsivi -Xclang -fdebug-prefix-map=$Source=C:/src/almsivi /Brepro" }
$manifest = Join-Path $Output "build-$State-$Compiler-$Config.txt"
@("state=$State","config=$Config","compiler=$Compiler","source=$Source","build=$Build","install=$Install","pin=$ExpectedPin","epoch=$Epoch",'status_begin',$status,'status_end',(& cmake --version | Select-Object -First 1)) | Set-Content -Encoding utf8 $manifest
$log = Join-Path $Output "build-$State-$Compiler-$Config.log"
$productArgs = if ($State -eq 'patched') { @("-DALMSIVI_SOURCE_ROOT=$RepoRoot") } else { @() }
$configure = @('-S',$Source,'-B',$Build) + $generatorArgs + @("-DCMAKE_INSTALL_PREFIX=$Install","-DCMAKE_C_FLAGS=$mapFlags","-DCMAKE_CXX_FLAGS=$mapFlags") + $productArgs + $CMakeArgument
& cmake @configure 2>&1 | Tee-Object -FilePath $log
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$buildArgs = @('--build',$Build,'--config',$Config); if ($Target) { $buildArgs += @('--target',$Target) }
& cmake @buildArgs 2>&1 | Tee-Object -FilePath $log -Append
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($TestTarget) {
  $targets = (& cmake --build $Build --config $Config --target help 2>&1) -join "`n"
  $targets | Set-Content -Encoding utf8 (Join-Path $Output 'targets.txt')
  if (-not $targets.Contains($TestTarget)) { throw "declared required target missing: $TestTarget" }
  & cmake --build $Build --config $Config --target $TestTarget 2>&1 | Tee-Object -FilePath $log -Append
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} elseif (Get-Command ctest -ErrorAction SilentlyContinue) {
  $listing = (& ctest --test-dir $Build -C $Config -N 2>&1) -join "`n"
  if ($listing -match 'Total Tests:\s+([1-9][0-9]*)') {
    & ctest --test-dir $Build -C $Config --output-on-failure 2>&1 | Tee-Object -FilePath $log -Append
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  } else { 'note: no CTest tests discovered; no test proof claimed' | Tee-Object -FilePath $log -Append }
}
& cmake --install $Build --config $Config 2>&1 | Tee-Object -FilePath $log -Append
exit $LASTEXITCODE
