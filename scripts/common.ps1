# Shared helpers for the Android debloater.
# Dot-source from a script in .\scripts :  . (Join-Path $PSScriptRoot 'common.ps1')

$script:RootDir       = Split-Path -Parent $PSScriptRoot
$script:PlatformTools = Join-Path $script:RootDir 'tools\platform-tools'
$script:LogDir        = Join-Path $script:RootDir 'logs'
$script:ProfileDir    = Join-Path $script:RootDir 'profiles'

# Packages that must never be disabled/removed by this tool.
# Anything matching these patterns is skipped even if it appears in a profile.
$script:CriticalPatterns = @(
    '^com\.android\.systemui$'
    '^com\.android\.settings$'
    '^com\.android\.packageinstaller$'
    '^com\.google\.android\.packageinstaller$'
    '^com\.android\.permissioncontroller$'
    '^com\.google\.android\.permissioncontroller$'
    '^com\.android\.providers\.'
    '^com\.android\.phone$'
    '^com\.android\.server\.telecom$'
    '^com\.android\.bluetooth'
    '^com\.android\.shell$'
    '^com\.android\.vending$'
    '^com\.android\.webview$'
    '^com\.google\.android\.webview$'
    '^android$'
    '^android\.'
    '^com\.google\.android\.gms$'
    '^com\.google\.android\.gsf$'
    '^com\.google\.android\.inputmethod'
    '^com\.android\.inputmethod'
    '^com\.miui\.home$'
    '^com\.miui\.securitycenter$'
    '^com\.miui\.packageinstaller$'
    '^com\.miui\.powerkeeper$'
    '^com\.lbe\.security\.miui$'
    '^com\.sec\.android\.app\.launcher$'
    '^com\.samsung\.android\.honeyboard$'
    '^com\.samsung\.android\.dialer$'
    '^com\.samsung\.android\.incallui$'
    '^com\.samsung\.android\.app\.telephonyui$'
    '^com\.samsung\.android\.MtpApplication$'
    '^com\.sec\.android\.app\.camera$'
    '^com\.sec\.android\.app\.clockpackage$'
    '^com\.samsung\.android\.app\.contacts$'
    '(?i)launcher'
)

function Write-Head {
    param([Parameter(Mandatory = $true)][string]$Text)
    Write-Host ''
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * $Text.Length)) -ForegroundColor DarkGray
}

function Write-Ok   { param([string]$Text) Write-Host "  [ok]   $Text" -ForegroundColor Green }
function Write-Warn2 { param([string]$Text) Write-Host "  [warn] $Text" -ForegroundColor Yellow }
function Write-Bad  { param([string]$Text) Write-Host "  [fail] $Text" -ForegroundColor Red }
function Write-Dim  { param([string]$Text) Write-Host "  $Text" -ForegroundColor DarkGray }

function Get-Stamp { (Get-Date).ToString('yyyyMMdd-HHmmss') }

function Get-AdbPath {
    if ($env:ADB_PATH -and (Test-Path -LiteralPath $env:ADB_PATH)) { return $env:ADB_PATH }
    $local = Join-Path $script:PlatformTools 'adb.exe'
    if (Test-Path -LiteralPath $local) { return $local }
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'adb was not found. Run .\setup.ps1 first (it downloads Android platform-tools).'
}

function Invoke-Adb {
    param(
        [Parameter(Mandatory = $true)][string[]]$AdbArgs,
        [switch]$AllowFail
    )
    $adb = Get-AdbPath
    # Native stderr output (adb daemon messages) becomes a terminating error
    # under ErrorActionPreference=Stop in Windows PowerShell 5.1, so relax it
    # while the process runs and restore it afterwards.
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $adb @AdbArgs 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldEap
    }
    $text = (($output | ForEach-Object { "$_" }) -join "`n").Trim()
    if ($code -ne 0 -and -not $AllowFail) {
        throw ("adb {0} failed (exit {1}): {2}" -f ($AdbArgs -join ' '), $code, $text)
    }
    [pscustomobject]@{ Text = $text; ExitCode = $code }
}

function Get-AdbDevices {
    $r = Invoke-Adb -AdbArgs @('devices', '-l') -AllowFail
    $rows = @()
    foreach ($line in ($r.Text -split "`n")) {
        $line = $line.Trim()
        if (-not $line) { continue }
        if ($line -like 'List of devices*') { continue }
        if ($line.StartsWith('*')) { continue }
        $parts = @($line -split '\s+')
        if ($parts.Count -lt 2) { continue }
        $validStates = @('device', 'offline', 'unauthorized', 'recovery', 'sideload', 'bootloader', 'host', 'rescue')
        if ($validStates -notcontains $parts[1]) { continue }
        $extra = @{}
        foreach ($p in ($parts | Select-Object -Skip 2)) {
            if ($p -match '^([^:]+):(.+)$') { $extra[$matches[1]] = $matches[2] }
        }
        $rows += [pscustomobject]@{
            Serial    = $parts[0]
            State     = $parts[1]
            Model     = $extra['model']
            Device    = $extra['device']
            Product   = $extra['product']
            Transport = $extra['transport_id']
        }
    }
    return $rows
}

