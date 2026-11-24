# Removes the Snipe-IT inventory agent from this machine. Run as Administrator.
$ErrorActionPreference = 'Stop'
$TaskName = 'Snipe-IT Inventory Agent'
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
$dir = Join-Path $env:ProgramData 'SnipeITAgent'
if (Test-Path $dir) { Remove-Item -Path $dir -Recurse -Force }
Write-Host 'Snipe-IT agent removed. Asset data already in Snipe-IT is kept.'
