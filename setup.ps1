#Requires -Version 5.1
<#
    Grabs Android platform-tools (adb + fastboot) into .\tools and checks the basics.
    Safe to re-run. Pass -Force to re-download.
#>
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root       = $PSScriptRoot
$toolsDir   = Join-Path $root 'tools'
$ptDir      = Join-Path $toolsDir 'platform-tools'
$adb        = Join-Path $ptDir 'adb.exe'
$zip        = Join-Path $toolsDir 'platform-tools.zip'
$downloadUrl = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'

Write-Host ''
Write-Host '  DeBloatZal - setup' -ForegroundColor Cyan
Write-Host '  -------------------------' -ForegroundColor DarkGray
Write-Host ''

if (-not (Test-Path -LiteralPath $toolsDir)) {
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
}

# ---------------------------------------------------------------- platform-tools
if ((Test-Path -LiteralPath $adb) -and -not $Force) {
    Write-Host '  [ok]   platform-tools already installed' -ForegroundColor Green
}
else {
    Write-Host '  Downloading Android platform-tools from Google...' -ForegroundColor Yellow
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch { }
    try {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zip -UseBasicParsing
        Write-Host '  Extracting...' -ForegroundColor Yellow
        if (Test-Path -LiteralPath $ptDir) { Remove-Item -LiteralPath $ptDir -Recurse -Force }
        Expand-Archive -LiteralPath $zip -DestinationPath $toolsDir -Force
        Remove-Item -LiteralPath $zip -Force
        if (-not (Test-Path -LiteralPath $adb)) { throw 'adb.exe missing after extraction.' }
        Write-Host '  [ok]   platform-tools installed' -ForegroundColor Green
    }
    catch {
        Write-Host ''
        Write-Host '  [fail] Could not download platform-tools.' -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)" -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  Manual fallback:' -ForegroundColor Yellow
        Write-Host '    1. Download platform-tools-latest-windows.zip from:'
        Write-Host '       https://developer.android.com/tools/releases/platform-tools'
        Write-Host "    2. Extract it so you get: $ptDir\adb.exe"
        Write-Host '    3. Re-run this script.'
        Write-Host ''
        return
    }
}

# ---------------------------------------------------------------- sanity check
Write-Host ''
try {
    $version = (& $adb version 2>&1 | Out-String).Trim()
    ((($version -split "`n")[0]).Trim()) | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    Write-Host "  [ok]   $adb" -ForegroundColor Green
}
catch {
    Write-Host '  [fail] adb.exe is present but will not run.' -ForegroundColor Red
    Write-Host '         Antivirus or SmartScreen may be blocking it.' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- drivers
Write-Host ''
Write-Host '  USB drivers' -ForegroundColor Cyan
Write-Host '  Windows 10/11 normally installs the Android ADB interface automatically.' -ForegroundColor Gray
Write-Host '  If a phone is not detected, install the vendor driver:' -ForegroundColor Gray
Write-Host '    Samsung (needed most often for Galaxy F22):' -ForegroundColor White
Write-Host '      https://developer.samsung.com/android-usb-driver' -ForegroundColor DarkCyan
Write-Host '    Google USB driver (generic fallback / manual INF install):' -ForegroundColor White
Write-Host '      https://developer.android.com/studio/run/win-usb' -ForegroundColor DarkCyan
Write-Host '  Note: MediaTek VCOM drivers are only for flashing tools (SP Flash Tool),' -ForegroundColor DarkGray
Write-Host '        not for adb. Redmi 9C / Note 8 do not need them for debloating.' -ForegroundColor DarkGray

# ---------------------------------------------------------------- next steps
Write-Host ''
Write-Host '  Next:' -ForegroundColor Cyan
Write-Host '    1. On the phone: enable Developer options + USB debugging (README.md).'
Write-Host '    2. Plug in USB, unlock the phone, tap "Allow" on the debugging prompt.'
Write-Host '    3. Run:  .\Start.cmd'
Write-Host '       or:   powershell -ExecutionPolicy Bypass -File .\scripts\doctor.ps1'
Write-Host ''