function Select-AndroidDevice {
    param([string]$Serial)
    $devices = @(Get-AdbDevices)
    if ($devices.Count -eq 0) {
        throw 'No device detected. Connect the phone with a data-capable USB cable, unlock it, and enable USB debugging.'
    }
    if ($Serial) {
        $dev = $devices | Where-Object { $_.Serial -eq $Serial } | Select-Object -First 1
        if (-not $dev) {
            throw ("Device '{0}' not found. Connected: {1}" -f $Serial, (($devices | ForEach-Object { $_.Serial }) -join ', '))
        }
    }
    else {
        $ready = @($devices | Where-Object { $_.State -eq 'device' })
        if ($ready.Count -eq 0) {
            $states = ($devices | ForEach-Object { "$($_.Serial)=$($_.State)" }) -join ', '
            throw ("No authorized device. adb sees: {0}. Unlock the phone and accept the 'Allow USB debugging' prompt (tick 'Always allow')." -f $states)
        }
        if ($ready.Count -gt 1) {
            throw ("Multiple devices connected: {0}. Re-run with -Serial <serial>." -f (($ready | ForEach-Object { $_.Serial }) -join ', '))
        }
        $dev = $ready[0]
    }
    if ($dev.State -ne 'device') {
        throw ("Device {0} is in state '{1}'. Accept the authorization prompt or reconnect the cable." -f $dev.Serial, $dev.State)
    }
    return $dev
}

function Get-DeviceInfo {
    param([Parameter(Mandatory = $true)][string]$Serial)
    $r = Invoke-Adb -AdbArgs @('-s', $Serial, 'shell', 'getprop') -AllowFail
    $p = @{}
    foreach ($line in ($r.Text -split "`n")) {
        if ($line -match '^\s*\[([^\]]+)\]\s*:\s*\[(.*)\]\s*$') {
            $p[$matches[1]] = $matches[2]
        }
    }
    $osName = 'Android'
    if ($p['ro.miui.ui.version.name']) { $osName = 'MIUI ' + $p['ro.miui.ui.version.name'] }
    elseif ($p['ro.build.version.oneui']) {
        $one = [string]$p['ro.build.version.oneui']
        if ($one -match '^(\d)(\d\d)(\d\d)$') {
            $osName = ("One UI {0}.{1}" -f $matches[1], [int]$matches[2])
        }
        else { $osName = 'One UI ' + $one }
    }
    elseif ($p['ro.build.version.sem']) { $osName = 'One UI ' + $p['ro.build.version.sem'] }
    [pscustomobject]@{
        Serial        = $Serial
        Manufacturer  = $p['ro.product.manufacturer']
        Brand         = $p['ro.product.brand']
        Model         = $p['ro.product.model']
        Device        = $p['ro.product.device']
        Android       = $p['ro.build.version.release']
        Sdk           = $p['ro.build.version.sdk']
        Build         = $p['ro.build.display.id']
        OsName        = $osName
        SecurityPatch = $p['ro.build.version.security_patch']
        Props         = $p
    }
}

function Get-PackageStates {
    param([Parameter(Mandatory = $true)][string]$Serial)

    function Get-PackageSet {
        param([string[]]$Extra)
        $adbArgs = @('-s', $Serial, 'shell', 'pm', 'list', 'packages') + $Extra
        $r = Invoke-Adb -AdbArgs $adbArgs -AllowFail
        $set = @{}
        if ($r.ExitCode -ne 0) { return $set }
        foreach ($line in ($r.Text -split "`n")) {
            if ($line -match '^package:(.+?)\s*$') { $set[$matches[1]] = $true }
        }
        return $set
    }

    $enabled  = Get-PackageSet @('-e')
    $disabled = Get-PackageSet @('-d')
    $all      = Get-PackageSet @('-u')

    $result = @{}
    foreach ($k in $all.Keys) {
        if ($enabled.ContainsKey($k))      { $result[$k] = 'enabled' }
        elseif ($disabled.ContainsKey($k)) { $result[$k] = 'disabled' }
        else                               { $result[$k] = 'uninstalled' }
    }
    return $result
}

