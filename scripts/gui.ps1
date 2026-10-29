#Requires -Version 5.1
<#
.SYNOPSIS
    DeBloatZal - WebView2 UI for Android debloating, compact and install-free.

.DESCRIPTION
    The window is a thin PowerShell + WebView2 host. All layout lives in
    .\gui (HTML/CSS/JS), all phone work lives here and in common.ps1.
    WebView2 runtime ships with Windows/Edge; the small .NET wrapper DLLs are
    bundled in .\gui\lib so there is nothing to install.

.EXAMPLE
    .\scripts\gui.ps1
    .\scripts\gui.ps1 -Demo
    .\scripts\gui.ps1 -Demo -State removed
#>
[CmdletBinding()]
param(
    [string]$Serial,
    [string]$Profile,
    [ValidateSet('recommended', 'optional', 'critical', 'all', 'removed')][string]$State = 'recommended',
    [switch]$Demo,
    [switch]$Windowed,
    [switch]$UserOnly,
    [string]$Search,
    [string]$Capture
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$script:RootDir   = Split-Path -Parent $PSScriptRoot
$script:GuiDir    = Join-Path $script:RootDir 'gui'
$script:IndexFile = Join-Path $script:GuiDir 'index.html'
$script:LibDir    = Join-Path $script:GuiDir 'lib'
$script:InfoFile  = Join-Path $script:RootDir 'data\package-info.json'

$script:DemoMode    = [bool]$Demo
$script:StartMaximized = -not [bool]$Windowed
$script:InitialUserOnly = [bool]$UserOnly
$script:InitialSearch = [string]$Search
$script:InitialView = $State
$script:CapturePath = $Capture
$script:Connected   = $false
$script:Busy        = $false
$script:Device      = $null
$script:DeviceInfo  = $null
$script:States      = @{}
$script:UserPackages = @{}
$script:Sections    = $null
$script:ProtectSet  = @{}
$script:ProfileFile = $null
$script:ProfileName = ''
$script:DeviceWarning = ''
$script:Wv          = $null
$script:Form        = $null
$script:Maximized   = $false
$script:RestoreBounds = $null

# ---------------------------------------------------------------- native bits
if (-not ('DebloaterNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DebloaterNative {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool ReleaseCapture();
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, int Msg, int wParam, int lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool SetDllDirectory(string lpPathName);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr hdc, int index);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
}
'@
}
[void][DebloaterNative]::SetProcessDPIAware()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$coreDll = Join-Path $script:LibDir 'Microsoft.Web.WebView2.Core.dll'
$winDll  = Join-Path $script:LibDir 'Microsoft.Web.WebView2.WinForms.dll'
$loadDll = Join-Path $script:LibDir 'WebView2Loader.dll'

function Start-ClassicFallback {
    param([string]$Reason)
    [void][System.Windows.Forms.MessageBox]::Show(
        ("The modern UI could not start: {0}`n`nOpening the classic window instead." -f $Reason),
        'DeBloatZal', 'OK', 'Warning')
    $classicState = 'installed'
    if ($script:InitialView -eq 'removed') { $classicState = 'removed' }
    elseif ($script:InitialView -eq 'all') { $classicState = 'all' }
    & (Join-Path $PSScriptRoot 'gui-classic.ps1') -Serial $Serial -Profile $Profile -Demo:$Demo -State $classicState -Capture $Capture
}

if (-not (Test-Path -LiteralPath $coreDll) -or -not (Test-Path -LiteralPath $winDll) -or -not (Test-Path -LiteralPath $loadDll)) {
    Start-ClassicFallback 'WebView2 wrapper libraries are missing from gui\lib'
    return
}

[void][DebloaterNative]::SetDllDirectory($script:LibDir)
$env:PATH = "$($script:LibDir);$env:PATH"

try {
    if (-not ('Microsoft.Web.WebView2.WinForms.WebView2' -as [type])) {
        Add-Type -Path $coreDll
        Add-Type -Path $winDll
    }
    $runtimeVersion = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString()
    if (-not $runtimeVersion) { throw 'WebView2 runtime is not installed.' }
}
catch {
    Start-ClassicFallback $_.Exception.Message
    return
}

# ---------------------------------------------------------------- metadata
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
    catch { }
}

