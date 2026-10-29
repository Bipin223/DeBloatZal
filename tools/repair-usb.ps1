$ErrorActionPreference = 'Continue'
$root = 'D:\android-debloater'
$log = Join-Path $root 'logs\usb-repair.log'
New-Item -ItemType Directory -Path (Split-Path $log) -Force | Out-Null
Start-Transcript -Path $log -Force

Write-Host ("USB repair started " + (Get-Date))
Write-Host '--- removing stale Samsung device nodes ---'
$nodes = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VID_04E8' })
Write-Host ("Samsung nodes found: " + $nodes.Count)
foreach ($n in $nodes) {
    if ($n.Status -eq 'OK') {
        Write-Host ("skip (present): " + $n.InstanceId)
        continue
    }
    Write-Host ("remove: " + $n.InstanceId)
    pnputil /remove-device "$($n.InstanceId)" 2>&1 | ForEach-Object { Write-Host ("  " + $_) }
}

Write-Host '--- disabling USB selective suspend ---'
$sub = '2a737441-1930-4402-8d77-b2bebba308a3'
$set = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
powercfg /setacvalueindex SCHEME_CURRENT $sub $set 0 2>&1 | Out-Null
powercfg /setdcvalueindex SCHEME_CURRENT $sub $set 0 2>&1 | Out-Null
powercfg /setactive SCHEME_CURRENT 2>&1 | Out-Null
Write-Host 'done'

Write-Host '--- rescanning hardware ---'
pnputil /scan-devices 2>&1 | ForEach-Object { Write-Host ("  " + $_) }

Write-Host '--- resetting adb server ---'
$adb = Join-Path $root 'tools\platform-tools\adb.exe'
& $adb kill-server 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
& $adb start-server 2>&1 | Out-Null
& $adb devices -l 2>&1 | ForEach-Object { Write-Host ("  " + $_) }

Write-Host 'Repair finished. Plug the phone in now.'
Stop-Transcript
