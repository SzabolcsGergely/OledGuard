#Requires -Version 5.1
<#
.SYNOPSIS
  Starts OLED Guard at every logon of this user (Task Scheduler, no admin needed) and starts it now.
  Any arguments are passed on to oled-guard.ps1, e.g.  .\install.ps1 -IdleMinutes 5 -KeepTaskbar
#>
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'oled-guard.ps1'
$extra = ($args | ForEach-Object { if ("$_" -match '\s') { "`"$_`"" } else { "$_" } }) -join ' '

# conhost --headless runs PowerShell without a console window (no flash at logon).
$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" $extra".Trim()
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" `
    -Argument "--headless `"$PSHOME\powershell.exe`" $psArgs" -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName 'OledGuard' -Description 'Blanks the OLED TV when idle; hides taskbar and wallpaper while it is active.' `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'OledGuard'
"OLED Guard installed: starts at logon, and is running now."
