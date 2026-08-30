[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot,
    [string]$ProfileName = 'Compatibility',
    [switch]$Validate
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = [IO.Path]::GetFullPath($Root)
$profileRoot = Join-Path $Root "Profiles\$ProfileName"
$profilePath = Join-Path $profileRoot 'openmw.cfg'
$modsRoot = Join-Path $Root 'Mods'
$launcherPath = Join-Path $Root 'OpenMW\openmw-launcher.exe'
$clientConfigPath = Join-Path $Root 'Config\lorkhan-client.conf'
$contentExtensions = @('.esm', '.esp', '.omwgame', '.omwaddon', '.omwscripts')

function Unquote-OpenMwValue {
    param([Parameter(Mandatory)][string]$Value)
    $trimmed = $Value.Trim()
    if ($trimmed.Length -ge 2 -and $trimmed[0] -eq '"' -and $trimmed[$trimmed.Length - 1] -eq '"') {
        return $trimmed.Substring(1, $trimmed.Length - 2)
    }
    return $trimmed
}

function Read-ProfileState {
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        throw "OpenMW profile not found: $profilePath"
    }

    $lines = [IO.File]::ReadAllLines($profilePath)
    $dataPaths = [System.Collections.Generic.List[string]]::new()
    $content = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        if ($line -match '^\s*data\s*=\s*(.*)$') {
            $dataPaths.Add((Unquote-OpenMwValue $Matches[1]))
        } elseif ($line -match '^\s*content\s*=\s*(.*)$') {
            $content.Add((Unquote-OpenMwValue $Matches[1]))
        }
    }
    return [pscustomobject]@{ Lines = $lines; DataPaths = $dataPaths.ToArray(); Content = $content.ToArray() }
}

function Get-ModEntries {
    param([Parameter(Mandatory)]$State)

    $entries = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $State.DataPaths) {
        $fullPath = if ([IO.Path]::IsPathRooted($path)) { [IO.Path]::GetFullPath($path) } else { [IO.Path]::GetFullPath((Join-Path $profileRoot $path)) }
        if ($seen.Add($fullPath)) {
            $entries.Add([pscustomobject]@{
                Name = Split-Path $fullPath -Leaf
                Path = $fullPath
                Enabled = $true
                Exists = Test-Path -LiteralPath $fullPath -PathType Container
            })
        }
    }
    if (Test-Path -LiteralPath $modsRoot -PathType Container) {
        foreach ($directory in Get-ChildItem -LiteralPath $modsRoot -Directory | Sort-Object Name) {
            if ($seen.Add($directory.FullName)) {
                $entries.Add([pscustomobject]@{ Name = $directory.Name; Path = $directory.FullName; Enabled = $false; Exists = $true })
            }
        }
    }
    return $entries.ToArray()
}

