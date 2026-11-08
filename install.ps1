<#
  Installs sama-lcd-ai-usage for the current user and starts it at every sign-in.
    - copies src\ to %LOCALAPPDATA%\Programs\sama-lcd-ai-usage
    - registers a Scheduled Task "sama-lcd-ai-usage" (at logon, hidden, no admin rights needed)
  Usage:
    powershell -ExecutionPolicy Bypass -File install.ps1 [-Rotate 180] [-Fps 15] [-Port COM3]
#>
param(
  [ValidateSet(0, 90, 180, 270)][int]$Rotate = 0,
  [ValidateRange(1, 30)][int]$Fps = 15,
  [string]$Port = '',
  [switch]$NoStart
)
$ErrorActionPreference = 'Stop'
$TaskName = 'sama-lcd-ai-usage'
$Dest = Join-Path $env:LOCALAPPDATA 'Programs\sama-lcd-ai-usage'
$Src = Join-Path $PSScriptRoot 'src'

if (Get-Process SAMA -ErrorAction SilentlyContinue) {
  Write-Warning 'The SAMA app is running and will block the screen. Quit it from the tray (and disable its auto-start) first.'
}

# stop a running copy before replacing files
Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Stop-ScheduledTask -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'sama-lcd-ai-usage\.ps1' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Force $Dest | Out-Null
Copy-Item (Join-Path $Src '*') $Dest -Force
Write-Host "Installed to $Dest"

$argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dest\sama-lcd-ai-usage.ps1`" -Rotate $Rotate -Fps $Fps"
if ($Port) { $argList += " -Port $Port" }
$user = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $argList -WorkingDirectory $Dest
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$trigger.Delay = 'PT20S'
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) `
  -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $TaskName -Description 'Claude / Codex usage on the SAMA cooler LCD' `
  -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Write-Host "Scheduled task '$TaskName' registered (starts 20 s after sign-in)."

if (-not $NoStart) {
  Start-ScheduledTask -TaskName $TaskName
  Write-Host "Started. Log: $Dest\sama-lcd-ai-usage.log"
}
