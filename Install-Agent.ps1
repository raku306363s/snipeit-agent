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
    # Interactive: copy the agent token in Snipe-IT first; it is read from the clipboard
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
try { Start-Transcript -Path (Join-Path $env:ProgramData 'SnipeITAgent-install.log') -Append | Out-Null } catch { }
# Repair installs made by v1.0, whose file permissions locked everyone out.
& takeown.exe /F $InstallDir /R /A /D Y 2>&1 | Out-Null
& icacls.exe $InstallDir /reset /T /Q 2>&1 | Out-Null
Copy-Item -Path (Join-Path $Here 'SnipeIT-Agent.ps1') -Destination $InstallDir -Force

$configPath = Join-Path $InstallDir 'config.json'
if ($ConfigFile) {
    if (-not (Test-Path $ConfigFile)) { throw "Config file not found: $ConfigFile" }
    if (Test-Path $configPath) { Remove-Item $configPath -Force }
    Copy-Item -Path $ConfigFile -Destination $configPath -Force
} elseif ($SnipeUrl) {
    # The console truncates long pastes into Read-Host, and Snipe-IT tokens are ~1000
    # characters, so take the token from the clipboard: copy it in Snipe-IT, then run this.
    $token = ''
    try { $token = ((Get-Clipboard -Raw) -replace '\s', '') } catch { }
    if ($token.Length -ge 100 -and $token -match '^[A-Za-z0-9._-]+$') {
        Write-Host "Using the API token from the clipboard ($($token.Length) characters). Clearing the clipboard."
        try { Set-Clipboard -Value ' ' } catch { }
    } else {
        throw 'Copy the agent API token in Snipe-IT (Manage API Keys) so it is on the clipboard, then run this again.'
    }
    $cfg = [ordered]@{
        SnipeUrl         = $SnipeUrl.TrimEnd('/')
        ApiToken         = $token
        HeartbeatDays    = 7
        MaxSoftwareChars = 60000
        AssetTag         = $AssetTag
    }
    [IO.File]::WriteAllText($configPath, ($cfg | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
} elseif (-not (Test-Path $configPath)) {
    throw 'Pass -SnipeUrl (token from clipboard) or -ConfigFile <path to config.json>.'
}

if ($AssetTag -and $ConfigFile) {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    $cfg | Add-Member -NotePropertyName AssetTag -NotePropertyValue $AssetTag -Force
    [IO.File]::WriteAllText($configPath, ($cfg | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
}

Write-Host "Config: agent will report to $((Get-Content $configPath -Raw | ConvertFrom-Json).SnipeUrl)"
# Check the URL and token work before going further.
try {
    $c = Get-Content $configPath -Raw | ConvertFrom-Json
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    $null = Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Uri "$($c.SnipeUrl.TrimEnd('/'))/api/v1/hardware?limit=1" `
        -Headers @{ Authorization = "Bearer $($c.ApiToken)"; Accept = 'application/json' }
    Write-Host "API check OK: $($c.SnipeUrl) accepted the token." -ForegroundColor Green
} catch {
    Write-Warning "API check failed: $($_.Exception.Message). 401 = token wrong/revoked/truncated, 403 = user lacks Assets View. Installing anyway."
}

# Only SYSTEM and Administrators may read the folder (protects the API token).
# Set it on the folder only, then make every file inherit from it. (Applying the
# inheritable grant to files with /T leaves them with no access at all.)
& icacls.exe $InstallDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /Q | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed to set folder permissions ($LASTEXITCODE)" }
& icacls.exe (Join-Path $InstallDir '*') /reset /T /Q | Out-Null

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
