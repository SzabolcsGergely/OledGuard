#Requires -Version 5.1
<#
.SYNOPSIS
  Stops OLED Guard, removes the logon task, and puts the taskbar, background and desktop icons back.
#>
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'oled-guard.ps1'

if (Get-ScheduledTask -TaskName 'OledGuard' -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName 'OledGuard' -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'OledGuard' -Confirm:$false
}

# A guard started by hand (or one the task left behind).
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*oled-guard.ps1*' -and $_.ProcessId -ne $PID -and $_.CommandLine -notlike '*-Restore*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# A killed guard doesn't restore on its way out; its saved originals do it here.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Restore
"OLED Guard removed; taskbar, background and icons restored."