function Get-AvailableContent {
    param([Parameter(Mandatory)][object[]]$ModEntries)

    $result = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($mod in $ModEntries) {
        if (-not $mod.Enabled -or -not $mod.Exists) { continue }
        foreach ($file in Get-ChildItem -LiteralPath $mod.Path -Recurse -File -ErrorAction SilentlyContinue) {
            if ($contentExtensions -notcontains $file.Extension.ToLowerInvariant()) { continue }
            $directoryPrefix = $mod.Path.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if (-not $file.FullName.StartsWith($directoryPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $relative = $file.FullName.Substring($directoryPrefix.Length).Replace('\', '/')
            if ($seen.Add($relative)) {
                $result.Add([pscustomobject]@{ Name = $relative; Mod = $mod.Name; Path = $file.FullName })
            }
        }
    }
    return $result.ToArray()
}

function Test-ProfileState {
    param([Parameter(Mandatory)]$State)

    $modEntries = @(Get-ModEntries $State)
    $available = @(Get-AvailableContent $modEntries)
    $availableNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $available) { [void]$availableNames.Add($entry.Name) }
    $missingData = @($modEntries | Where-Object { $_.Enabled -and -not $_.Exists } | ForEach-Object Path)
    $missingContent = @($State.Content | Where-Object { -not $availableNames.Contains($_) })
    return [pscustomobject]@{
        Profile = $profilePath
        EnabledDataDirectories = @($modEntries | Where-Object Enabled).Count
        EnabledContentFiles = @($State.Content).Count
        MissingDataDirectories = $missingData
        MissingContentFiles = $missingContent
        Valid = $missingData.Count -eq 0 -and $missingContent.Count -eq 0
    }
}

if ($Validate) {
    $validation = Test-ProfileState (Read-ProfileState)
    $validation | ConvertTo-Json -Depth 4
    if (-not $validation.Valid) { exit 1 }
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$state = Read-ProfileState
$modEntries = @(Get-ModEntries $state)
$enabledContent = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($name in $state.Content) { [void]$enabledContent.Add($name) }

$form = [Windows.Forms.Form]::new()
$form.Text = "LORKHAN OpenMW Profile Manager - $ProfileName"
$form.StartPosition = 'CenterScreen'
$form.Size = [Drawing.Size]::new(1040, 700)
$form.MinimumSize = [Drawing.Size]::new(880, 560)
$form.BackColor = [Drawing.Color]::FromArgb(31, 25, 20)
$form.ForeColor = [Drawing.Color]::FromArgb(236, 213, 173)
$form.Font = [Drawing.Font]::new('Segoe UI', 10)

$title = [Windows.Forms.Label]::new()
$title.Text = 'LORKHAN OpenMW Profile Manager'
$title.Font = [Drawing.Font]::new('Segoe UI Semibold', 18)
$title.ForeColor = [Drawing.Color]::FromArgb(244, 145, 54)
$title.SetBounds(18, 14, 700, 38)
$form.Controls.Add($title)

$help = [Windows.Forms.Label]::new()
$help.Text = 'Enable and order isolated mod folders, then enable and order their OpenMW content files. Save creates a profile backup.'
$help.SetBounds(20, 54, 980, 28)
$form.Controls.Add($help)

$modsLabel = [Windows.Forms.Label]::new()
$modsLabel.Text = 'MOD DATA DIRECTORIES (lowest priority first; later entries win)'
$modsLabel.SetBounds(20, 88, 480, 24)
$form.Controls.Add($modsLabel)

$contentLabel = [Windows.Forms.Label]::new()
$contentLabel.Text = 'CONTENT FILES (load order)'
$contentLabel.SetBounds(520, 88, 480, 24)
$form.Controls.Add($contentLabel)

$modsList = [Windows.Forms.ListView]::new()
$modsList.View = 'Details'
$modsList.CheckBoxes = $true
$modsList.FullRowSelect = $true
$modsList.HideSelection = $false
$modsList.MultiSelect = $false
$modsList.BackColor = [Drawing.Color]::FromArgb(43, 35, 28)
$modsList.ForeColor = $form.ForeColor
$modsList.SetBounds(20, 116, 470, 420)
[void]$modsList.Columns.Add('Mod', 190)
[void]$modsList.Columns.Add('Folder', 250)
$form.Controls.Add($modsList)

$contentList = [Windows.Forms.ListView]::new()
$contentList.View = 'Details'
$contentList.CheckBoxes = $true
$contentList.FullRowSelect = $true
$contentList.HideSelection = $false
$contentList.MultiSelect = $false
$contentList.BackColor = [Drawing.Color]::FromArgb(43, 35, 28)
$contentList.ForeColor = $form.ForeColor
$contentList.SetBounds(520, 116, 480, 420)
[void]$contentList.Columns.Add('Content', 280)
[void]$contentList.Columns.Add('Mod', 160)
$form.Controls.Add($contentList)

$status = [Windows.Forms.Label]::new()
$status.AutoEllipsis = $true
$status.SetBounds(20, 616, 650, 28)
$form.Controls.Add($status)

function Sync-ModEntriesFromList {
    $script:modEntries = @($modsList.Items | ForEach-Object {
        $entry = $_.Tag
        $entry.Enabled = $_.Checked
        $entry
    })
}

function Refresh-ContentList {
    Sync-ModEntriesFromList
    foreach ($item in $contentList.Items) {
        if ($item.Checked) { [void]$enabledContent.Add([string]$item.Tag.Name) }
        else { [void]$enabledContent.Remove([string]$item.Tag.Name) }
    }
    $existingOrder = @($contentList.Items | ForEach-Object { [string]$_.Tag.Name })
    $available = @(Get-AvailableContent $modEntries)
    $byName = @{}
    foreach ($entry in $available) { $byName[$entry.Name.ToLowerInvariant()] = $entry }
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($name in @($state.Content) + $existingOrder) {
        $key = $name.ToLowerInvariant()
        if ($byName.ContainsKey($key)) { $ordered.Add($byName[$key]); $byName.Remove($key) }
    }
    foreach ($entry in $available) {
        $key = $entry.Name.ToLowerInvariant()
        if ($byName.ContainsKey($key)) { $ordered.Add($entry); $byName.Remove($key) }
    }
    $contentList.BeginUpdate()
    $contentList.Items.Clear()
    foreach ($entry in $ordered) {
        $item = [Windows.Forms.ListViewItem]::new($entry.Name)
        [void]$item.SubItems.Add($entry.Mod)
        $item.Tag = $entry
        $item.Checked = $enabledContent.Contains($entry.Name)
        [void]$contentList.Items.Add($item)
    }
    $contentList.EndUpdate()
}

function Refresh-ModList {
    $modsList.BeginUpdate()
    $modsList.Items.Clear()
    foreach ($entry in $modEntries) {
        $item = [Windows.Forms.ListViewItem]::new($entry.Name)
        [void]$item.SubItems.Add($entry.Path)
        $item.Tag = $entry
        $item.Checked = $entry.Enabled
        if (-not $entry.Exists) { $item.ForeColor = [Drawing.Color]::Tomato }
        [void]$modsList.Items.Add($item)
    }
    $modsList.EndUpdate()
}

function Rescan-Mods {
    Sync-ModEntriesFromList
    $scanned = @(Get-ModEntries $state)
    $scannedByPath = @{}
    foreach ($entry in $scanned) { $scannedByPath[$entry.Path.ToLowerInvariant()] = $entry }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $refreshed = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in $modEntries) {
        $key = $entry.Path.ToLowerInvariant()
        if (-not $scannedByPath.ContainsKey($key) -or -not $seen.Add($entry.Path)) { continue }
        $scannedByPath[$key].Enabled = $entry.Enabled
        $refreshed.Add($scannedByPath[$key])
    }
    foreach ($entry in $scanned) {
        if ($seen.Add($entry.Path)) { $refreshed.Add($entry) }
    }

    $script:modEntries = $refreshed.ToArray()
    Refresh-ModList
    Refresh-ContentList
    $status.Text = "Refreshed Mods folder: $($modEntries.Count) data directories found."
}

# Report duplicate relative paths in enabled data folders; the last provider is OpenMW's winner.
function Show-ModConflicts {
    Sync-ModEntriesFromList
    $providers = @{}
    $displayPaths = @{}
    foreach ($mod in $modEntries | Where-Object { $_.Enabled -and $_.Exists }) {
        $prefix = $mod.Path.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        foreach ($file in Get-ChildItem -LiteralPath $mod.Path -Recurse -File -ErrorAction SilentlyContinue) {
            if (-not $file.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $relative = $file.FullName.Substring($prefix.Length).Replace('\', '/')
            $key = $relative.ToLowerInvariant()
            if (-not $providers.ContainsKey($key)) {
                $providers[$key] = [System.Collections.Generic.List[string]]::new()
                $displayPaths[$key] = $relative
            }
            $providers[$key].Add([string]$mod.Name)
        }
    }
    $conflicts = @($providers.Keys | Where-Object { $providers[$_].Count -gt 1 } | Sort-Object)
    if ($conflicts.Count -eq 0) {
        [Windows.Forms.MessageBox]::Show('No overlapping files were found in the enabled mod folders.', 'LORKHAN mod conflicts') | Out-Null
        return
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("$($conflicts.Count) overlapping file paths found. Later enabled folders win.")
    $lines.Add('')
    foreach ($key in $conflicts | Select-Object -First 500) {
        $sources = @($providers[$key])
        $lines.Add($displayPaths[$key])
        $lines.Add('  ' + ($sources -join ' -> ') + "  [winner: $($sources[-1])]")
        $lines.Add('')
    }
    if ($conflicts.Count -gt 500) { $lines.Add('Only the first 500 conflicts are shown.') }

    $dialog = [Windows.Forms.Form]::new()
    $dialog.Text = 'LORKHAN OpenMW File Conflicts'
    $dialog.StartPosition = 'CenterParent'
    $dialog.Size = [Drawing.Size]::new(900, 650)
    $dialog.BackColor = $form.BackColor
    $dialog.ForeColor = $form.ForeColor
    $output = [Windows.Forms.TextBox]::new()
    $output.Multiline = $true
    $output.ReadOnly = $true
    $output.ScrollBars = 'Both'
    $output.WordWrap = $false
    $output.Dock = 'Fill'
    $output.BackColor = [Drawing.Color]::FromArgb(43, 35, 28)
    $output.ForeColor = $form.ForeColor
    $output.Font = [Drawing.Font]::new('Consolas', 10)
    $output.Text = $lines -join [Environment]::NewLine
    $dialog.Controls.Add($output)
    [void]$dialog.ShowDialog($form)
}

function Move-SelectedItem {
    param([Parameter(Mandatory)][Windows.Forms.ListView]$List, [Parameter(Mandatory)][int]$Direction)
    if ($List.SelectedIndices.Count -ne 1) { return }
    $from = $List.SelectedIndices[0]
    $to = $from + $Direction
    if ($to -lt 0 -or $to -ge $List.Items.Count) { return }
    $item = $List.Items[$from]
    $List.Items.RemoveAt($from)
    $List.Items.Insert($to, $item)
    $item.Selected = $true
    $item.Focused = $true
    $item.EnsureVisible()
}

function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width, [scriptblock]$Click)
    $button = [Windows.Forms.Button]::new()
    $button.Text = $Text
    $button.SetBounds($X, $Y, $Width, 34)
    $button.BackColor = [Drawing.Color]::FromArgb(75, 52, 32)
    $button.ForeColor = $form.ForeColor
    $button.FlatStyle = 'Flat'
    $button.Add_Click($Click)
    $form.Controls.Add($button)
}

function Start-LorkhanServices {
    if (-not (Test-Path -LiteralPath $clientConfigPath -PathType Leaf)) {
        throw "The private LORKHAN client configuration is missing: $clientConfigPath"
    }
    & wsl.exe -d DwemerAI4Skyrim3 -u root -- bash -lc 'service postgresql start >/dev/null; service apache2 start >/dev/null; service lorkhanserver-worker start >/dev/null'
    if ($LASTEXITCODE -ne 0) { throw 'The LORKHAN WSL services could not be started.' }
$healthUri = 'http://127.0.0.1:7514/' + 'LORKHANserver/api/v1/health'
    $health = Invoke-RestMethod -Uri $healthUri -TimeoutSec 5
    if ($health.schema -ne 'lorkhan.health.v1') { throw 'LORKHANserver returned an unexpected health response.' }
    $env:LORKHAN_CLIENT_CONFIG = $clientConfigPath
}

Refresh-ModList
Refresh-ContentList
$modsList.Add_ItemChecked({ $form.BeginInvoke([Action]{ Refresh-ContentList }) | Out-Null })

New-Button 'Move mod up' 20 548 100 { Move-SelectedItem $modsList -1; Sync-ModEntriesFromList }
New-Button 'Move mod down' 128 548 110 { Move-SelectedItem $modsList 1; Sync-ModEntriesFromList }
New-Button 'Refresh mods' 246 548 110 { Rescan-Mods }
New-Button 'Open Mods folder' 364 548 126 { Start-Process explorer.exe -ArgumentList $modsRoot }
New-Button 'Move content up' 520 548 130 { Move-SelectedItem $contentList -1 }
New-Button 'Move content down' 658 548 140 { Move-SelectedItem $contentList 1 }
New-Button 'Open OpenMW Launcher' 806 548 194 {
    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) { [Windows.Forms.MessageBox]::Show("Launcher not found: $launcherPath", 'LORKHAN') | Out-Null; return }
    try {
        Start-LorkhanServices
        Start-Process -FilePath $launcherPath -ArgumentList @('--config', $profileRoot) -WorkingDirectory (Split-Path $launcherPath -Parent)
    } catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'LORKHAN launcher') | Out-Null
    }
}
New-Button 'Show file conflicts' 684 604 154 { Show-ModConflicts }
New-Button 'Save profile' 846 604 154 {
    Sync-ModEntriesFromList
    $selectedContent = @($contentList.Items | Where-Object Checked | ForEach-Object { [string]$_.Tag.Name })
    $missingData = @($modEntries | Where-Object { $_.Enabled -and -not $_.Exists })
    if ($missingData.Count -gt 0) {
        [Windows.Forms.MessageBox]::Show(('Cannot save because these directories are missing:' + [Environment]::NewLine + ($missingData.Path -join [Environment]::NewLine)), 'LORKHAN profile validation') | Out-Null
        return
    }
    $preserved = @($state.Lines | Where-Object { $_ -notmatch '^\s*(data|content)\s*=' })
    $output = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $preserved) { $output.Add($line) }
    foreach ($entry in $modEntries | Where-Object Enabled) { $output.Add('data="' + $entry.Path + '"') }
    foreach ($name in $selectedContent) { $output.Add('content=' + $name) }
    $backup = $profilePath + '.' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.backup'
    Copy-Item -LiteralPath $profilePath -Destination $backup
    [IO.File]::WriteAllLines($profilePath, $output, [Text.UTF8Encoding]::new($false))
    $script:state = Read-ProfileState
    $status.Text = "Saved $ProfileName profile. Backup: $(Split-Path $backup -Leaf)"
}

$initialValidation = Test-ProfileState $state
if ($initialValidation.Valid) {
    $status.Text = "Profile valid: $($initialValidation.EnabledDataDirectories) data folders, $($initialValidation.EnabledContentFiles) content files."
} else {
    $status.Text = "Profile needs attention: $($initialValidation.MissingDataDirectories.Count) missing folders, $($initialValidation.MissingContentFiles.Count) missing content files."
    $status.ForeColor = [Drawing.Color]::Tomato
}

[void]$form.ShowDialog()
