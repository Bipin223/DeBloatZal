#Requires -Version 5.1
<#
    Small interactive menu. Started by Start.cmd, or run directly:
    powershell -ExecutionPolicy Bypass -File .\scripts\menu.ps1
#>
[CmdletBinding()]
param()

$root = Split-Path -Parent $PSScriptRoot

function Pause-Menu {
    Write-Host ''
    [void](Read-Host '  Press Enter to return to the menu')
}

$running = $true
while ($running) {
    Clear-Host
    Write-Host ''
    Write-Host '   DeBloatZal' -ForegroundColor Cyan
    Write-Host '   ==========' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '   1   Setup / update adb (platform-tools)'
    Write-Host '   2   Check phone connection (doctor)'
    Write-Host '   3   List installed packages'
    Write-Host '   4   Debloat (GUI)'
    Write-Host '   5   Debloat (text menu)'
    Write-Host '   6   Restore from a change log'
    Write-Host '   7   Open README / profiles folder'
    Write-Host '   Q   Quit'
    Write-Host ''
    $choice = ([string](Read-Host '   Select')).Trim().ToUpperInvariant()

    try {
        switch ($choice) {
            '1' {
                & (Join-Path $root 'setup.ps1')
                Pause-Menu
            }
            '2' {
                & (Join-Path $root 'scripts\doctor.ps1')
                Pause-Menu
            }
            '3' {
                & (Join-Path $root 'scripts\list-packages.ps1')
                Pause-Menu
            }
            '4' {
                & (Join-Path $root 'scripts\gui.ps1')
                Pause-Menu
            }
            '5' {
                & (Join-Path $root 'scripts\debloat.ps1')
                Pause-Menu
            }
            '6' {
                & (Join-Path $root 'scripts\restore.ps1')
                Pause-Menu
            }
            '7' {
                Start-Process -FilePath 'explorer.exe' -ArgumentList (Join-Path $root 'profiles')
                Start-Process -FilePath 'notepad.exe' -ArgumentList (Join-Path $root 'README.md')
                Pause-Menu
            }
            'Q' {
                $running = $false
            }
            default {
                Write-Host '   Unknown choice.' -ForegroundColor Yellow
                Start-Sleep -Milliseconds 700
            }
        }
    }
    catch {
        Write-Host ''
        Write-Host ("   ERROR: " + $_.Exception.Message) -ForegroundColor Red
        Pause-Menu
    }
}
