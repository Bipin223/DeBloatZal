#Requires -Version 5.1
<#
.SYNOPSIS
    Checks that adb, the USB connection, the phone and the profile are all OK.
    Run this first whenever something does not work.

.EXAMPLE
    .\scripts\doctor.ps1
#>
[CmdletBinding()]
param(
    [string]$Serial
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

Write-Head 'Environment'
Write-Dim ("PowerShell : " + $PSVersionTable.PSVersion.ToString())
Write-Dim ("OS         : " + [Environment]::OSVersion.VersionString)

try {
    $adbPath = Get-AdbPath
    Write-Ok  ("adb        : " + $adbPath)
    $v = Invoke-Adb -AdbArgs @('version') -AllowFail
    Write-Dim ("             " + (($v.Text -split "`n")[0]).Trim())
}
catch {
    Write-Bad $_.Exception.Message
    Write-Dim 'Fix: run .\setup.ps1 (or .\Start.cmd and choose 1).'
    return
}

Write-Head 'USB devices'
$devices = @(Get-AdbDevices)
if ($devices.Count -eq 0) {
    Write-Bad 'adb sees no device.'
    Write-Host ''
    Write-Dim '  Checklist:'
    Write-Dim '    - Developer options + USB debugging are ON (see README.md).'
    Write-Dim '    - The cable carries data (not charge-only). Try another cable/port.'
    Write-Dim '    - USB mode on the phone: File transfer (MTP), not "Charging only".'
    Write-Dim '    - Unlock the phone; accept the "Allow USB debugging" prompt.'
    Write-Dim '    - Windows: Device Manager -> look for a yellow warning triangle.'
    Write-Dim '        Samsung F22  -> install https://developer.samsung.com/android-usb-driver'
    Write-Dim '        Redmi phones -> Windows Update usually finds the ADB interface.'
    Write-Dim '    - Last resort: adb kill-server ; adb start-server ; replug.'
}
else {
    foreach ($d in $devices) {
        $stateColor = 'Green'
        if ($d.State -ne 'device') { $stateColor = 'Yellow' }
        Write-Host ("  {0,-22} {1,-14} {2}" -f $d.Serial, $d.State, $d.Model) -ForegroundColor $stateColor
    }
    if (@($devices | Where-Object { $_.State -eq 'unauthorized' }).Count -gt 0) {
        Write-Warn2 'Phone is unauthorized: unlock it and tap "Allow" (tick "Always allow").'
        Write-Dim  'Still stuck? Developer options -> Revoke USB debugging authorizations, then replug.'
    }
    if (@($devices | Where-Object { $_.State -eq 'offline' }).Count -gt 0) {
        Write-Warn2 'Phone is offline: replug the cable or run "adb kill-server".'
    }
}

$ready = @($devices | Where-Object { $_.State -eq 'device' })
if ($ready.Count -eq 0) {
    Write-Host ''
    Write-Dim '  No authorized phone to inspect yet.'
    return
}
if ($ready.Count -gt 1 -and -not $Serial) {
    Write-Warn2 'Multiple phones connected; using the first one. Use -Serial to pick another.'
}

$target = $ready[0]
if ($Serial) {
    $match = $ready | Where-Object { $_.Serial -eq $Serial } | Select-Object -First 1
    if ($match) { $target = $match }
}

Write-Head 'Phone'
try {
    $info = Get-DeviceInfo -Serial $target.Serial
    Write-Ok  ("Model      : {0} {1}" -f $info.Manufacturer, $info.Model)
    Write-Dim ("Codename   : " + $info.Device)
    Write-Dim ("Android    : {0} (SDK {1})" -f $info.Android, $info.Sdk)
    Write-Dim ("Build      : " + $info.Build)
    Write-Dim ("OS skin    : " + $info.OsName)
    if ($info.SecurityPatch) { Write-Dim ("Security   : " + $info.SecurityPatch) }
}
catch {
    Write-Bad $_.Exception.Message
    return
}

Write-Head 'Packages'
try {
    $states = Get-PackageStates -Serial $target.Serial
    if ($states.Count -eq 0) {
        Write-Bad 'adb could not read pm list packages.'
    }
    else {
        $enabled = @($states.Keys | Where-Object { $states[$_] -eq 'enabled' }).Count
        $disabled = @($states.Keys | Where-Object { $states[$_] -eq 'disabled' }).Count
        $gone = @($states.Keys | Where-Object { $states[$_] -eq 'uninstalled' }).Count
        Write-Ok ("{0} packages: {1} enabled, {2} disabled, {3} uninstalled for user 0" -f $states.Count, $enabled, $disabled, $gone)
    }
}
catch {
    Write-Bad $_.Exception.Message
}

Write-Head 'Profile match'
$profileFile = Find-ProfileForDevice $info
if ($profileFile) {
    Write-Ok ("Using " + (Split-Path -Leaf $profileFile))
}
else {
    Write-Warn2 'No profile matches this phone.'
    Write-Dim  'Available:'
    Get-ChildItem -LiteralPath $script:ProfileDir -Filter '*.profile' |
        ForEach-Object { Write-Dim ('  ' + $_.BaseName) }
    Write-Dim  'You can still run: debloat.ps1 -Profile <name> -DryRun'
}

Write-Host ''
Write-Dim 'Next: .\Start.cmd -> option 4 (debloat), or run debloat.ps1 -DryRun first.'
Write-Host ''
