#Requires -Version 5.1
<#
.SYNOPSIS
    Lists installed packages with their state and saves a full snapshot to .\logs.

.EXAMPLE
    .\scripts\list-packages.ps1
    .\scripts\list-packages.ps1 -Match 'samsung|bixby'
    .\scripts\list-packages.ps1 -IncludeUninstalled -Match 'facebook'
#>
[CmdletBinding()]
param(
    [string]$Serial,
    [string]$Match,
    [switch]$IncludeUninstalled,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

Write-Head 'Installed packages'
try {
    $dev = Select-AndroidDevice -Serial $Serial
}
catch {
    Write-Bad $_.Exception.Message
    return
}

$info = Get-DeviceInfo -Serial $dev.Serial
Write-Ok ("{0} {1} ({2})" -f $info.Manufacturer, $info.Model, $info.Device)

$states = Get-PackageStates -Serial $dev.Serial
$rows = New-Object 'System.Collections.Generic.List[object]'
foreach ($pkg in ($states.Keys | Sort-Object)) {
    $state = $states[$pkg]
    if (-not $IncludeUninstalled -and $state -eq 'uninstalled') { continue }
    if ($Match -and $pkg -notmatch $Match) { continue }
    $rows.Add([pscustomobject]@{ State = $state; Package = $pkg })
}

if (-not (Test-Path -LiteralPath $script:LogDir)) {
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
}
$slug = Get-DeviceSlug $info
$file = Join-Path $script:LogDir ("{0}-{1}-packages.tsv" -f $slug, (Get-Stamp))
$lines = New-Object 'System.Collections.Generic.List[string]'
$lines.Add('# package<TAB>state')
foreach ($r in $rows) { $lines.Add(("{0}`t{1}" -f $r.Package, $r.State)) }
Set-Content -LiteralPath $file -Value $lines -Encoding UTF8

Write-Dim ("{0} package(s) listed" -f $rows.Count)
Write-Dim ("saved: " + $file)
Write-Host ''

if (-not $Quiet) {
    Write-Host ("  {0,-13} {1}" -f 'STATE', 'PACKAGE') -ForegroundColor DarkGray
    foreach ($r in $rows) {
        $color = 'Gray'
        if ($r.State -eq 'disabled') { $color = 'Yellow' }
        if ($r.State -eq 'uninstalled') { $color = 'DarkGray' }
        Write-Host ("  {0,-13} {1}" -f $r.State, $r.Package) -ForegroundColor $color
    }
    Write-Host ''
    Write-Dim 'Tip: search with -Match, e.g.  .\scripts\list-packages.ps1 -Match "xiaomi|miui"'
}
