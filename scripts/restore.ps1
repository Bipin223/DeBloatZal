#Requires -Version 5.1
<#
.SYNOPSIS
    Undoes changes made by debloat.ps1 (re-enables disabled packages and
    reinstalls packages that were uninstalled for user 0).

.EXAMPLE
    .\scripts\restore.ps1
    Pick the newest change log interactively.

.EXAMPLE
    .\scripts\restore.ps1 -Changes .\logs\Redmi_M2006C3MG-20260101-120000-changes.tsv

.EXAMPLE
    .\scripts\restore.ps1 -All
    Restore every package ever changed by this tool (newest log wins per package).
#>
[CmdletBinding()]
param(
    [string]$Changes,
    [string]$Serial,
    [switch]$All,
    [switch]$DryRun,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

Write-Head 'Restore'

if (-not (Test-Path -LiteralPath $script:LogDir)) {
    Write-Bad 'No logs folder yet - nothing has been changed by this tool.'
    return
}

$files = @(Get-ChildItem -LiteralPath $script:LogDir -Filter '*-changes.tsv' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if ($files.Count -eq 0) {
    Write-Bad 'No change logs found - nothing to restore.'
    return
}

$selected = @()
if ($Changes) {
    if (-not (Test-Path -LiteralPath $Changes)) {
        Write-Bad "Change log not found: $Changes"
        return
    }
    $selected = @(Get-Item -LiteralPath $Changes)
}
elseif ($All) {
    $selected = $files
}
else {
    Write-Host ''
    Write-Host '  Change logs (newest first):' -ForegroundColor Cyan
    for ($i = 0; $i -lt $files.Count; $i++) {
        $f = $files[$i]
        Write-Host ("    {0}) {1}  [{2}]" -f ($i + 1), $f.Name, $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
    }
    Write-Host ''
    $pick = ([string](Read-Host '  Restore which one? [1]')).Trim()
    if (-not $pick) { $pick = '1' }
    $idx = 0
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $files.Count) {
        Write-Bad 'Invalid choice.'
        return
    }
    $selected = @($files[$idx - 1])
}

try {
    $dev = Select-AndroidDevice -Serial $Serial
}
catch {
    Write-Bad $_.Exception.Message
    return
}
$info = Get-DeviceInfo -Serial $dev.Serial
Write-Ok ("Connected: {0}" -f $info.Model)

# Parse rows, newest log first, one entry per package.
$rows = New-Object 'System.Collections.Generic.List[object]'
$seen = @{}
$metaSerial = $null

foreach ($file in $selected) {
    $lines = Get-Content -LiteralPath $file.FullName
    foreach ($line in $lines) {
        if (-not $line -or $line.StartsWith('#')) {
            if ($line -match 'serial=([^\s]+)') {
                if (-not $metaSerial) { $metaSerial = $matches[1] }
            }
            continue
        }
        $parts = $line -split "`t"
        if ($parts.Count -lt 2) { continue }
        $pkg = $parts[0].Trim()
        $action = $parts[1].Trim()
        if (-not $pkg -or $pkg -in $seen.Keys) { continue }
        $seen[$pkg] = $true
        $rows.Add([pscustomobject]@{ Package = $pkg; Action = $action; File = $file.Name })
    }
}

if ($rows.Count -eq 0) {
    Write-Bad 'Those logs contain no package entries.'
    return
}

if ($metaSerial -and $metaSerial -ne $dev.Serial) {
    Write-Warn2 ("These logs were made for serial {0}, but {1} is connected." -f $metaSerial, $dev.Serial)
    if (-not $Yes) {
        $answer = ([string](Read-Host '  Continue anyway? [y/N]')).Trim()
        if ($answer -notmatch '^(?i)y(es)?$') { Write-Dim '  Aborted.'; return }
    }
}

Write-Host ''
Write-Host ("  Restoring {0} package(s):" -f $rows.Count) -ForegroundColor Cyan
foreach ($r in $rows) {
    $verb = 'enable'
    if ($r.Action -eq 'uninstall') { $verb = 'install-existing' }
    Write-Host ("    {0,-10} {1}" -f $verb, $r.Package) -ForegroundColor Yellow
}

if ($DryRun) {
    Write-Host ''
    Write-Ok 'Dry run: nothing was changed.'
    return
}

if (-not $Yes) {
    $answer = ([string](Read-Host '  Proceed? [y/N]')).Trim()
    if ($answer -notmatch '^(?i)y(es)?$') { Write-Dim '  Aborted.'; return }
}

Write-Host ''
$restored = 0
$failed = 0
foreach ($r in $rows) {
    if ($r.Action -eq 'uninstall') {
        $res = Invoke-Adb -AdbArgs @('-s', $dev.Serial, 'shell', 'pm', 'install-existing', '--user', '0', $r.Package) -AllowFail
        if ($res.Text -match 'installed' -or $res.ExitCode -eq 0) {
            $restored++
            Write-Ok $r.Package
        }
        else {
            $failed++
            Write-Bad ("{0} -> {1}" -f $r.Package, ($res.Text -replace '\s+', ' '))
        }
    }
    else {
        $res = Invoke-Adb -AdbArgs @('-s', $dev.Serial, 'shell', 'pm', 'enable', $r.Package) -AllowFail
        if ($res.Text -notmatch '(?i)error|exception|unknown') {
            $restored++
            Write-Ok $r.Package
        }
        else {
            $failed++
            Write-Bad ("{0} -> {1}" -f $r.Package, ($res.Text -replace '\s+', ' '))
        }
    }
}

Write-Head 'Summary'
Write-Host ("  restored : {0}" -f $restored) -ForegroundColor Green
Write-Host ("  failed   : {0}" -f $failed) -ForegroundColor $(if ($failed -gt 0) { 'Yellow' } else { 'DarkGray' })
Write-Dim  '  Reboot the phone so the launcher picks everything up again.'