function Get-FriendlyName {
    param([string]$Package)
    $parts = $Package -split '\.'
    $leaf = $parts[-1]
    $generic = @('android', 'app', 'apps', 'mobile', 'client', 'messenger', 'editor', 'motion', 'free', 'lite', 'pro', 'release')
    if ($generic -contains $leaf.ToLowerInvariant() -and $parts.Count -ge 2) { $leaf = $parts[-2] }
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

function Get-Recommendation {
    param([string]$Tier, [string]$Risk, [bool]$Protected)
    if ($Protected -or $Risk -eq 'critical') {
        return @{ Key = 'critical'; Label = 'Do not remove'; Rank = 4; Why = 'System-critical package. The tool locks it so the phone keeps booting and working.' }
    }
    if ($Risk -eq 'high') {
        return @{ Key = 'risky'; Label = 'Risky'; Rank = 3; Why = 'Removing this breaks a core feature. Keep it unless you know exactly what you lose.' }
    }
    if ($Risk -eq 'medium') {
        return @{ Key = 'caution'; Label = 'Caution'; Rank = 2; Why = 'Some features can stop working. Review this one before removing it.' }
    }
    if ($Tier -eq 'core') {
        return @{ Key = 'recommended'; Label = 'Safe'; Rank = 0; Why = 'Ads, telemetry or preloads with no useful feature. Safe to remove on this phone.' }
    }
    if ($Tier -eq 'optional') {
        return @{ Key = 'optional'; Label = 'Optional'; Rank = 1; Why = 'You may use this app. Remove it only if you have a replacement or do not need it.' }
    }
    return @{ Key = 'unknown'; Label = 'Unknown'; Rank = 5; Why = 'Not in the curated list. Research this package before touching it.' }
}

function Get-ProfileNames {
    return @(Get-ChildItem -LiteralPath $script:ProfileDir -Filter '*.profile' -ErrorAction SilentlyContinue |
        Sort-Object Name | ForEach-Object { $_.BaseName })
}

function Set-ProfileInternal {
    param([string]$File)
    $script:ProfileFile = $File
    $script:ProfileName = [IO.Path]::GetFileNameWithoutExtension($File)
    $script:Sections = Read-ProfileFile $File
    $script:ProtectSet = New-ProtectedSet $script:Sections
}

function New-Row {
    param([string]$Package, [string]$Tier)
    $meta = Get-PackageMeta $Package
    $state = $script:States[$Package]
    $protected = ($Tier -eq 'protect') -or (Test-CriticalPackage -Package $Package -ExtraProtect $script:ProtectSet)
    if ($protected) { $Tier = 'protect' }
    $risk = $meta.Risk
    if ($protected) { $risk = 'critical' }
    $rec = Get-Recommendation -Tier $Tier -Risk $risk -Protected $protected
    $isUser = ($script:UserPackages.ContainsKey($Package)) -and ($Tier -eq 'other')
    if ($isUser -and -not $protected) {
        $rec = @{
            Key = 'user'
            Label = 'Your app'
            Rank = 6
            Why = 'Third-party app you installed. Remove it only if you no longer use it.'
        }
    }
    [pscustomobject]@{
        id        = $Package
        name      = $meta.Name
        desc      = $meta.Desc
        tier      = $Tier
        state     = $state
        risk      = $risk
        protected = [bool]$protected
        rec       = $rec.Key
        recLabel  = $rec.Label
        why       = $rec.Why
        rank      = $rec.Rank
        user      = $isUser
    }
}

function Get-Rows {
    if (-not $script:Sections -or $script:States.Count -eq 0) { return @() }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}

    foreach ($tier in @('core', 'optional', 'protect')) {
        if (-not $script:Sections.ContainsKey($tier)) { continue }
        foreach ($pkg in $script:Sections[$tier]) {
            if ($seen.ContainsKey($pkg)) { continue }
            $seen[$pkg] = $true
            if (-not $script:States.ContainsKey($pkg)) { continue }
            $rows.Add((New-Row -Package $pkg -Tier $tier))
        }
    }

    foreach ($pkg in ($script:States.Keys | Sort-Object)) {
        if ($seen.ContainsKey($pkg)) { continue }
        $seen[$pkg] = $true
        $rows.Add((New-Row -Package $pkg -Tier 'other'))
    }

    return $rows
}

# ---------------------------------------------------------------- bridge
function Send-Json {
    param([hashtable]$Payload)
    if (-not $script:Wv -or -not $script:Wv.CoreWebView2) { return }
    try {
        $json = $Payload | ConvertTo-Json -Depth 8 -Compress
        $script:Wv.CoreWebView2.PostWebMessageAsJson($json)
    }
    catch { }
}