function Resolve-ProfileFile {
    param([string]$Name)
    if (-not $Name) { return $null }
    if (Test-Path -LiteralPath $Name) { return (Resolve-Path -LiteralPath $Name).Path }
    $candidates = @(
        (Join-Path $script:ProfileDir $Name)
        (Join-Path $script:ProfileDir ($Name + '.profile'))
        (Join-Path $script:ProfileDir ($Name + '.txt'))
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

function Read-ProfileFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sections = @{}
    $current = 'meta'
    $sections[$current] = New-Object 'System.Collections.Generic.List[string]'
    foreach ($raw in (Get-Content -LiteralPath $Path)) {
        $line = $raw.Trim()
        if ($line.Length -eq 0) { continue }
        if ($line -match '^\[([^\]]+)\]$') {
            $current = $matches[1].Trim().ToLowerInvariant()
            if (-not $sections.ContainsKey($current)) {
                $sections[$current] = New-Object 'System.Collections.Generic.List[string]'
            }
            continue
        }
        if ($line.StartsWith('#')) { continue }
        $sections[$current].Add($line)
    }
    return $sections
}

function Find-ProfileForDevice {
    param([Parameter(Mandatory = $true)]$Device)
    $files = @(Get-ChildItem -LiteralPath $script:ProfileDir -Filter '*.profile' -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($f in $files) {
        $s = Read-ProfileFile $f.FullName
        if (-not $s.ContainsKey('match')) { continue }
        foreach ($pat in $s['match']) {
            if ($Device.Device -and ($Device.Device -match $pat)) { return $f.FullName }
            if ($Device.Model  -and ($Device.Model  -match $pat)) { return $f.FullName }
        }
    }
    return $null
}

function Test-CriticalPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Package,
        [hashtable]$ExtraProtect
    )
    if ($ExtraProtect -and $ExtraProtect.ContainsKey($Package)) { return $true }
    foreach ($pat in $script:CriticalPatterns) {
        if ($Package -match $pat) { return $true }
    }
    return $false
}

function Test-ProfileVendorMatch {
    if (-not $script:DeviceInfo -or -not $script:ProfileName) { return $true }
    $maker = [string]$script:DeviceInfo.Manufacturer
    $name = [string]$script:ProfileName
    if ($name -match 'samsung' -and $maker -notmatch 'samsung') { return $false }
    if ($name -match 'redmi|xiaomi' -and $maker -notmatch 'xiaomi|redmi') { return $false }
    return $true
}

function New-ProtectedSet {
    param([hashtable]$Sections)
    $set = @{}
    if ($Sections -and $Sections.ContainsKey('protect')) {
        foreach ($p in $Sections['protect']) { $set[$p] = $true }
    }
    return $set
}

function Get-TierList {
    param(
        [hashtable]$Sections,
        [string]$Tier
    )
    $names = @('core')
    if ($Tier -eq 'optional' -or $Tier -eq 'all') { $names += 'optional' }
    $picked = New-Object 'System.Collections.Generic.List[string]'
    foreach ($n in $names) {
        if (-not $Sections.ContainsKey($n)) { continue }
        foreach ($pkg in $Sections[$n]) {
            if (-not $picked.Contains($pkg)) { $picked.Add($pkg) }
        }
    }
    return $picked
}

function Save-PackageSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Serial,
        [Parameter(Mandatory = $true)][string]$Slug,
        [Parameter(Mandatory = $true)][hashtable]$States
    )
    if (-not (Test-Path -LiteralPath $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }
    $file = Join-Path $script:LogDir ("{0}-{1}-packages.tsv" -f $Slug, (Get-Stamp))
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('# Android package snapshot (state is per user 0)')
    $lines.Add(("# serial={0} date={1}" -f $Serial, (Get-Date).ToString('s')))
    $lines.Add('# package<TAB>state')
    foreach ($k in ($States.Keys | Sort-Object)) {
        $lines.Add(("{0}`t{1}" -f $k, $States[$k]))
    }
    Set-Content -LiteralPath $file -Value $lines -Encoding UTF8
    return $file
}

function Get-DeviceSlug {
    param($DeviceInfo)
    $raw = "$($DeviceInfo.Manufacturer)-$($DeviceInfo.Model)"
    $slug = ($raw -replace '[^A-Za-z0-9\._-]', '_')
    return $slug.Trim('_')
}

function Read-ChangeLog {
    param([Parameter(Mandatory = $true)][string]$Path)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $meta = @{}
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        if (-not $line) { continue }
        if ($line.StartsWith('#')) {
            if ($line -match 'date=([^\s]+)')    { $meta['Date'] = $matches[1] }
            if ($line -match 'serial=([^\s]+)')  { $meta['Serial'] = $matches[1] }
            if ($line -match 'model=([^\s]+)')   { $meta['Model'] = $matches[1] }
            if ($line -match 'profile=([^\s]+)') { $meta['Profile'] = $matches[1] }
            if ($line -match 'mode=([^\s]+)')    { $meta['Mode'] = $matches[1] }
            continue
        }
        $parts = $line -split "`t"
        if ($parts.Count -ge 3) {
            $rows.Add([pscustomobject]@{
                Package    = $parts[0].Trim()
                Action     = $parts[1].Trim()
                PriorState = $parts[2].Trim()
            })
        }
    }
    [pscustomobject]@{ Meta = $meta; Rows = $rows }
}

function Get-ChangeLogFiles {
    if (-not (Test-Path -LiteralPath $script:LogDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $script:LogDir -Filter '*-changes.tsv' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
}
