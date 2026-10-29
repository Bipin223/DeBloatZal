#Requires -Version 5.1
<#
.SYNOPSIS
    Debloats a supported Android phone over USB with adb. No root, no bootloader unlock.

.DESCRIPTION
    Reads a profile from .\profiles, compares it with the packages actually installed
    on the phone, then disables or uninstalls the selected tier for user 0.
    Every run writes a package snapshot and an undo log to .\logs.

.EXAMPLE
    .\scripts\debloat.ps1
    Interactive: auto-detects the phone and asks for tier + mode.

.EXAMPLE
    .\scripts\debloat.ps1 -Profile redmi-9c -Tier core -Mode uninstall -Yes
    Non-interactive.

.EXAMPLE
    .\scripts\debloat.ps1 -Profile samsung-f22 -Tier all -DryRun
    Show exactly what would happen, change nothing.
#>
[CmdletBinding()]
param(
    [string]$Profile,
    [ValidateSet('core', 'optional', 'all')][string]$Tier,
    [ValidateSet('disable', 'uninstall')][string]$Mode,
    [string]$Serial,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# ------------------------------------------------------------------ list only
if ($List) {
    $file = Resolve-ProfileFile $Profile
    if (-not $file) {
        Write-Head 'Available profiles'
        Get-ChildItem -LiteralPath $script:ProfileDir -Filter '*.profile' |
            ForEach-Object { Write-Dim ('  ' + $_.BaseName) }
        Write-Host ''
        Write-Dim '  Use:  .\scripts\debloat.ps1 -List -Profile redmi-9c'
        return
    }
    $s = Read-ProfileFile $file
    Write-Head ("Profile: " + (Split-Path -Leaf $file))
    foreach ($section in @('core', 'optional', 'protect')) {
        $pkgs = @()
        if ($s.ContainsKey($section)) { $pkgs = @($s[$section]) }
        $label = $section
        if ($section -eq 'core')     { $label = 'core (safe bloat)' }
        if ($section -eq 'optional') { $label = 'optional (you may want to keep some)' }
        if ($section -eq 'protect')  { $label = 'protected (never touched)' }
        Write-Host ''
        Write-Host ("  [$label] {0} package(s)" -f $pkgs.Count) -ForegroundColor Yellow
        foreach ($p in $pkgs) { Write-Dim ('    ' + $p) }
    }
    Write-Host ''
    return
}

# ------------------------------------------------------------------ device
Write-Head 'DeBloatZal'
try {
    $dev = Select-AndroidDevice -Serial $Serial
}
catch {
    Write-Bad $_.Exception.Message
    Write-Dim 'Run .\scripts\doctor.ps1 for a full connection check.'
    return
}

$info = Get-DeviceInfo -Serial $dev.Serial
Write-Ok ("Connected: {0}  (adb serial {1})" -f $info.Model, $info.Serial)
Write-Dim ("{0} {1} / codename {2} / Android {3} / {4}" -f $info.Manufacturer, $info.Model, $info.Device, $info.Android, $info.OsName)

# ------------------------------------------------------------------ profile
$profileFile = $null
if ($Profile) {
    $profileFile = Resolve-ProfileFile $Profile
    if (-not $profileFile) {
        Write-Bad "Profile '$Profile' not found in .\profiles"
        return
    }
}
else {
    $profileFile = Find-ProfileForDevice $info
}

if (-not $profileFile) {
    Write-Warn ("No profile matched this phone ({0} / {1})." -f $info.Device, $info.Model)
    Write-Dim  'Available profiles:'
    Get-ChildItem -LiteralPath $script:ProfileDir -Filter '*.profile' |
        ForEach-Object { Write-Dim ('  ' + $_.BaseName) }
    Write-Dim  'Add a [match] pattern to a profile or pass -Profile <name>.'
    return
}

$sections    = Read-ProfileFile $profileFile
$profileName = [IO.Path]::GetFileNameWithoutExtension($profileFile)
Write-Ok ("Profile: {0}" -f $profileName)

if ($sections.ContainsKey('note')) {
    foreach ($n in $sections['note']) { Write-Dim ('  note: ' + $n) }
}

# ------------------------------------------------------------------ tier
if (-not $PSBoundParameters.ContainsKey('Tier') -and -not $Yes -and -not $DryRun) {
    Write-Host ''
    Write-Host '  What should be removed?' -ForegroundColor Cyan
    Write-Host '    1  core      ads, telemetry, Facebook/Netflix/Spotify/Amazon preloads   (recommended)'
    Write-Host '    2  all       core + optional apps (YouTube, Maps, Gallery, browser, ...)'
    $choice = ([string](Read-Host '  Choose [1]')).Trim()
    if ($choice -eq '2') { $Tier = 'all' } else { $Tier = 'core' }
}
elseif ($Tier -eq 'optional') {
    $Tier = 'all'
}
if (-not $Tier) { $Tier = 'core' }

# ------------------------------------------------------------------ mode
if (-not $PSBoundParameters.ContainsKey('Mode') -and -not $Yes -and -not $DryRun) {
    Write-Host ''
    Write-Host '  How should packages be handled?' -ForegroundColor Cyan
    Write-Host '    1  uninstall  removes it for user 0, icon disappears, undo: pm install-existing  (recommended)'
    Write-Host '    2  disable    keeps the APK on the phone, undo: pm enable'
    $choice = ([string](Read-Host '  Choose [1]')).Trim()
    if ($choice -eq '2') { $Mode = 'disable' } else { $Mode = 'uninstall' }
}
if (-not $Mode) { $Mode = 'uninstall' }
Write-Dim ("  mode: {0} / tier: {1}" -f $Mode, $Tier)

# ------------------------------------------------------------------ installed state
Write-Host ''
Write-Host '  Reading package list from the phone...' -ForegroundColor Yellow
$states = Get-PackageStates -Serial $dev.Serial
if ($states.Count -eq 0) {
    Write-Bad 'Could not read the package list. Is the phone unlocked and still authorized?'
    return
}
$enabledCount = @($states.Keys | Where-Object { $states[$_] -eq 'enabled' }).Count
Write-Ok ("{0} packages known, {1} enabled" -f $states.Count, $enabledCount)

# ------------------------------------------------------------------ plan
$protect = New-ProtectedSet $sections
$picked  = Get-TierList -Sections $sections -Tier $Tier
$tiers   = 'core'
if ($Tier -eq 'all') { $tiers = 'core + optional' }

$plan    = New-Object 'System.Collections.Generic.List[object]'
$skipped = @{ 'already gone' = 0; 'protected' = 0; 'not installed' = 0; 'already disabled' = 0 }

foreach ($pkg in $picked) {
    $pkg = $pkg.Trim()
    if (-not $pkg) { continue }

    if (Test-CriticalPackage -Package $pkg -ExtraProtect $protect) {
        $skipped['protected']++
        Write-Dim ("  protected, skipped: {0}" -f $pkg)
        continue
    }

    if (-not $states.ContainsKey($pkg)) {
        $skipped['not installed']++
        continue
    }

    $state = $states[$pkg]
    if ($state -eq 'uninstalled') {
        $skipped['already gone']++
        continue
    }
    if ($state -eq 'disabled' -and $Mode -eq 'disable') {
        $skipped['already disabled']++
        continue
    }

    $plan.Add([pscustomobject]@{ Package = $pkg; State = $state; Action = $Mode })
}

Write-Host ''
Write-Host ("  Tier {0}: {1} change(s)" -f $tiers, $plan.Count) -ForegroundColor Cyan
if ($plan.Count -gt 0) {
    Write-Host ("  {0,-11} {1,-12} {2}" -f 'ACTION', 'STATE', 'PACKAGE') -ForegroundColor DarkGray
    foreach ($item in $plan) {
        $color = 'Yellow'
        if ($item.Action -eq 'uninstall') { $color = 'Red' }
        Write-Host ("  {0,-11} {1,-12} {2}" -f $item.Action, $item.State, $item.Package) -ForegroundColor $color
    }
}
$skipLine = ($skipped.Keys | Sort-Object | ForEach-Object { "$_=$($skipped[$_])" }) -join ', '
Write-Dim ("  skipped: " + $skipLine)

if ($plan.Count -eq 0) {
    Write-Ok 'Nothing to do.'
    return
}

if ($DryRun) {
    Write-Host ''
    Write-Ok 'Dry run: nothing was changed.'
    return
}

# ------------------------------------------------------------------ confirm
if (-not $Yes) {
    Write-Host ''
    Write-Host '  Safety: every change is logged and reversible. If the phone misbehaves,' -ForegroundColor DarkGray
    Write-Host '  run restore.ps1 with the log printed at the end.' -ForegroundColor DarkGray
    $answer = ([string](Read-Host ("  Apply {0} change(s) to {1}? [y/N]" -f $plan.Count, $info.Model))).Trim()
    if ($answer -notmatch '^(?i)y(es)?$') {
        Write-Dim '  Aborted. Nothing was changed.'
        return
    }
}

# ------------------------------------------------------------------ snapshot + log
$slug = Get-DeviceSlug $info
$snap = Save-PackageSnapshot -Serial $dev.Serial -Slug $slug -States $states
Write-Ok ("Package snapshot: {0}" -f $snap)

$changeFile = Join-Path $script:LogDir ("{0}-{1}-changes.tsv" -f $slug, (Get-Stamp))
$header = @(
    '# android-debloater change log v1'
    ("# date={0} serial={1} model={2} profile={3} mode={4}" -f (Get-Date).ToString('s'), $dev.Serial, $info.Model, $profileName, $Mode)
    '# package<TAB>action<TAB>prior-state'
)
Set-Content -LiteralPath $changeFile -Value $header -Encoding UTF8

# ------------------------------------------------------------------ apply
Write-Host ''
Write-Host '  Applying...' -ForegroundColor Yellow
$applied = 0
$failed  = 0

foreach ($item in $plan) {
    $pkg = $item.Package
    $ok  = $false
    $resultText = ''

    try {
        if ($Mode -eq 'disable') {
            $r = Invoke-Adb -AdbArgs @('-s', $dev.Serial, 'shell', 'pm', 'disable-user', '--user', '0', $pkg) -AllowFail
            $resultText = $r.Text
            if ($resultText -match 'new state:\s*disabled') { $ok = $true }
        }
        else {
            $r = Invoke-Adb -AdbArgs @('-s', $dev.Serial, 'shell', 'pm', 'uninstall', '-k', '--user', '0', $pkg) -AllowFail
            $resultText = $r.Text
            if ($resultText -notmatch 'Success') {
                # Some MIUI builds reject -k; retry without it.
                $r = Invoke-Adb -AdbArgs @('-s', $dev.Serial, 'shell', 'pm', 'uninstall', '--user', '0', $pkg) -AllowFail
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
        Add-Content -LiteralPath $changeFile -Value ("{0}`t{1}`t{2}" -f $pkg, $Mode, $item.State) -Encoding UTF8
        Write-Ok $pkg
    }
    else {
        $failed++
        Write-Bad ("{0} -> {1}" -f $pkg, ($resultText -replace '\s+', ' '))
    }
}

# ------------------------------------------------------------------ summary
Write-Head 'Summary'
Write-Host ("  applied : {0}" -f $applied) -ForegroundColor Green
Write-Host ("  failed  : {0}" -f $failed) -ForegroundColor $(if ($failed -gt 0) { 'Yellow' } else { 'DarkGray' })

$ping = Invoke-Adb -AdbArgs @('-s', $dev.Serial, 'shell', 'echo', 'ok') -AllowFail
if ($ping.Text -match 'ok') {
    Write-Ok 'Phone still responds to adb.'
}
else {
    Write-Warn2 'Phone did not answer adb. Reboot it; if the launcher is missing, run the restore command below.'
}

if ($applied -gt 0) {
    Write-Host ''
    Write-Host '  Undo everything from this run:' -ForegroundColor Cyan
    $restorePath = Join-Path $script:RootDir 'scripts\restore.ps1'
    Write-Host ("    powershell -ExecutionPolicy Bypass -File `"{0}`" -Changes `"{1}`"" -f $restorePath, $changeFile) -ForegroundColor White
    Write-Host ''
    Write-Dim '  Reboot the phone once, then use it for a day before deleting anything else.'
    Write-Dim '  A MIUI/One UI update can bring some preinstalled apps back.'
}