function Send-Toast {
    param([string]$Text, [string]$Kind = '')
    Send-Json @{ type = 'toast'; text = $Text; kind = $Kind }
}

function Toggle-Maximize {
    if (-not $script:Form) { return }
    if ($script:Maximized) {
        if ($script:RestoreBounds) { $script:Form.Bounds = $script:RestoreBounds }
        $script:Maximized = $false
    }
    else {
        $script:RestoreBounds = $script:Form.Bounds
        $screen = [System.Windows.Forms.Screen]::FromHandle($script:Form.Handle)
        $script:Form.Bounds = $screen.WorkingArea
        $script:Maximized = $true
    }
    try {
        $pref = if ($script:Maximized) { 1 } else { 2 }
        [void][DebloaterNative]::DwmSetWindowAttribute($script:Form.Handle, 33, [ref]$pref, 4)
    }
    catch { }
    Send-Json @{ type = 'windowState'; maximized = $script:Maximized }
}

function Get-DevicePayload {
    if (-not $script:DeviceInfo) { return $null }
    return @{
        manufacturer = $script:DeviceInfo.Manufacturer
        model        = $script:DeviceInfo.Model
        codename     = $script:DeviceInfo.Device
        android      = $script:DeviceInfo.Android
        os           = $script:DeviceInfo.OsName
        serial       = $script:DeviceInfo.Serial
        warning      = $script:DeviceWarning
    }
}

function Send-DeviceInfo {
    Send-Json @{
        type     = 'device'
        device   = (Get-DevicePayload)
        profiles = @(Get-ProfileNames)
        profile  = $script:ProfileName
        demo     = $script:DemoMode
    }
}

function Send-Packages {
    Send-Json @{ type = 'packages'; packages = @(Get-Rows) }
}

function Send-Init {
    Send-Json @{
        type     = 'init'
        device   = (Get-DevicePayload)
        profiles = @(Get-ProfileNames)
        profile  = $script:ProfileName
        demo     = $script:DemoMode
        view     = $script:InitialView
        userOnly = $script:InitialUserOnly
        search   = $script:InitialSearch
        packages = @(Get-Rows)
    }
}

# ---------------------------------------------------------------- device
function Connect-Device {
    param([switch]$Silent)
    try {
        $dev = Select-AndroidDevice -Serial $Serial
        $info = Get-DeviceInfo -Serial $dev.Serial
        $states = Get-PackageStates -Serial $dev.Serial
        if ($states.Count -eq 0) { throw 'Could not read the package list from the phone.' }

        $userPackages = @{}
        $userResult = Invoke-Adb -AdbArgs @('-s', $dev.Serial, 'shell', 'pm', 'list', 'packages', '-3', '-u') -AllowFail
        foreach ($line in ($userResult.Text -split "`n")) {
            if ($line -match '^package:(.+?)\s*$') { $userPackages[$matches[1]] = $true }
        }
        $script:UserPackages = $userPackages

        $file = $null
        if ($Profile) { $file = Resolve-ProfileFile $Profile }
        if (-not $file) { $file = Find-ProfileForDevice $info }

        $script:Device = $dev
        $script:DeviceInfo = $info
        $script:States = $states
        $script:Connected = $true
        $script:DeviceWarning = ''

        if ($file) {
            Set-ProfileInternal $file
            if (-not (Test-ProfileVendorMatch)) {
                $script:DeviceWarning = ("Profile '{0}' is for a different brand. Pick the right profile." -f $script:ProfileName)
            }
        }
        else {
            $script:ProfileFile = $null
            $script:ProfileName = ''
            $script:Sections = $null
            $script:ProtectSet = @{}
            $script:DeviceWarning = 'No profile matched this phone. Pick one from the profile menu.'
        }

        return $true
    }
    catch {
        $script:Connected = $false
        $script:Device = $null
        $script:DeviceInfo = $null
        $script:States = @{}
        $script:ProfileFile = $null
        $script:ProfileName = ''
        $script:Sections = $null
        $script:ProtectSet = @{}
        $script:DeviceWarning = ''
        $script:UserPackages = @{}
        if (-not $Silent) { Send-Json @{ type = 'error'; text = $_.Exception.Message } }
        return $false
    }
}

