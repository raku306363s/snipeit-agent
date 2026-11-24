<#
.SYNOPSIS
    Installs the Snipe-IT inventory agent on this Windows machine.

.DESCRIPTION
    - Copies SnipeIT-Agent.ps1 to C:\ProgramData\SnipeITAgent
    - Writes config.json (or copies the one you pass with -ConfigFile)
    - Locks the folder down to SYSTEM and Administrators (the config holds the API token)
    - Registers a scheduled task "Snipe-IT Inventory Agent" that runs as SYSTEM
      10 minutes after startup and once a day (with a random delay so 400+ laptops
      don't all hit the server at the same minute)
    - Runs the agent once right away (skip with -NoRun)

    Must be run as Administrator. Safe to rerun: it upgrades the script and task in place.

.EXAMPLE
    # Interactive: prompts for the token without echoing it
    .\Install-Agent.ps1 -SnipeUrl https://hrms.wisilica.com/itasset

.EXAMPLE
    # Mass rollout (GPO startup script / Intune / PDQ): ship a prepared config.json
    .\Install-Agent.ps1 -ConfigFile \\fileserver\it$\snipeit-agent\config.json
#>
[CmdletBinding()]
param(
    [string]$SnipeUrl,
    [string]$ConfigFile,
    [string]$AssetTag,
    [string]$DailyTime = '11:00',
    [switch]$NoRun
)

$ErrorActionPreference = 'Stop'
$InstallDir = Join-Path $env:ProgramData 'SnipeITAgent'
$TaskName = 'Snipe-IT Inventory Agent'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated (Administrator) PowerShell.'
}

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Copy-Item -Path (Join-Path $Here 'SnipeIT-Agent.ps1') -Destination $InstallDir -Force

$configPath = Join-Path $InstallDir 'config.json'
if ($ConfigFile) {
    Copy-Item -Path $ConfigFile -Destination $configPath -Force
} elseif ($SnipeUrl) {
    $sec = Read-Host -AsSecureString 'Snipe-IT API token for the agent (low-privilege user)'
    $token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    $cfg = [ordered]@{
        SnipeUrl         = $SnipeUrl.TrimEnd('/')
        ApiToken         = $token
        HeartbeatDays    = 7
        MaxSoftwareChars = 60000
        AssetTag         = $AssetTag
    }
    [IO.File]::WriteAllText($configPath, ($cfg | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
} elseif (-not (Test-Path $configPath)) {
    throw 'Pass -SnipeUrl (prompts for the token) or -ConfigFile <path to config.json>.'
}

if ($AssetTag -and $ConfigFile) {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName AssetTag -NotePropertyValue $AssetTag -Force
    [IO.File]::WriteAllText($configPath, ($cfg | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
}

# Only SYSTEM and Administrators may read the folder (protects the API token).
& icacls.exe $InstallDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /T /Q | Out-Null

$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $psExe `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstallDir\SnipeIT-Agent.ps1`""

$atStartup = New-ScheduledTaskTrigger -AtStartup
$atStartup.Delay = 'PT10M'
$daily = New-ScheduledTaskTrigger -Daily -At $DailyTime -RandomDelay (New-TimeSpan -Hours 2)

$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew
$taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($atStartup, $daily) `
    -Settings $settings -Principal $taskPrincipal -Description 'Reports hardware and installed software to Snipe-IT' -Force | Out-Null

Write-Host "Installed to $InstallDir and registered task '$TaskName'." -ForegroundColor Green

if (-not $NoRun) {
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "First run started. Check $InstallDir\agent.log in a minute."
}
