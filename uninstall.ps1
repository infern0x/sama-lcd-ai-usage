<#
  Removes sama-lcd-ai-usage: stops it, deletes the scheduled task and the installed files.
  Your Claude / Codex logins are not touched.
#>
$TaskName = 'sama-lcd-ai-usage'
$Dest = Join-Path $env:LOCALAPPDATA 'Programs\sama-lcd-ai-usage'

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
  Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
  Write-Host "Scheduled task '$TaskName' removed."
}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -match 'sama-lcd-ai-usage\.ps1' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force; Write-Host "Removed $Dest" }
Write-Host 'Done. Start the SAMA app again if you want its original display back.'