function Set-DemoState {
    $info = [pscustomobject]@{
        Serial        = 'DEMO123456'
        Manufacturer  = 'Xiaomi'
        Brand         = 'Redmi'
        Model         = 'M2006C3MG'
        Device        = 'cattail'
        Android       = '10'
        Sdk           = '29'
        Build         = 'QKQ1.200830.002'
        OsName        = 'MIUI 12'
        SecurityPatch = '2021-01-01'
    }
    $file = Resolve-ProfileFile 'redmi-9c'
    Set-ProfileInternal $file

    $states = @{}
    $i = 0
    foreach ($pkg in $script:Sections['core']) {
        $i++
        if ($i % 7 -eq 0) { $states[$pkg] = 'uninstalled' }
        elseif ($i % 11 -eq 0) { $states[$pkg] = 'disabled' }
        else { $states[$pkg] = 'enabled' }
    }
    $i = 0
    foreach ($pkg in $script:Sections['optional']) {
        $i++
        if ($i % 4 -eq 0) { $states[$pkg] = 'uninstalled' }
        elseif ($i % 3 -eq 0) { $states[$pkg] = 'disabled' }
        else { $states[$pkg] = 'enabled' }
    }
    foreach ($pkg in $script:Sections['protect']) { $states[$pkg] = 'enabled' }
    $states['com.android.deskclock'] = 'enabled'
    $states['com.android.calculator2'] = 'enabled'
    $states['com.google.android.apps.restore'] = 'enabled'
    $states['com.whatsapp'] = 'enabled'
    $states['com.instagram.android'] = 'enabled'
    $states['com.telegram.messenger'] = 'enabled'

    $script:Device = [pscustomobject]@{ Serial = 'DEMO123456'; State = 'device' }
    $script:DeviceInfo = $info
    $script:States = $states
    $script:UserPackages = @{
        'com.whatsapp' = $true
        'com.instagram.android' = $true
        'com.telegram.messenger' = $true
    }
    $script:Connected = $true
    $script:DemoMode = $true
    $script:DeviceWarning = ''
}

# ---------------------------------------------------------------- actions
function Invoke-ApplyAction {
    param($Ids)
    if ($script:DemoMode) { Send-Toast 'Preview only - connect a phone to apply changes.' 'warn'; return }
    if ($script:Busy -or -not $script:Connected -or -not $script:DeviceInfo) { return }

    $valid = New-Object 'System.Collections.Generic.List[string]'
    foreach ($id in @($Ids | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace([string]$id)) { continue }
        if (-not $script:States.ContainsKey($id)) { continue }
        if ($script:States[$id] -eq 'uninstalled') { continue }
        if (Test-CriticalPackage -Package $id -ExtraProtect $script:ProtectSet) { continue }
        $valid.Add($id)
    }
    if ($valid.Count -eq 0) { Send-Toast 'Nothing to do.' 'warn'; return }

    $script:Busy = $true
    Send-Json @{ type = 'busy'; value = $true; text = 'Applying changes...' }
    [System.Windows.Forms.Application]::DoEvents()

    $applied = 0
    $failed = 0
    $i = 0
    foreach ($pkg in $valid) {
        $i++
        Send-Json @{ type = 'progress'; value = $i; total = $valid.Count; text = ("Removing {0} / {1}" -f ($i - 1), $valid.Count) }
        [System.Windows.Forms.Application]::DoEvents()

        $ok = $false
        $text = ''
        try {
            $r = Invoke-Adb -AdbArgs @('-s', $script:Device.Serial, 'shell', 'pm', 'uninstall', '-k', '--user', '0', $pkg) -AllowFail
            $text = $r.Text
            if ($text -notmatch 'Success') {
                $r = Invoke-Adb -AdbArgs @('-s', $script:Device.Serial, 'shell', 'pm', 'uninstall', '--user', '0', $pkg) -AllowFail
                $text = $r.Text
            }
            if ($text -match 'Success') { $ok = $true }
        }
        catch { $text = $_.Exception.Message }

        if ($ok) {
            $applied++
            $script:States[$pkg] = 'uninstalled'
        }
        else { $failed++ }

        Send-Json @{ type = 'progress'; value = $i; total = $valid.Count; text = ("Removing {0} / {1}" -f $i, $valid.Count) }
        [System.Windows.Forms.Application]::DoEvents()
    }

    $script:Busy = $false
    Send-Json @{ type = 'done'; kind = 'apply'; applied = $applied; failed = $failed }
    Send-Packages
}

