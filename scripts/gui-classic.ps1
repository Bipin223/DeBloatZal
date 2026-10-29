#Requires -Version 5.1
<#
.SYNOPSIS
    Legacy DeBloatZal GUI front-end (WinForms, no extra installs).

.DESCRIPTION
    Lists packages from the selected profile, shows what each one is, and lets
    you tick what to remove. Same engine as debloat.ps1: adb + pm, user 0 only,
    with a package snapshot and an undo log for every run.

.EXAMPLE
    .\scripts\gui.ps1
    .\scripts\gui.ps1 -Demo          # try the UI without a phone
    .\scripts\gui.ps1 -Serial abc123
#>
[CmdletBinding()]
param(
    [string]$Serial,
    [string]$Profile,
    [ValidateSet('installed', 'removed', 'all')][string]$State = 'installed',
    [switch]$Demo,
    [string]$Capture
)

$ErrorActionPreference = 'Stop'
if (-not ('DpiAwareness' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DpiAwareness {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
'@
}
[void][DpiAwareness]::SetProcessDPIAware()
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

. (Join-Path $PSScriptRoot 'common.ps1')

$script:RootDir  = Split-Path -Parent $PSScriptRoot
$script:InfoFile = Join-Path $script:RootDir 'data\package-info.json'
$script:DemoMode = [bool]$Demo
$script:CapturePath = $Capture
$script:Connected = $false
$script:Busy = $false
$script:Device = $null
$script:DeviceInfo = $null
$script:States = @{}
$script:Extras = @()
$script:Sections = $null
$script:ProfileFile = $null
$script:ProfileName = ''
$script:Model = New-Object 'System.Collections.Generic.List[object]'
$script:ModelByPackage = @{}
$script:LastChangeLog = $null
$script:TierFilter = 'all'
$script:SearchText = ''
$script:StateFilter = $State
$script:ProfileAutoMatched = $true

# ---------------------------------------------------------------- theme
$script:ColBg      = [Drawing.Color]::FromArgb(24, 24, 28)
$script:ColPanel   = [Drawing.Color]::FromArgb(31, 31, 37)
$script:ColPanel2  = [Drawing.Color]::FromArgb(40, 40, 48)
$script:ColLine    = [Drawing.Color]::FromArgb(58, 58, 70)
$script:ColText    = [Drawing.Color]::FromArgb(232, 232, 236)
$script:ColMuted   = [Drawing.Color]::FromArgb(148, 148, 160)
$script:ColAccent  = [Drawing.Color]::FromArgb(59, 130, 246)
$script:ColGreen   = [Drawing.Color]::FromArgb(34, 197, 94)
$script:ColAmber   = [Drawing.Color]::FromArgb(245, 158, 11)
$script:ColRed     = [Drawing.Color]::FromArgb(239, 68, 68)

$script:FontMain  = New-Object Drawing.Font('Segoe UI', 9)
$script:FontSmall = New-Object Drawing.Font('Segoe UI', 8)
$script:FontTitle = New-Object Drawing.Font('Segoe UI Semibold', 14)

# ---------------------------------------------------------------- package metadata
$script:PackageInfo = @{}
if (Test-Path -LiteralPath $script:InfoFile) {
    try {
        $json = Get-Content -LiteralPath $script:InfoFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $json.PSObject.Properties) {
            if ($p.Name -eq '_readme') { continue }
            $script:PackageInfo[$p.Name] = @{
                Name = [string]$p.Value.name
                Desc = [string]$p.Value.desc
                Risk = [string]$p.Value.risk
            }
        }
    }
    catch {
        Write-Host ("Warning: could not read package-info.json: " + $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Get-FriendlyName {
    param([string]$Package)
    $leaf = ($Package -split '\.')[-1]
    $leaf = $leaf -creplace '([a-z0-9])([A-Z])', '$1 $2'
    $leaf = $leaf -replace '_', ' '
    if ($leaf.Length -le 3) { return $leaf.ToUpperInvariant() }
    return $leaf.Substring(0, 1).ToUpperInvariant() + $leaf.Substring(1)
}

function Get-PackageMeta {
    param([string]$Package)
    if ($script:PackageInfo.ContainsKey($Package)) { return $script:PackageInfo[$Package] }
    return @{
        Name = Get-FriendlyName $Package
        Desc = 'Not in the curated list. Research this package before removing it.'
        Risk = 'unknown'
    }
}

function Get-TierLabel {
    param([string]$Tier)
    switch ($Tier) {
        'core'      { return 'Core' }
        'optional'  { return 'Optional' }
        'protect'   { return 'Protected' }
        default     { return 'Other' }
    }
}

function Get-StateLabel {
    param([string]$State)
    switch ($State) {
        'enabled'      { return 'installed' }
        'disabled'     { return 'disabled' }
        'uninstalled'  { return 'removed' }
        'not installed'{ return 'not on phone' }
        default        { return $State }
    }
}

# ---------------------------------------------------------------- form + widgets
$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'DeBloatZal'
$script:Form.Size = New-Object Drawing.Size(1180, 760)
$script:Form.MinimumSize = New-Object Drawing.Size(980, 620)
$script:Form.StartPosition = 'CenterScreen'
$script:Form.BackColor = $script:ColBg
$script:Form.ForeColor = $script:ColText
$script:Form.Font = $script:FontMain
$script:Form.AutoScaleMode = 'Dpi'

function New-FlatButton {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [switch]$Accent, [switch]$Small)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object Drawing.Point($X, $Y)
    $b.Size = New-Object Drawing.Size($W, $H)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = $script:ColLine
    if ($Accent) {
        $b.BackColor = $script:ColAccent
        $b.ForeColor = [Drawing.Color]::White
        $b.FlatAppearance.BorderColor = $script:ColAccent
    }
    else {
        $b.BackColor = $script:ColPanel2
        $b.ForeColor = $script:ColText
    }
    $b.Font = $script:FontMain
    if ($Small) { $b.Font = $script:FontSmall }
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.UseVisualStyleBackColor = $false
    return $b
}

$script:TopPanel = New-Object System.Windows.Forms.Panel
$script:TopPanel.Dock = 'Top'
$script:TopPanel.Height = 134
$script:TopPanel.BackColor = $script:ColPanel

$script:TitleLabel = New-Object System.Windows.Forms.Label
$script:TitleLabel.Text = 'DeBloatZal'
$script:TitleLabel.Font = $script:FontTitle
$script:TitleLabel.ForeColor = $script:ColText
$script:TitleLabel.Location = New-Object Drawing.Point(18, 12)
$script:TitleLabel.AutoSize = $true
$script:TopPanel.Controls.Add($script:TitleLabel)

$script:DeviceLabel = New-Object System.Windows.Forms.Label
$script:DeviceLabel.Text = 'No phone connected'
$script:DeviceLabel.Font = New-Object Drawing.Font('Segoe UI Semibold', 10)
$script:DeviceLabel.ForeColor = $script:ColText
$script:DeviceLabel.Location = New-Object Drawing.Point(18, 44)
$script:DeviceLabel.Size = New-Object Drawing.Size(570, 22)
$script:TopPanel.Controls.Add($script:DeviceLabel)

$script:ProfileLabel = New-Object System.Windows.Forms.Label
$script:ProfileLabel.Text = 'Plug in a phone, enable USB debugging and press Refresh.'
$script:ProfileLabel.Font = $script:FontSmall
$script:ProfileLabel.ForeColor = $script:ColMuted
$script:ProfileLabel.Location = New-Object Drawing.Point(18, 70)
$script:ProfileLabel.Size = New-Object Drawing.Size(760, 18)
$script:TopPanel.Controls.Add($script:ProfileLabel)

$script:ProfileCombo = New-Object System.Windows.Forms.ComboBox
$script:ProfileCombo.Location = New-Object Drawing.Point(600, 42)
$script:ProfileCombo.Size = New-Object Drawing.Size(190, 24)
$script:ProfileCombo.DropDownStyle = 'DropDownList'
$script:ProfileCombo.FlatStyle = 'Flat'
$script:ProfileCombo.BackColor = $script:ColPanel2
$script:ProfileCombo.ForeColor = $script:ColText
$script:ProfileCombo.Enabled = $false
$script:TopPanel.Controls.Add($script:ProfileCombo)
Get-ChildItem -LiteralPath $script:ProfileDir -Filter '*.profile' -ErrorAction SilentlyContinue |
    Sort-Object Name | ForEach-Object { [void]$script:ProfileCombo.Items.Add($_.BaseName) }

$script:RefreshButton = New-FlatButton -Text 'Refresh' -X 1040 -Y 12 -W 104 -H 30 -Accent
$script:TopPanel.Controls.Add($script:RefreshButton)

$script:RebootButton = New-FlatButton -Text 'Reboot' -X 1040 -Y 50 -W 104 -H 28
$script:RebootButton.Enabled = $false
$script:TopPanel.Controls.Add($script:RebootButton)

$script:LogsButton = New-FlatButton -Text 'Open logs' -X 894 -Y 50 -W 136 -H 28
$script:TopPanel.Controls.Add($script:LogsButton)

# ---------------------------------------------------------------- filter bar (inside the top panel)
$script:FilterPanel = $script:TopPanel

$script:SearchLabel = New-Object System.Windows.Forms.Label
$script:SearchLabel.Text = 'Search'
$script:SearchLabel.ForeColor = $script:ColMuted
$script:SearchLabel.Location = New-Object Drawing.Point(18, 100)
$script:SearchLabel.AutoSize = $true
$script:FilterPanel.Controls.Add($script:SearchLabel)

$script:SearchBox = New-Object System.Windows.Forms.TextBox
$script:SearchBox.Location = New-Object Drawing.Point(74, 97)
$script:SearchBox.Size = New-Object Drawing.Size(300, 24)
$script:SearchBox.BackColor = $script:ColPanel2
$script:SearchBox.ForeColor = $script:ColText
$script:SearchBox.BorderStyle = 'FixedSingle'
$script:FilterPanel.Controls.Add($script:SearchBox)

$script:TierLabel = New-Object System.Windows.Forms.Label
$script:TierLabel.Text = 'Show'
$script:TierLabel.ForeColor = $script:ColMuted
$script:TierLabel.Location = New-Object Drawing.Point(398, 100)
$script:TierLabel.AutoSize = $true
$script:FilterPanel.Controls.Add($script:TierLabel)

$script:TierCombo = New-Object System.Windows.Forms.ComboBox
$script:TierCombo.Location = New-Object Drawing.Point(440, 97)
$script:TierCombo.Size = New-Object Drawing.Size(150, 24)
$script:TierCombo.DropDownStyle = 'DropDownList'
$script:TierCombo.FlatStyle = 'Flat'
$script:TierCombo.BackColor = $script:ColPanel2
$script:TierCombo.ForeColor = $script:ColText
@('All packages', 'Core only', 'Optional only', 'Protected only', 'Other only') | ForEach-Object { [void]$script:TierCombo.Items.Add($_) }
$script:TierCombo.SelectedIndex = 0
$script:FilterPanel.Controls.Add($script:TierCombo)

$script:StateCombo = New-Object System.Windows.Forms.ComboBox
$script:StateCombo.Location = New-Object Drawing.Point(612, 97)
$script:StateCombo.Size = New-Object Drawing.Size(150, 24)
$script:StateCombo.DropDownStyle = 'DropDownList'
$script:StateCombo.FlatStyle = 'Flat'
$script:StateCombo.BackColor = $script:ColPanel2
$script:StateCombo.ForeColor = $script:ColText
@('Installed', 'Removed', 'All') | ForEach-Object { [void]$script:StateCombo.Items.Add($_) }
switch ($State) {
    'removed' { $script:StateCombo.SelectedIndex = 1 }
    'all'     { $script:StateCombo.SelectedIndex = 2 }
    default   { $script:StateCombo.SelectedIndex = 0 }
}
$script:FilterPanel.Controls.Add($script:StateCombo)

$script:CountLabel = New-Object System.Windows.Forms.Label
$script:CountLabel.Text = ''
$script:CountLabel.ForeColor = $script:ColMuted
$script:CountLabel.Location = New-Object Drawing.Point(790, 100)
$script:CountLabel.AutoSize = $true
$script:FilterPanel.Controls.Add($script:CountLabel)

$script:Form.Controls.Add($script:TopPanel)

# ---------------------------------------------------------------- grid
$script:Grid = New-Object System.Windows.Forms.DataGridView
$script:Grid.Dock = 'Fill'
$script:Grid.BackgroundColor = $script:ColBg
$script:Grid.BorderStyle = 'None'
$script:Grid.GridColor = [Drawing.Color]::FromArgb(44, 44, 54)
$script:Grid.RowHeadersVisible = $false
$script:Grid.AllowUserToAddRows = $false
$script:Grid.AllowUserToDeleteRows = $false
$script:Grid.AllowUserToResizeRows = $false
$script:Grid.AllowUserToOrderColumns = $false
$script:Grid.SelectionMode = 'FullRowSelect'
$script:Grid.MultiSelect = $false
$script:Grid.EnableHeadersVisualStyles = $false
$script:Grid.ColumnHeadersHeight = 34
$script:Grid.ColumnHeadersVisible = $true
$script:Grid.ColumnHeadersBorderStyle = 'Single'
$script:Grid.RowTemplate.Height = 26
$script:Grid.AutoSizeRowsMode = 'None'
$script:Grid.DefaultCellStyle.BackColor = $script:ColBg
$script:Grid.DefaultCellStyle.ForeColor = $script:ColText
$script:Grid.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(38, 56, 84)
$script:Grid.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::White
$script:Grid.DefaultCellStyle.Font = $script:FontMain
$script:Grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(2, 0, 2, 0)
$script:Grid.ColumnHeadersDefaultCellStyle.BackColor = $script:ColPanel2
$script:Grid.ColumnHeadersDefaultCellStyle.ForeColor = $script:ColMuted
$script:Grid.ColumnHeadersDefaultCellStyle.Font = $script:FontSmall
$script:Grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $script:ColPanel2
$script:Grid.ColumnHeadersDefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(2, 0, 2, 0)
$script:Grid.AlternatingRowsDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(28, 28, 33)
$script:Grid.StandardTab = $true
$script:Form.Controls.Add($script:Grid)

$colSel = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colSel.HeaderText = ''
$colSel.Name = 'sel'
$colSel.Width = 38
$colSel.SortMode = 'NotSortable'
$colSel.Resizable = 'False'
[void]$script:Grid.Columns.Add($colSel)

$colPkg = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colPkg.HeaderText = 'Package'
$colPkg.Name = 'pkg'
$colPkg.Width = 360
$colPkg.ReadOnly = $true
$colPkg.SortMode = 'NotSortable'
[void]$script:Grid.Columns.Add($colPkg)

$colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colName.HeaderText = 'App / service'
$colName.Name = 'name'
$colName.AutoSizeMode = 'Fill'
$colName.ReadOnly = $true
$colName.SortMode = 'NotSortable'
[void]$script:Grid.Columns.Add($colName)

$colTier = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colTier.HeaderText = 'Tier'
$colTier.Name = 'tier'
$colTier.Width = 80
$colTier.ReadOnly = $true
$colTier.SortMode = 'NotSortable'
[void]$script:Grid.Columns.Add($colTier)

$colState = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colState.HeaderText = 'State'
$colState.Name = 'state'
$colState.Width = 95
$colState.ReadOnly = $true
$colState.SortMode = 'NotSortable'
[void]$script:Grid.Columns.Add($colState)

$colRisk = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colRisk.HeaderText = 'Risk'
$colRisk.Name = 'risk'
$colRisk.Width = 76
$colRisk.ReadOnly = $true
$colRisk.SortMode = 'NotSortable'
[void]$script:Grid.Columns.Add($colRisk)

$script:Grid.ColumnHeadersVisible = $true
$script:Grid.ColumnHeadersHeightSizeMode = 'DisableResizing'
$script:Grid.ColumnHeadersHeight = 32

# ---------------------------------------------------------------- bottom bar
$script:BottomPanel = New-Object System.Windows.Forms.Panel
$script:BottomPanel.Dock = 'Bottom'
$script:BottomPanel.Height = 88
$script:BottomPanel.BackColor = $script:ColPanel
$script:Form.Controls.Add($script:BottomPanel)

$script:ModeLabel = New-Object System.Windows.Forms.Label
$script:ModeLabel.Text = 'Mode'
$script:ModeLabel.ForeColor = $script:ColMuted
$script:ModeLabel.Location = New-Object Drawing.Point(18, 9)
$script:ModeLabel.AutoSize = $true
$script:BottomPanel.Controls.Add($script:ModeLabel)

$script:RadioUninstall = New-Object System.Windows.Forms.RadioButton
$script:RadioUninstall.Text = 'Uninstall  (recommended)'
$script:RadioUninstall.Checked = $true
$script:RadioUninstall.ForeColor = $script:ColText
$script:RadioUninstall.Location = New-Object Drawing.Point(62, 6)
$script:RadioUninstall.AutoSize = $true
$script:BottomPanel.Controls.Add($script:RadioUninstall)

$script:RadioDisable = New-Object System.Windows.Forms.RadioButton
$script:RadioDisable.Text = 'Disable only'
$script:RadioDisable.ForeColor = $script:ColText
$script:RadioDisable.Location = New-Object Drawing.Point(246, 6)
$script:RadioDisable.AutoSize = $true
$script:BottomPanel.Controls.Add($script:RadioDisable)

$script:SelectCoreButton = New-FlatButton -Text 'Select core' -X 18 -Y 34 -W 108 -H 28
$script:BottomPanel.Controls.Add($script:SelectCoreButton)

$script:SelectAllButton = New-FlatButton -Text 'Core + optional' -X 132 -Y 34 -W 126 -H 28
$script:BottomPanel.Controls.Add($script:SelectAllButton)

$script:ClearButton = New-FlatButton -Text 'Clear' -X 264 -Y 34 -W 70 -H 28
$script:BottomPanel.Controls.Add($script:ClearButton)

$script:ApplyButton = New-FlatButton -Text 'Apply selected' -X 620 -Y 34 -W 165 -H 28 -Accent
$script:ApplyButton.Anchor = 'Bottom,Right'
$script:ApplyButton.Enabled = $false
$script:BottomPanel.Controls.Add($script:ApplyButton)

$script:RestoreButton = New-FlatButton -Text 'Restore selected' -X 793 -Y 34 -W 175 -H 28
$script:RestoreButton.Anchor = 'Bottom,Right'
$script:RestoreButton.Enabled = $false
$script:BottomPanel.Controls.Add($script:RestoreButton)

$script:UndoButton = New-FlatButton -Text 'Undo last run' -X 976 -Y 34 -W 170 -H 28
$script:UndoButton.Anchor = 'Bottom,Right'
$script:BottomPanel.Controls.Add($script:UndoButton)

$script:Progress = New-Object System.Windows.Forms.ProgressBar
$script:Progress.Location = New-Object Drawing.Point(620, 6)
$script:Progress.Size = New-Object Drawing.Size(526, 16)
$script:Progress.Anchor = 'Bottom,Right'
$script:Progress.Visible = $false
$script:BottomPanel.Controls.Add($script:Progress)

$script:StatusLabel = New-Object System.Windows.Forms.Label
$script:StatusLabel.Text = 'Ready.'
$script:StatusLabel.ForeColor = $script:ColMuted
$script:StatusLabel.Font = $script:FontSmall
$script:StatusLabel.Location = New-Object Drawing.Point(18, 66)
$script:StatusLabel.Size = New-Object Drawing.Size(1120, 16)
$script:StatusLabel.Anchor = 'Bottom,Left,Right'
$script:BottomPanel.Controls.Add($script:StatusLabel)

# docking order: top panel first, then bottom, then the grid fills the rest
$script:Form.Controls.SetChildIndex($script:Grid, 0)
$script:Form.Controls.SetChildIndex($script:BottomPanel, 1)
$script:Form.Controls.SetChildIndex($script:TopPanel, 2)

# ---------------------------------------------------------------- data helpers
function Set-DemoData {
    $info = [pscustomobject]@{
        Serial = 'DEMO123456'
        Manufacturer = 'Xiaomi'
        Brand = 'Redmi'
        Model = 'M2006C3MG'
        Device = 'cattail'
        Android = '10'
        Sdk = '29'
        Build = 'QKQ1.200830.002'
        OsName = 'MIUI 12'
        SecurityPatch = '2021-01-01'
    }
    $script:Device = [pscustomobject]@{ Serial = 'DEMO123456'; State = 'device'; Model = 'M2006C3MG' }
    $script:DeviceInfo = $info
    $file = Resolve-ProfileFile 'redmi-9c'
    $sections = Read-ProfileFile $file
    $script:ProfileFile = $file
    $script:ProfileName = 'redmi-9c'
    $script:Sections = $sections

    $states = @{}
    $i = 0
    foreach ($pkg in $sections['core']) {
        $i++
        if ($i % 7 -eq 0) { $states[$pkg] = 'uninstalled' }
        elseif ($i % 11 -eq 0) { $states[$pkg] = 'disabled' }
        else { $states[$pkg] = 'enabled' }
    }
    $i = 0
    foreach ($pkg in $sections['optional']) {
        $i++
        if ($i % 4 -eq 0) { $states[$pkg] = 'uninstalled' }
        elseif ($i % 3 -eq 0) { $states[$pkg] = 'disabled' }
        else { $states[$pkg] = 'enabled' }
    }
    foreach ($pkg in $sections['protect']) { $states[$pkg] = 'enabled' }
    $script:States = $states
    $script:Extras = @('com.android.deskclock', 'com.android.calculator2', 'com.google.android.apps.restore')
    $script:Connected = $true
    $script:LastChangeLog = $null
    if ((Get-ChangeLogFiles).Count -gt 0) { $script:LastChangeLog = (Get-ChangeLogFiles)[0].FullName }

    $script:DeviceLabel.Text = 'Redmi 9C (M2006C3MG)  -  MIUI 12  -  Android 10'
    $script:DeviceLabel.ForeColor = $script:ColText
    $script:ProfileLabel.Text = 'Demo preview - no phone connected. Nothing here can be applied.'
    $script:ProfileLabel.ForeColor = $script:ColAmber
    $script:ProfileCombo.SelectedItem = 'redmi-9c'
    $script:ProfileCombo.Enabled = $false
}

function Connect-RealDevice {
    param([switch]$Silent)
    try {
        $dev = Select-AndroidDevice -Serial $Serial
        $info = Get-DeviceInfo -Serial $dev.Serial
        $states = Get-PackageStates -Serial $dev.Serial
        if ($states.Count -eq 0) { throw 'Could not read the package list from the phone.' }

        # packages this tool removed earlier, even if the phone no longer lists them
        foreach ($logFile in (Get-ChangeLogFiles)) {
            $parsedLog = Read-ChangeLog -Path $logFile.FullName
            if ($parsedLog.Meta.ContainsKey('Serial') -and $parsedLog.Meta['Serial'] -ne $dev.Serial) { continue }
            foreach ($r in $parsedLog.Rows) {
                if (-not $states.ContainsKey($r.Package)) { $states[$r.Package] = 'uninstalled' }
            }
        }

        $file = $null
        $autoMatched = $false
        if ($Profile) { $file = Resolve-ProfileFile $Profile }
        if (-not $file) {
            $file = Find-ProfileForDevice $info
            if ($file) { $autoMatched = $true }
        }
        $script:ProfileAutoMatched = $autoMatched

        $script:Device = $dev
        $script:DeviceInfo = $info
        $script:States = $states
        $script:Connected = $true
        $script:Extras = @()

        if ($file) {
            $script:ProfileFile = $file
            $script:ProfileName = [IO.Path]::GetFileNameWithoutExtension($file)
            $script:Sections = Read-ProfileFile $file
        }
        else {
            $script:ProfileFile = $null
            $script:ProfileName = ''
            $script:Sections = $null
        }

        $script:DeviceLabel.Text = ("{0} {1}  -  {2}  -  Android {3}" -f $info.Manufacturer, $info.Model, $info.OsName, $info.Android)
        $script:DeviceLabel.ForeColor = $script:ColText
        $script:ProfileLabel.Text = ''
        $script:ProfileLabel.ForeColor = $script:ColMuted

        if (-not $file) {
            $script:ProfileLabel.Text = 'No profile matched this phone - choose one below.'
            $script:ProfileLabel.ForeColor = $script:ColAmber
            $script:ProfileCombo.SelectedIndex = -1
        }
        elseif (-not (Test-ProfileVendorMatch)) {
            $script:ProfileLabel.Text = ("Profile '{0}' is for a different brand - choose the right one." -f $script:ProfileName)
            $script:ProfileLabel.ForeColor = $script:ColAmber
            $script:ProfileCombo.SelectedItem = $script:ProfileName
        }
        else {
            $script:ProfileCombo.SelectedItem = $script:ProfileName
        }

        $script:ProfileCombo.Enabled = $true
        $script:LastChangeLog = $null
        if ((Get-ChangeLogFiles).Count -gt 0) { $script:LastChangeLog = (Get-ChangeLogFiles)[0].FullName }

        $script:ApplyButton.Enabled = $true
        $script:RebootButton.Enabled = $true
        $script:StatusLabel.Text = ("Connected to {0} ({1})." -f $info.Model, $dev.Serial)
    }
    catch {
        $script:Connected = $false
        $script:ApplyButton.Enabled = $false
        $script:RebootButton.Enabled = $false
        $script:DeviceLabel.Text = 'No phone connected'
        $script:DeviceLabel.ForeColor = $script:ColMuted
        if (-not $Silent) {
            $script:StatusLabel.Text = $_.Exception.Message
            [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Connection', 'OK', 'Warning')
        }
        else {
            $script:StatusLabel.Text = 'No phone connected. Enable USB debugging, plug in, then press Refresh.'
        }
        return
    }
}

function Build-Model {
    $script:Model.Clear()
    $script:ModelByPackage.Clear()
    $sections = $script:Sections
    if (-not $sections) { return }
    $protect = New-ProtectedSet $sections
    $seen = @{}

    foreach ($tier in @('core', 'optional', 'protect')) {
        if (-not $sections.ContainsKey($tier)) { continue }
        foreach ($pkg in $sections[$tier]) {
            if ($seen.ContainsKey($pkg)) { continue }
            $seen[$pkg] = $true
            if (-not $script:States.ContainsKey($pkg)) { continue }
            $meta = Get-PackageMeta $pkg
            $state = $script:States[$pkg]
            $isProtected = ($tier -eq 'protect') -or (Test-CriticalPackage -Package $pkg -ExtraProtect $protect)
            $m = [pscustomobject]@{
                Package   = $pkg
                Name      = $meta.Name
                Desc      = $meta.Desc
                Risk      = $meta.Risk
                Tier      = $tier
                State     = $state
                Protected = [bool]$isProtected
                Selected  = $false
            }
            $script:Model.Add($m)
            $script:ModelByPackage[$pkg] = $m
        }
    }

    foreach ($pkg in $script:Extras) {
        if ($seen.ContainsKey($pkg)) { continue }
        $seen[$pkg] = $true
        $meta = Get-PackageMeta $pkg
        $state = 'enabled'
        if ($script:States.ContainsKey($pkg)) { $state = $script:States[$pkg] }
        $isProtected = [bool](Test-CriticalPackage -Package $pkg)
        $tier = 'other'
        $risk = $meta.Risk
        if ($isProtected) { $tier = 'protect'; $risk = 'critical' }
        $m = [pscustomobject]@{
            Package   = $pkg
            Name      = $meta.Name
            Desc      = $meta.Desc
            Risk      = $risk
            Tier      = $tier
            State     = $state
            Protected = $isProtected
            Selected  = $false
        }
        $script:Model.Add($m)
        $script:ModelByPackage[$pkg] = $m
    }
}

function Get-ExtraPackages {
    if (-not $script:Sections) { return @() }
    $seen = @{}
    if ($script:Sections) {
        foreach ($tier in @('core', 'optional', 'protect')) {
            if (-not $script:Sections.ContainsKey($tier)) { continue }
            foreach ($pkg in $script:Sections[$tier]) { $seen[$pkg] = $true }
        }
    }
    $extras = New-Object 'System.Collections.Generic.List[string]'
    foreach ($pkg in ($script:States.Keys | Sort-Object)) {
        if ($seen.ContainsKey($pkg)) { continue }
        $extras.Add($pkg)
    }
    return $extras
}

function Test-RowVisible {
    param($Row)
    if ($Row.State -eq 'not installed') { return $false }
    if ($script:StateFilter -eq 'installed' -and $Row.State -ne 'enabled' -and $Row.State -ne 'disabled') { return $false }
    if ($script:StateFilter -eq 'removed' -and $Row.State -ne 'uninstalled') { return $false }
    if ($script:TierFilter -ne 'all' -and $Row.Tier -ne $script:TierFilter) { return $false }
    if ($script:SearchText) {
        $q = $script:SearchText
        if (-not ($Row.Package -like "*$q*" -or $Row.Name -like "*$q*" -or $Row.Desc -like "*$q*")) { return $false }
    }
    return $true
}

function Sync-GridSelection {
    foreach ($row in $script:Grid.Rows) {
        $pkg = [string]$row.Tag
        if ($pkg -and $script:ModelByPackage.ContainsKey($pkg)) {
            $script:ModelByPackage[$pkg].Selected = [bool]$row.Cells[0].Value
        }
    }
}

function Update-Grid {
    Sync-GridSelection
    $script:Grid.SuspendLayout()
    $script:Grid.Rows.Clear()
    $shown = 0
    foreach ($m in $script:Model) {
        if (-not (Test-RowVisible $m)) { continue }
        $idx = $script:Grid.Rows.Add($m.Selected, $m.Package, $m.Name, (Get-TierLabel $m.Tier), (Get-StateLabel $m.State), $m.Risk)
        $row = $script:Grid.Rows[$idx]
        $row.Tag = $m.Package
        $row.Cells[1].ToolTipText = $m.Desc
        $row.Cells[2].ToolTipText = $m.Desc

        if ($m.Protected) {
            $row.Cells[0].ReadOnly = $true
            $row.DefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(112, 112, 124)
        }
        elseif ($m.State -eq 'not installed') {
            $row.Cells[0].ReadOnly = $true
            $row.DefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(128, 128, 140)
        }
        elseif ($m.State -eq 'uninstalled') {
            $row.DefaultCellStyle.ForeColor = [Drawing.Color]::FromArgb(170, 170, 178)
        }

        if ($m.State -eq 'disabled') { $row.Cells[4].Style.ForeColor = $script:ColAmber }
        if ($m.State -eq 'uninstalled' -or $m.State -eq 'not installed') { $row.Cells[4].Style.ForeColor = $script:ColMuted }
        switch ($m.Risk) {
            'medium'   { $row.Cells[5].Style.ForeColor = $script:ColAmber }
            'high'     { $row.Cells[5].Style.ForeColor = $script:ColRed }
            'critical' { $row.Cells[5].Style.ForeColor = $script:ColRed }
            'unknown'  { $row.Cells[5].Style.ForeColor = $script:ColMuted }
        }
        $shown++
    }
    $script:Grid.ResumeLayout()
    $script:CountLabel.Text = ("{0} shown" -f $shown)
    Update-Status
}

function Update-Status {
    $installedSel = @($script:Model | Where-Object { $_.Selected -and -not $_.Protected -and ($_.State -eq 'enabled' -or $_.State -eq 'disabled') })
    $removedSel   = @($script:Model | Where-Object { $_.Selected -and -not $_.Protected -and $_.State -eq 'uninstalled' })
    $mode = 'uninstall'
    if ($script:RadioDisable.Checked) { $mode = 'disable' }
    if ($mode -eq 'disable') {
        $installedSel = @($installedSel | Where-Object { $_.State -eq 'enabled' })
    }
    $device = 'no device'
    if ($script:DeviceInfo) { $device = $script:DeviceInfo.Model }
    $script:StatusLabel.Text = ("{0}  |  {1}  |  {2} package(s)  |  {3} to remove  |  {4} to restore  |  mode: {5}" -f $device, $script:ProfileName, $script:Model.Count, $installedSel.Count, $removedSel.Count, $mode)
    $script:ApplyButton.Text = ("Apply selected ({0})" -f $installedSel.Count)
    $script:RestoreButton.Text = ("Restore selected ({0})" -f $removedSel.Count)

    $canApply = $script:Connected -and -not $script:Busy -and $installedSel.Count -gt 0
    $canRestore = $script:Connected -and -not $script:Busy -and $removedSel.Count -gt 0
    $script:ApplyButton.Enabled = [bool]$canApply
    $script:RestoreButton.Enabled = [bool]$canRestore

    if ($canApply) {
        $script:ApplyButton.BackColor = $script:ColAccent
        $script:ApplyButton.ForeColor = [Drawing.Color]::White
    }
    else {
        $script:ApplyButton.BackColor = [Drawing.Color]::FromArgb(44, 62, 92)
        $script:ApplyButton.ForeColor = [Drawing.Color]::FromArgb(150, 150, 162)
    }
    if ($canRestore) {
        $script:RestoreButton.BackColor = $script:ColGreen
        $script:RestoreButton.ForeColor = [Drawing.Color]::White
    }
    else {
        $script:RestoreButton.BackColor = $script:ColPanel2
        $script:RestoreButton.ForeColor = [Drawing.Color]::FromArgb(150, 150, 162)
    }
    $script:UndoButton.Enabled = $script:Connected -and -not $script:Busy
}

function Set-Busy {
    param([bool]$Busy)
    $script:Busy = $Busy
    $script:RefreshButton.Enabled = -not $Busy
    $script:SelectCoreButton.Enabled = -not $Busy
    $script:SelectAllButton.Enabled = -not $Busy
    $script:ClearButton.Enabled = -not $Busy
    $script:UndoButton.Enabled = -not $Busy
    if ($Busy) {
        $script:ApplyButton.Enabled = $false
        $script:RestoreButton.Enabled = $false
    }
    else { Update-Status }
    $script:Form.Cursor = if ($Busy) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default }
}

# ---------------------------------------------------------------- actions
function Invoke-Refresh {
    param([switch]$Silent)
    if ($script:Busy) { return }
    Set-Busy $true
    try {
        if ($script:DemoMode) {
            Set-DemoData
        }
        else {
            Connect-RealDevice -Silent:$Silent
            if (-not $script:Connected) {
                $script:Grid.Rows.Clear()
                $script:Model.Clear()
                $script:ModelByPackage.Clear()
                $script:CountLabel.Text = '0 shown'
                return
            }
            $script:Extras = Get-ExtraPackages
        }
        Build-Model
        Update-Grid
    }
    finally {
        Set-Busy $false
    }
}

function Set-ProfileSelection {
    param([string]$Name)
    $file = Resolve-ProfileFile $Name
    if (-not $file) { return }
    $script:ProfileFile = $file
    $script:ProfileName = [IO.Path]::GetFileNameWithoutExtension($file)
    $script:Sections = Read-ProfileFile $file
    $script:Extras = Get-ExtraPackages
    Build-Model
    Update-Grid
    if (-not (Test-ProfileVendorMatch)) {
        $script:ProfileLabel.Text = ("Profile '{0}' is for a different brand - choose the right one." -f $script:ProfileName)
        $script:ProfileLabel.ForeColor = $script:ColAmber
    }
    else {
        $script:ProfileLabel.Text = ''
        $script:ProfileLabel.ForeColor = $script:ColMuted
    }
}

function Select-Tier {
    param([string[]]$Tiers)
    Sync-GridSelection
    foreach ($m in $script:Model) {
        if ($m.Protected) { continue }
        if ($m.State -ne 'enabled' -and $m.State -ne 'disabled') { continue }
        $m.Selected = ($Tiers -contains $m.Tier)
    }
    Update-Grid
}

function Clear-Selection {
    Sync-GridSelection
    foreach ($m in $script:Model) { $m.Selected = $false }
    Update-Grid
}

function Invoke-Apply {
    if ($script:DemoMode) {
        [void][System.Windows.Forms.MessageBox]::Show('This is only a preview. Connect a phone and press Refresh to apply changes.', 'Demo mode', 'OK', 'Information')
        return
    }
    if (-not $script:Connected) { return }
    if (-not $script:Sections -or -not $script:ProfileName) {
        [void][System.Windows.Forms.MessageBox]::Show('Choose a profile first.', 'Apply', 'OK', 'Information')
        return
    }
    if (-not (Test-ProfileVendorMatch)) {
        $warn = [System.Windows.Forms.MessageBox]::Show(
            ("Profile '{0}' is for a different brand than {1}.`n`nThis can remove the wrong apps. Continue anyway?" -f $script:ProfileName, $script:DeviceInfo.Manufacturer),
            'Wrong profile?', 'YesNo', 'Warning')
        if ($warn -ne 'Yes') { return }
    }
    Sync-GridSelection
    $mode = 'uninstall'
    if ($script:RadioDisable.Checked) { $mode = 'disable' }
    $selected = @($script:Model | Where-Object {
        $_.Selected -and -not $_.Protected -and
        ($_.State -eq 'enabled' -or $_.State -eq 'disabled') -and
        -not ($mode -eq 'disable' -and $_.State -eq 'disabled')
    })
    if ($selected.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Nothing selected.', 'Apply', 'OK', 'Information')
        return
    }

    $verb = 'uninstall'
    if ($mode -eq 'disable') { $verb = 'disable' }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("{0} {1} package(s) on {2}?`n`nA snapshot and an undo log will be written first." -f $verb, $selected.Count, $script:DeviceInfo.Model),
        'Confirm', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }

    Set-Busy $true
    $script:Progress.Visible = $true
    $script:Progress.Minimum = 0
    $script:Progress.Maximum = $selected.Count
    $script:Progress.Value = 0

    $snap = Save-PackageSnapshot -Serial $script:Device.Serial -Slug (Get-DeviceSlug $script:DeviceInfo) -States $script:States
    $changeFile = Join-Path $script:LogDir ("{0}-{1}-changes.tsv" -f (Get-DeviceSlug $script:DeviceInfo), (Get-Stamp))
    $header = @(
        '# android-debloater change log v1 (gui)'
        ("# date={0} serial={1} model={2} profile={3} mode={4}" -f (Get-Date).ToString('s'), $script:Device.Serial, $script:DeviceInfo.Model, $script:ProfileName, $mode)
        '# package<TAB>action<TAB>prior-state'
    )
    Set-Content -LiteralPath $changeFile -Value $header -Encoding UTF8

    $applied = 0
    $failed = 0
    $i = 0
    foreach ($m in $selected) {
        $i++
        $priorState = $m.State
        $script:StatusLabel.Text = ("{0} / {1}: {2}" -f $i, $selected.Count, $m.Package)
        $script:Progress.Value = $i - 1
        [System.Windows.Forms.Application]::DoEvents()

        $resultText = ''
        $ok = $false
        try {
            if ($mode -eq 'disable') {
                $r = Invoke-Adb -AdbArgs @('-s', $script:Device.Serial, 'shell', 'pm', 'disable-user', '--user', '0', $m.Package) -AllowFail
                $resultText = $r.Text
                if ($resultText -match 'new state:\s*disabled') { $ok = $true }
            }
            else {
                $r = Invoke-Adb -AdbArgs @('-s', $script:Device.Serial, 'shell', 'pm', 'uninstall', '-k', '--user', '0', $m.Package) -AllowFail
                $resultText = $r.Text
                if ($resultText -notmatch 'Success') {
                    $r = Invoke-Adb -AdbArgs @('-s', $script:Device.Serial, 'shell', 'pm', 'uninstall', '--user', '0', $m.Package) -AllowFail
                    $resultText = $r.Text
                }
                if ($resultText -match 'Success') { $ok = $true }
            }
        }
        catch {
            $resultText = $_.Exception.Message
        }

        if ($ok) {
            $applied++
            $m.Selected = $false
            if ($mode -eq 'disable') { $m.State = 'disabled' } else { $m.State = 'uninstalled' }
            Add-Content -LiteralPath $changeFile -Value ("{0}`t{1}`t{2}" -f $m.Package, $mode, $priorState) -Encoding UTF8
            foreach ($row in $script:Grid.Rows) {
                if ([string]$row.Tag -eq $m.Package) { $row.Cells[4].Value = Get-StateLabel $m.State }
            }
        }
        else {
            $failed++
        }
        $script:Progress.Value = $i
        [System.Windows.Forms.Application]::DoEvents()
    }

    $script:Progress.Visible = $false
    Set-Busy $false
    $script:LastChangeLog = $changeFile
    Update-Grid
    [void][System.Windows.Forms.MessageBox]::Show(
        ("Applied: {0}`nFailed: {1}`n`nUndo log:`n{2}" -f $applied, $failed, $changeFile),
        'Done', 'OK', 'Information')
}

function Invoke-Restore {
    if ($script:DemoMode) {
        [void][System.Windows.Forms.MessageBox]::Show('This is only a preview. Connect a phone and press Refresh to restore packages.', 'Demo mode', 'OK', 'Information')
        return
    }
    if (-not $script:Connected -or -not $script:Device) {
        [void][System.Windows.Forms.MessageBox]::Show('Connect a phone first.', 'Restore', 'OK', 'Information')
        return
    }
    Sync-GridSelection
    $selected = @($script:Model | Where-Object { $_.Selected -and -not $_.Protected -and $_.State -eq 'uninstalled' })
    if ($selected.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('Set the state filter to Removed, tick the apps, then press Restore selected.', 'Restore', 'OK', 'Information')
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Restore {0} removed package(s) on {1}?`n`nThey will reappear in the app drawer." -f $selected.Count, $script:DeviceInfo.Model),
        'Restore', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }

    Set-Busy $true
    $script:Progress.Visible = $true
    $script:Progress.Minimum = 0
    $script:Progress.Maximum = $selected.Count
    $script:Progress.Value = 0
    $restored = 0
    $failed = 0
    $i = 0
    foreach ($m in $selected) {
        $i++
        $script:StatusLabel.Text = ("restoring {0} / {1}: {2}" -f $i, $selected.Count, $m.Package)
        $script:Progress.Value = $i - 1
        [System.Windows.Forms.Application]::DoEvents()
        $res = Invoke-Adb -AdbArgs @('-s', $script:Device.Serial, 'shell', 'pm', 'install-existing', '--user', '0', $m.Package) -AllowFail
        $ok = (($res.Text -match 'installed') -or ($res.ExitCode -eq 0)) -and ($res.Text -notmatch '(?i)error|exception|unknown')
        if ($ok) {
            $restored++
            $m.Selected = $false
            $m.State = 'enabled'
            foreach ($row in $script:Grid.Rows) {
                if ([string]$row.Tag -eq $m.Package) { $row.Cells[4].Value = Get-StateLabel $m.State }
            }
        }
        else {
            $failed++
        }
        $script:Progress.Value = $i
        [System.Windows.Forms.Application]::DoEvents()
    }
    $script:Progress.Visible = $false
    Set-Busy $false
    Update-Grid
    [void][System.Windows.Forms.MessageBox]::Show(
        ("Restored: {0}`nFailed: {1}" -f $restored, $failed),
        'Restore', 'OK', 'Information')
}

function Invoke-Undo {
    if ($script:DemoMode) {
        [void][System.Windows.Forms.MessageBox]::Show('Demo mode: nothing was changed.', 'Undo', 'OK', 'Information')
        return
    }
    if (-not $script:Connected -or -not $script:Device) {
        [void][System.Windows.Forms.MessageBox]::Show('Connect a phone first.', 'Undo', 'OK', 'Information')
        return
    }
    $file = $script:LastChangeLog
    if (-not $file -or -not (Test-Path -LiteralPath $file)) {
        $files = @(Get-ChangeLogFiles)
        if ($files.Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show('No change logs found.', 'Undo', 'OK', 'Information')
            return
        }
        $file = $files[0].FullName
    }
    $log = Read-ChangeLog -Path $file
    $rows = @($log.Rows)
    if ($rows.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show('That log is empty.', 'Undo', 'OK', 'Information')
        return
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        ("Restore {0} package(s) from:`n{1}?`n`nReboot the phone afterwards." -f $rows.Count, (Split-Path $file -Leaf)),
        'Undo', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }

    Set-Busy $true
    $script:Progress.Visible = $true
    $script:Progress.Maximum = $rows.Count
    $script:Progress.Value = 0
    $restored = 0
    $failed = 0
    $i = 0
    foreach ($r in $rows) {
        $i++
        $script:StatusLabel.Text = ("restoring {0} / {1}: {2}" -f $i, $rows.Count, $r.Package)
        $script:Progress.Value = $i - 1
        [System.Windows.Forms.Application]::DoEvents()
        $res = $null
        if ($r.Action -eq 'uninstall') {
            $res = Invoke-Adb -AdbArgs @('-s', $script:Device.Serial, 'shell', 'pm', 'install-existing', '--user', '0', $r.Package) -AllowFail
            if ($res.Text -match 'installed' -or $res.ExitCode -eq 0) { $restored++ } else { $failed++ }
        }
        else {
            $res = Invoke-Adb -AdbArgs @('-s', $script:Device.Serial, 'shell', 'pm', 'enable', $r.Package) -AllowFail
            if ($res.Text -notmatch '(?i)error|exception|unknown') { $restored++ } else { $failed++ }
        }
        $script:Progress.Value = $i
        [System.Windows.Forms.Application]::DoEvents()
    }
    $script:Progress.Visible = $false
    Set-Busy $false

    try {
        $script:States = Get-PackageStates -Serial $script:Device.Serial
        $script:Extras = Get-ExtraPackages
        Build-Model
        Update-Grid
    }
    catch { }
    [void][System.Windows.Forms.MessageBox]::Show(("Restored: {0}`nFailed: {1}`n`nReboot the phone." -f $restored, $failed), 'Undo', 'OK', 'Information')
}

function Invoke-Reboot {
    if ($script:DemoMode -or -not $script:Connected) { return }
    $answer = [System.Windows.Forms.MessageBox]::Show('Reboot the phone now?', 'Reboot', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    Invoke-Adb -AdbArgs @('-s', $script:Device.Serial, 'reboot') -AllowFail | Out-Null
    $script:StatusLabel.Text = 'Reboot command sent. Reconnect when the phone boots.'
}

# ---------------------------------------------------------------- events
function Set-TopButtonPositions {
    $w = $script:TopPanel.ClientSize.Width
    if ($w -lt 600) { return }
    $script:RefreshButton.Location = New-Object Drawing.Point(($w - 128), 12)
    $script:RebootButton.Location = New-Object Drawing.Point(($w - 128), 50)
    $script:LogsButton.Location = New-Object Drawing.Point(($w - 276), 50)
}

$script:RefreshButton.Add_Click({ Invoke-Refresh })
$script:RebootButton.Add_Click({ Invoke-Reboot })

$script:LogsButton.Add_Click({
    if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
    Start-Process -FilePath 'explorer.exe' -ArgumentList $script:LogDir
})

$script:ProfileCombo.Add_SelectedIndexChanged({
    if ($script:Busy -or -not $script:Connected) { return }
    $name = [string]$script:ProfileCombo.SelectedItem
    if ($name -and $name -ne $script:ProfileName) { Set-ProfileSelection $name }
})

$script:SearchBox.Add_TextChanged({
    $script:SearchText = $script:SearchBox.Text.Trim()
    Update-Grid
})

$script:TierCombo.Add_SelectedIndexChanged({
    switch ($script:TierCombo.SelectedIndex) {
        0 { $script:TierFilter = 'all' }
        1 { $script:TierFilter = 'core' }
        2 { $script:TierFilter = 'optional' }
        3 { $script:TierFilter = 'protect' }
        4 { $script:TierFilter = 'other' }
    }
    Update-Grid
})

$script:StateCombo.Add_SelectedIndexChanged({
    switch ($script:StateCombo.SelectedIndex) {
        0 { $script:StateFilter = 'installed' }
        1 { $script:StateFilter = 'removed' }
        2 { $script:StateFilter = 'all' }
    }
    Update-Grid
})

$script:SelectCoreButton.Add_Click({ Select-Tier @('core') })
$script:SelectAllButton.Add_Click({ Select-Tier @('core', 'optional') })
$script:ClearButton.Add_Click({ Clear-Selection })
$script:ApplyButton.Add_Click({ Invoke-Apply })
$script:RestoreButton.Add_Click({ Invoke-Restore })
$script:UndoButton.Add_Click({ Invoke-Undo })
$script:RadioUninstall.Add_CheckedChanged({ Update-Status })
$script:RadioDisable.Add_CheckedChanged({ Update-Status })

$script:Grid.Add_CellValueChanged({
    param($sender, $e)
    if ($e.ColumnIndex -eq 0) { Update-Status }
})

$script:Grid.Add_CurrentCellDirtyStateChanged({
    if ($script:Grid.IsCurrentCellDirty) { $script:Grid.CommitEdit('CommitChange') }
})

$script:Grid.Add_CellDoubleClick({
    param($sender, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -eq 0) { return }
    $row = $script:Grid.Rows[$e.RowIndex]
    if ($row.Cells[0].ReadOnly) { return }
    $row.Cells[0].Value = -not [bool]$row.Cells[0].Value
})

# ---------------------------------------------------------------- startup
function Start-CaptureTimer {
    $script:CaptureTimer = New-Object System.Windows.Forms.Timer
    $script:CaptureTimer.Interval = 1600
    $script:CaptureTimer.Add_Tick({
        $this.Stop()
        try {
            $script:Form.TopMost = $true
            $script:Form.Activate()
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 350
            $size = $script:Form.ClientSize
            $bmp = New-Object System.Drawing.Bitmap($size.Width, $size.Height)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $origin = $script:Form.PointToScreen([Drawing.Point]::Empty)
            $g.CopyFromScreen($origin, [Drawing.Point]::Empty, $size)
            $g.Dispose()
            $bmp.Save($script:CapturePath, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            Write-Host ("capture saved: " + $script:CapturePath)
        }
        catch {
            Write-Host ("capture failed: " + $_.Exception.Message)
        }
        $script:Form.Close()
    })
    $script:CaptureTimer.Start()
}

$script:Form.Add_Shown({
    Set-TopButtonPositions
    if ($script:DemoMode) {
        Set-DemoData
        Build-Model
        Update-Grid
    }
    else {
        Invoke-Refresh -Silent
    }
    if ($script:CapturePath) { Start-CaptureTimer }
})

$script:Form.Add_Resize({ Set-TopButtonPositions })

[void]$script:Form.ShowDialog()