function Invoke-RestoreAction {
    param($Ids)
    if ($script:DemoMode) { Send-Toast 'Preview only - connect a phone to restore.' 'warn'; return }
    if ($script:Busy -or -not $script:Connected -or -not $script:DeviceInfo) { return }

    $valid = New-Object 'System.Collections.Generic.List[string]'
    foreach ($id in @($Ids | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace([string]$id)) { continue }
        if (-not $script:States.ContainsKey($id)) { continue }
        if ($script:States[$id] -ne 'uninstalled') { continue }
        $valid.Add($id)
    }
    if ($valid.Count -eq 0) { Send-Toast 'Nothing to restore.' 'warn'; return }

    $script:Busy = $true
    Send-Json @{ type = 'busy'; value = $true; text = 'Restoring packages...' }
    [System.Windows.Forms.Application]::DoEvents()

    $restored = 0
    $failed = 0
    $i = 0
    foreach ($pkg in $valid) {
        $i++
        Send-Json @{ type = 'progress'; value = $i; total = $valid.Count; text = ("Restoring {0} / {1}" -f ($i - 1), $valid.Count) }
        [System.Windows.Forms.Application]::DoEvents()
        $r = Invoke-Adb -AdbArgs @('-s', $script:Device.Serial, 'shell', 'pm', 'install-existing', '--user', '0', $pkg) -AllowFail
        $ok = (($r.Text -match 'installed') -or ($r.ExitCode -eq 0)) -and ($r.Text -notmatch '(?i)error|exception|unknown')
        if ($ok) {
            $restored++
            $script:States[$pkg] = 'enabled'
        }
        else { $failed++ }
        Send-Json @{ type = 'progress'; value = $i; total = $valid.Count; text = ("Restoring {0} / {1}" -f $i, $valid.Count) }
        [System.Windows.Forms.Application]::DoEvents()
    }

    $script:Busy = $false
    Send-Json @{ type = 'done'; kind = 'restore'; applied = $restored; failed = $failed }
    Send-Packages
}

function Invoke-RebootAction {
    if ($script:DemoMode -or -not $script:Connected) { return }
    Invoke-Adb -AdbArgs @('-s', $script:Device.Serial, 'reboot') -AllowFail | Out-Null
    Send-Toast 'Reboot command sent. Reconnect when the phone boots.'
}

# ---------------------------------------------------------------- messages
function Handle-Message {
    param($Msg)
    switch ($Msg.type) {
        'ready' {
            if ($script:DemoMode) { Set-DemoState }
            else { [void](Connect-Device -Silent) }
            Send-Init
            if ($script:StartMaximized -and -not $script:Maximized) { Toggle-Maximize }
            if ($script:Maximized) { Send-Json @{ type = 'windowState'; maximized = $true } }
            if ($script:CapturePath) { Start-CaptureTimer }
        }
        'refresh' {
            if ($script:Busy) { return }
            $script:Busy = $true
            Send-Json @{ type = 'busy'; value = $true; text = 'Reading packages...' }
            [System.Windows.Forms.Application]::DoEvents()
            $ok = Connect-Device -Silent
            $script:Busy = $false
            Send-DeviceInfo
            Send-Packages
            if ($ok) { Send-Json @{ type = 'busy'; value = $false } }
            else { Send-Json @{ type = 'error'; text = 'No phone detected. Enable USB debugging, plug in, and press Refresh.' } }
        }
        'profile' {
            if ($script:Busy -or -not $script:Connected) { return }
            $name = [string]$Msg.profile
            $file = Resolve-ProfileFile $name
            if (-not $file) { Send-Toast 'Profile not found.' 'error'; return }
            Set-ProfileInternal $file
            $script:DeviceWarning = ''
            if (-not (Test-ProfileVendorMatch)) {
                $script:DeviceWarning = ("Profile '{0}' is for a different brand. Pick the right profile." -f $script:ProfileName)
            }
            Send-DeviceInfo
            Send-Packages
            Send-Json @{ type = 'busy'; value = $false }
        }
        'apply' {
            Invoke-ApplyAction -Ids @($Msg.packages)
        }
        'restore' {
            Invoke-RestoreAction -Ids @($Msg.packages)
        }
        'reboot' {
            Invoke-RebootAction
        }
        'minimize' {
            if ($script:Form) { $script:Form.WindowState = 'Minimized' }
        }
        'maximize' {
            Toggle-Maximize
        }
        'close' {
            if ($script:Form) { $script:Form.Close() }
        }
        'drag' {
            if ($script:Form) {
                [void][DebloaterNative]::ReleaseCapture()
                [void][DebloaterNative]::SendMessage($script:Form.Handle, 0xA1, 0x2, 0)
            }
        }
    }
}

# ---------------------------------------------------------------- window
$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'DeBloatZal'
$script:Form.FormBorderStyle = 'None'
$work = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$formWidth = [Math]::Min(1280, [Math]::Max(1040, $work.Width - 48))
$formHeight = [Math]::Min(840, [Math]::Max(700, $work.Height - 48))
$script:Form.Size = New-Object Drawing.Size($formWidth, $formHeight)
$script:Form.MinimumSize = New-Object Drawing.Size([Math]::Min(1040, $formWidth), [Math]::Min(700, $formHeight))
$script:Form.StartPosition = 'CenterScreen'
$script:Form.BackColor = [Drawing.Color]::FromArgb(0, 0, 0)
$script:Form.Padding = New-Object System.Windows.Forms.Padding(0)

$script:Wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
$script:Wv.Dock = 'Fill'
$script:Wv.CreationProperties = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
$script:Wv.CreationProperties.UserDataFolder = Join-Path $env:LOCALAPPDATA 'DeBloatZalWebView2'
$script:Form.Controls.Add($script:Wv)

$script:Wv.add_CoreWebView2InitializationCompleted({
    param($sender, $e)
    if (-not $e.IsSuccess) {
        [void][System.Windows.Forms.MessageBox]::Show(
            ("WebView2 failed to start: {0}`n`nRun scripts\gui-classic.ps1 instead." -f $e.InitializationException),
            'DeBloatZal', 'OK', 'Error')
        $script:Form.Close()
        return
    }

    $core = $sender.CoreWebView2
    try {
        $hdc = [DebloaterNative]::GetDC([IntPtr]::Zero)
        $dpi = [DebloaterNative]::GetDeviceCaps($hdc, 88)
        $zoom = [Math]::Min(1.0, 120.0 / $dpi)
        $sender.ZoomFactor = $zoom
    }
    catch { }
    try { $core.Settings.AreDefaultContextMenusEnabled = $false } catch { }
    try { $core.Settings.IsStatusBarEnabled = $false } catch { }
    try { $core.Settings.IsZoomControlEnabled = $false } catch { }
    try { $sender.DefaultBackgroundColor = [Drawing.Color]::FromArgb(255, 0, 0, 0) } catch { }

    $core.add_WebMessageReceived({
        param($s, $ev)
        try {
            $msg = $ev.WebMessageAsJson | ConvertFrom-Json
            Handle-Message $msg
        }
        catch {
            Send-Json @{ type = 'error'; text = $_.Exception.Message }
        }
    })

    $core.add_NavigationCompleted({
        param($s, $ev)
        if (-not $ev.IsSuccess) {
            [void][System.Windows.Forms.MessageBox]::Show(
                ("UI failed to load: {0}" -f $ev.WebErrorStatus),
                'DeBloatZal', 'OK', 'Error')
            $script:Form.Close()
        }
    })

    $core.Navigate((([Uri]$script:IndexFile).AbsoluteUri + '?t=' + [DateTime]::Now.Ticks))
})

$script:Form.Add_Shown({
    try {
        $pref = 2
        [void][DebloaterNative]::DwmSetWindowAttribute($script:Form.Handle, 33, [ref]$pref, 4)
    }
    catch { }
    if ($script:StartMaximized -and -not $script:Maximized) { Toggle-Maximize }
    $script:Wv.EnsureCoreWebView2Async($null) | Out-Null
})

$script:Form.Add_FormClosed({
    try { if ($script:Wv) { $script:Wv.Dispose() } } catch { }
})

function Start-CaptureTimer {
    $script:CaptureTimer = New-Object System.Windows.Forms.Timer
    $script:CaptureTimer.Interval = 2600
    $script:CaptureTimer.Add_Tick({
        $this.Stop()
        try {
            $script:Form.TopMost = $true
            $script:Form.Activate()
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 400
            $size = New-Object Drawing.Size($script:Form.Width, $script:Form.Height)
            $bmp = New-Object System.Drawing.Bitmap($size.Width, $size.Height)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $hdc = $g.GetHdc()
            $printed = [DebloaterNative]::PrintWindow($script:Form.Handle, $hdc, 2)
            $g.ReleaseHdc($hdc)
            if (-not $printed) {
                $g.CopyFromScreen($script:Form.PointToScreen([Drawing.Point]::Empty), [Drawing.Point]::Empty, $size)
            }
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

[void]$script:Form.ShowDialog()
