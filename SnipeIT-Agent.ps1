<#
.SYNOPSIS
    Snipe-IT inventory sensor for Windows laptops and PCs.

.DESCRIPTION
    Collects hardware and software facts (CPU, RAM, storage, OS, network, logged-in
    user, installed applications) and writes them into the matching Snipe-IT asset's
    custom fields through the REST API.

    The asset is found by the BIOS serial number (Dell service tag / Lenovo serial).
    If the serial is missing or generic, the optional "AssetTag" in config.json is used.

    Only fields whose values changed are sent, so the Snipe-IT activity log is not
    flooded. Hardware, OS and software changes are sent right away. Fast-changing
    values (free disk space, IP, logged-in user) are only refreshed together with a
    real change or the heartbeat. "Last Inventory" is refreshed at least every
    HeartbeatDays days so you can spot machines whose agent stopped reporting.

    Runs on Windows PowerShell 5.1 and PowerShell 7. Designed to run as SYSTEM from a
    scheduled task (see Install-Agent.ps1).

.PARAMETER ConfigPath
    Path to config.json. Defaults to config.json next to this script.

.PARAMETER DryRun
    Collect and print the inventory, and show what would be sent, without changing
    anything in Snipe-IT. If no API token is configured, it only collects.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\SnipeIT-Agent.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$AgentVersion = '1.0.0'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'config.json' }
$DataDir = Split-Path -Parent $ConfigPath
$LogPath = Join-Path $DataDir 'agent.log'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try {
        if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 1MB)) {
            Move-Item -Path $LogPath -Destination "$LogPath.old" -Force
        }
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
$DefaultFieldNames = [ordered]@{
    HardwareModel = 'Hardware Model'
    Hostname      = 'Hostname'
    CPU           = 'CPU'
    RamGB         = 'RAM (GB)'
    Storage       = 'Storage'
    DiskFreeGB    = 'Disk Free C: (GB)'
    Volumes       = 'Volumes'
    OS            = 'Operating System'
    OSBuild       = 'OS Build'
    IPAddress     = 'IP Address'
    MACAddress    = 'MAC Address (Agent)'
    LastUser      = 'Last Logged-in User'
    SoftwareCount = 'Software Count'
    Software      = 'Installed Software'
    LastInventory = 'Last Inventory'
}

$DefaultSoftwareExclude = @(
    '^Security Update for',
    '^Update for',
    '^Hotfix for',
    '\(KB\d+\)',
    '^Microsoft Visual C\+\+ \d{4}.*(Additional|Minimum) Runtime',
    '^Microsoft \.NET .*(Host|Hostfx|Targeting Pack|Toolset|AppHost|Manifest)',
    '^Windows SDK',
    '^vs_'
)

$Config = $null
if (Test-Path $ConfigPath) {
    $Config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Get-Cfg([string]$Name, $Default) {
    if ($Config -and ($Config.PSObject.Properties.Name -contains $Name) -and $null -ne $Config.$Name -and "$($Config.$Name)" -ne '') {
        return $Config.$Name
    }
    return $Default
}

$SnipeUrl        = ([string](Get-Cfg 'SnipeUrl' '')).TrimEnd('/')
$ApiToken        = [string](Get-Cfg 'ApiToken' '')
$HeartbeatDays   = [int](Get-Cfg 'HeartbeatDays' 7)
$MaxSoftwareChars= [int](Get-Cfg 'MaxSoftwareChars' 60000)
$ConfigAssetTag  = [string](Get-Cfg 'AssetTag' '')
$SoftwareExclude = @(Get-Cfg 'SoftwareExclude' $DefaultSoftwareExclude)

$FieldNames = [ordered]@{}
foreach ($k in $DefaultFieldNames.Keys) { $FieldNames[$k] = $DefaultFieldNames[$k] }
$cfgFields = Get-Cfg 'FieldNames' $null
if ($cfgFields) {
    foreach ($p in $cfgFields.PSObject.Properties) { $FieldNames[$p.Name] = [string]$p.Value }
}

# ---------------------------------------------------------------------------
# Collection helpers
# ---------------------------------------------------------------------------
function Get-Safe([scriptblock]$Block, $Default = $null) {
    try { & $Block } catch { Write-Log "Collection step failed: $($_.Exception.Message)" 'WARN'; $Default }
}

function Format-GB([double]$Bytes) {
    [math]::Round($Bytes / 1GB, 0)
}

function Test-UsableSerial([string]$Serial) {
    if ([string]::IsNullOrWhiteSpace($Serial)) { return $false }
    $bad = '^(To be filled by O\.E\.M\.|Default string|System Serial Number|None|N/A|0+|Not Specified|INVALID|123456789|Chassis Serial Number)$'
    return -not ($Serial.Trim() -match $bad)
}

function Get-SerialNumber {
    $s = (Get-CimInstance Win32_BIOS).SerialNumber
    if (Test-UsableSerial $s) { return $s.Trim() }
    $s = (Get-CimInstance Win32_SystemEnclosure).SerialNumber
    if (Test-UsableSerial $s) { return $s.Trim() }
    $s = (Get-CimInstance Win32_ComputerSystemProduct).IdentifyingNumber
    if (Test-UsableSerial $s) { return $s.Trim() }
    return $null
}

function Get-StorageSummary {
    $parts = @()
    $physical = Get-Safe { @(Get-CimInstance -Namespace 'root\Microsoft\Windows\Storage' -ClassName MSFT_PhysicalDisk) } @()
    if ($physical.Count -gt 0) {
        foreach ($d in ($physical | Sort-Object DeviceId)) {
            $media = switch ([int]$d.MediaType) { 3 { 'HDD' } 4 { 'SSD' } 5 { 'SCM' } default { 'Disk' } }
            if ([int]$d.BusType -eq 17) { $media = 'NVMe SSD' }
            if ([int]$d.BusType -eq 7) { continue }   # USB sticks / external drives
            $parts += ('{0} {1} GB ({2})' -f $media, (Format-GB $d.Size), ($d.FriendlyName -replace '\s+', ' ').Trim())
        }
    } else {
        foreach ($d in (Get-CimInstance Win32_DiskDrive | Where-Object { $_.InterfaceType -ne 'USB' })) {
            $parts += ('{0} GB ({1})' -f (Format-GB $d.Size), ($d.Model -replace '\s+', ' ').Trim())
        }
    }
    return ($parts -join '; ')
}

function Get-PrimaryNetwork {
    $cfg = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = TRUE' |
        Where-Object { $_.DefaultIPGateway } |
        Sort-Object { [int]$_.IPConnectionMetric } |
        Select-Object -First 1
    if (-not $cfg) { return @{ IP = ''; MAC = '' } }
    $ipv4 = @($cfg.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }) -join ', '
    return @{ IP = $ipv4; MAC = [string]$cfg.MACAddress }
}

function Get-LastUser {
    $u = (Get-CimInstance Win32_ComputerSystem).UserName
    if ($u) { return [string]$u }
    $reg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Authentication\LogonUI'
    $v = Get-Safe { (Get-ItemProperty -Path $reg -ErrorAction Stop).LastLoggedOnUser } ''
    return [string]$v
}

function Get-InstalledSoftware {
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    # Per-user installs (Teams, Zoom, VS Code user setup...) for users whose hive is loaded.
    foreach ($sidKey in (Get-ChildItem 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
        if ($sidKey.PSChildName -match '^S-1-5-21-[\d-]+$') {
            $roots += "Registry::HKEY_USERS\$($sidKey.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Uninstall"
        }
    }

    $seen = @{}
    $apps = New-Object System.Collections.Generic.List[object]
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        foreach ($key in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            $name = [string]$p.DisplayName
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($p.SystemComponent -eq 1) { continue }
            if ($p.ParentKeyName) { continue }
            if ($p.ReleaseType -in @('Update', 'Hotfix', 'Security Update')) { continue }
            $name = ($name -replace '\s+', ' ').Trim()
            $excluded = $false
            foreach ($rx in $SoftwareExclude) { if ($name -match $rx) { $excluded = $true; break } }
            if ($excluded) { continue }
            $version = ([string]$p.DisplayVersion).Trim()
            $id = "$name|$version".ToLowerInvariant()
            if ($seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
            $apps.Add([pscustomobject]@{ Name = $name; Version = $version; Publisher = ([string]$p.Publisher).Trim() })
        }
    }
    return @($apps | Sort-Object Name, Version)
}

function Get-CleanManufacturer([string]$Name) {
    $n = ($Name -replace '\s+', ' ').Trim()
    switch -Regex ($n) {
        '^Dell'                  { return 'Dell' }
        '^LENOVO'                { return 'Lenovo' }
        '^(HP|Hewlett)'          { return 'HP' }
        '^ASUS'                  { return 'ASUS' }
        '^Acer'                  { return 'Acer' }
        '^TOSHIBA|^Dynabook'     { return 'Toshiba' }
        '^Micro-Star|^MSI'       { return 'MSI' }
        '^Gigabyte'              { return 'Gigabyte' }
        '^Intel'                 { return 'Intel' }
        '^Microsoft'             { return 'Microsoft' }
        '^Samsung'               { return 'Samsung' }
        '^Apple'                 { return 'Apple' }
    }
    return ($n -replace ',?\s+(Inc\.?|Corporation|Corp\.?|Co\.,? ?Ltd\.?|Ltd\.?|Technology|COMPUTER INC\.?)\b.*$', '').Trim()
}

# "Manufacturer Model" as the vendor markets it, e.g. "Dell Vostro 15 3510", "Lenovo ideapad 330-15IKB",
# "ASUS H170M-PLUS" (custom-built PCs report the motherboard).
function Get-HardwareModel($cs) {
    $junk = '^(System Product Name|System manufacturer|To be filled by O\.E\.M\.|Default string|Not Applicable|None|)$'
    $mfr = [string]$cs.Manufacturer
    $model = [string]$cs.Model
    if ($mfr -match '^LENOVO') {
        # Lenovo puts the machine type (81DE) in Model and the marketing name in Version.
        $v = [string](Get-CimInstance Win32_ComputerSystemProduct).Version
        if ($v -and $v -notmatch $junk) { $model = $v }
    }
    if ($model.Trim() -match $junk -or $mfr.Trim() -match $junk) {
        $bb = Get-CimInstance Win32_BaseBoard
        $mfr = [string]$bb.Manufacturer
        $model = [string]$bb.Product
    }
    $mfr = Get-CleanManufacturer $mfr
    $model = ($model -replace '\s+', ' ').Trim()
    if ($model -match "^$([regex]::Escape($mfr))\s+(.*)$") { $model = $Matches[1] }   # "HP HP Pavilion" -> "HP Pavilion"
    return ("$mfr $model").Trim()
}

function Get-Inventory {
    $cs  = Get-CimInstance Win32_ComputerSystem
    $os  = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1

    $ramBytes = Get-Safe { (Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum } 0
    if (-not $ramBytes) { $ramBytes = $cs.TotalPhysicalMemory }

    $cDrive = Get-Safe { Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" }
    $volumes = Get-Safe {
        (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' | Sort-Object DeviceID | ForEach-Object {
            '{0} {1} GB free of {2} GB' -f $_.DeviceID, (Format-GB $_.FreeSpace), (Format-GB $_.Size)
        }) -join '; '
    } ''

    $cv = Get-Safe { Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' }
    $displayVersion = if ($cv.DisplayVersion) { $cv.DisplayVersion } elseif ($cv.ReleaseId) { $cv.ReleaseId } else { '' }
    $build = if ($null -ne $cv.UBR) { "$($cv.CurrentBuildNumber).$($cv.UBR)" } else { [string]$os.BuildNumber }
    $osName = ([string]$os.Caption -replace '^Microsoft\s+', '').Trim()
    # Win11 still reports "Windows 10" in ProductName on some builds; build >= 22000 is Windows 11.
    if ([int]$os.BuildNumber -ge 22000) { $osName = $osName -replace 'Windows 10', 'Windows 11' }

    $net = Get-Safe { Get-PrimaryNetwork } @{ IP = ''; MAC = '' }
    $software = @(Get-Safe { Get-InstalledSoftware } @())

    $softwareText = ($software | ForEach-Object {
        if ($_.Version) { "$($_.Name) ($($_.Version))" } else { $_.Name }
    }) -join "`n"
    if ($softwareText.Length -gt $MaxSoftwareChars) {
        $softwareText = $softwareText.Substring(0, $MaxSoftwareChars) + "`n... (truncated)"
    }

    [pscustomobject]@{
        Serial        = Get-Safe { Get-SerialNumber }
        Manufacturer  = [string]$cs.Manufacturer
        Model         = [string]$cs.Model
        HardwareModel = [string](Get-Safe { Get-HardwareModel $cs } '')
        Hostname      = [string]$env:COMPUTERNAME
        CPU           = (([string]$cpu.Name) -replace '\s+', ' ').Trim()
        RamGB         = [string](Format-GB $ramBytes)
        Storage       = [string](Get-Safe { Get-StorageSummary } '')
        DiskFreeGB    = if ($cDrive) { [string](Format-GB $cDrive.FreeSpace) } else { '' }
        Volumes       = [string]$volumes
        OS            = ("$osName $displayVersion").Trim()
        OSBuild       = $build
        IPAddress     = [string]$net.IP
        MACAddress    = [string]$net.MAC
        LastUser      = [string](Get-Safe { Get-LastUser } '')
        SoftwareCount = [string]$software.Count
        Software      = $softwareText
        SoftwareList  = $software
    }
}

# ---------------------------------------------------------------------------
# Snipe-IT API
# ---------------------------------------------------------------------------
function Invoke-Snipe {
    param([string]$Method, [string]$Path, $Body)
    $uri = "$SnipeUrl/api/v1/$($Path.TrimStart('/'))"
    $params = @{
        Uri             = $uri
        Method          = $Method
        Headers         = @{ Authorization = "Bearer $ApiToken"; Accept = 'application/json' }
        UseBasicParsing = $true
        TimeoutSec      = 60
    }
    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 6 -Compress
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes($json)
        $params.ContentType = 'application/json; charset=utf-8'
    }
    try {
        $resp = Invoke-WebRequest @params
    } catch {
        # Show what the server actually said, not just the status code.
        $r = $_.Exception.Response
        if (-not $r) { throw }
        $code = [int]$r.StatusCode
        $body = ''
        try { $body = (New-Object IO.StreamReader($r.GetResponseStream(), [Text.Encoding]::UTF8)).ReadToEnd() } catch { }
        $msg = $body
        try { $j = $body | ConvertFrom-Json; if ($j.messages) { $msg = ($j.messages | ConvertTo-Json -Compress -Depth 4) } elseif ($j.message) { $msg = $j.message } } catch { }
        $msg = ($msg -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim()
        if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) + '...' }
        $hint = switch ($code) {
            401 { ' (token wrong, revoked, cut off when pasted, or from another server)' }
            403 { ' (the token''s user lacks permission for this; use an admin/superuser token)' }
            default { '' }
        }
        throw "HTTP $code on $Method $Path$hint. Server said: $msg"
    }
    # Decode as UTF-8 ourselves; PowerShell 5.1 guesses ISO-8859-1 when no charset is sent.
    $reader = New-Object System.IO.StreamReader($resp.RawContentStream, [System.Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd()
    $result = $text | ConvertFrom-Json
    if ($result.PSObject.Properties.Name -contains 'status' -and $result.status -eq 'error') {
        $msg = $result.messages | ConvertTo-Json -Depth 4 -Compress
        throw "Snipe-IT returned an error for $Method $Path : $msg"
    }
    return $result
}

function Find-Asset([string]$Serial, [string]$AssetTag) {
    if ($Serial) {
        try {
            $r = Invoke-Snipe -Method GET -Path ("hardware/byserial/" + [uri]::EscapeDataString($Serial))
            $rows = @($r.rows)
            if ($rows.Count -eq 1) { return $rows[0] }
            if ($rows.Count -gt 1) {
                throw "Serial '$Serial' matches $($rows.Count) assets in Snipe-IT (tags: $(($rows | ForEach-Object asset_tag) -join ', ')). Fix the duplicate serials, then rerun."
            }
        } catch {
            if ($_.Exception.Message -match 'matches \d+ assets') { throw }
            if ($_.Exception.Message -notmatch '404|not found|does not exist') { throw }
        }
    }
    if ($AssetTag) {
        # bytag/{tag} breaks on tags with slashes (WICDC/LAP/014), so search and match exactly.
        $r = Invoke-Snipe -Method GET -Path ("hardware?limit=50&search=" + [uri]::EscapeDataString($AssetTag))
        $match = @($r.rows | Where-Object { $_.asset_tag -eq $AssetTag })
        if ($match.Count -eq 1) { return $match[0] }
    }
    return $null
}

function Normalize([string]$Value) {
    if ($null -eq $Value) { return '' }
    $v = [System.Net.WebUtility]::HtmlDecode($Value)
    return ($v -replace "`r`n", "`n").Trim()
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
try {
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }

    Write-Log "Snipe-IT agent $AgentVersion starting on $env:COMPUTERNAME$(if ($DryRun) { ' (dry run)' })"
    $inv = Get-Inventory
    Write-Log ("Collected: serial={0}, model={1}, RAM={2} GB, apps={3}" -f $inv.Serial, $inv.HardwareModel, $inv.RamGB, $inv.SoftwareCount)

    # Keep a local copy for troubleshooting.
    try {
        $inv | Select-Object * -ExcludeProperty Software |
            ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $DataDir 'inventory.json') -Encoding UTF8
    } catch { }

    if ($DryRun) {
        $inv | Select-Object * -ExcludeProperty Software, SoftwareList | Format-List | Out-String | Write-Host
        Write-Host "Installed software ($($inv.SoftwareCount)):`n$($inv.Software)`n"
    }
    if ($DryRun -and (-not $SnipeUrl -or -not $ApiToken)) {
        Write-Log 'Dry run without API settings: collection only.'
        exit 0
    }
    if (-not $SnipeUrl -or -not $ApiToken) { throw "SnipeUrl and ApiToken must be set in $ConfigPath" }

    $asset = Find-Asset -Serial $inv.Serial -AssetTag $ConfigAssetTag
    if (-not $asset) {
        Write-Log "No Snipe-IT asset found for serial '$($inv.Serial)'$(if ($ConfigAssetTag) { " or tag '$ConfigAssetTag'" }). Add the serial to the asset in Snipe-IT." 'WARN'
        exit 2
    }
    Write-Log "Matched asset id=$($asset.id) tag=$($asset.asset_tag) name=$($asset.name)"

    # Map our field names to this asset's DB columns using the asset's own custom_fields
    # block. This only needs "view assets" permission, not access to the fields API.
    $existing = @{}
    if ($asset.custom_fields) {
        foreach ($p in $asset.custom_fields.PSObject.Properties) {
            $existing[$p.Name] = [pscustomobject]@{ Column = $p.Value.field; Value = [string]$p.Value.value }
        }
    }

    # Volatile fields (free space, IP, user) change almost daily. They are only sent with a
    # "real" change or with the heartbeat, so the activity log isn't flooded every day.
    $volatile = @('DiskFreeGB', 'Volumes', 'IPAddress', 'LastUser')
    $stableChanges   = [ordered]@{}
    $volatileChanges = [ordered]@{}
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($key in $FieldNames.Keys) {
        if ($key -eq 'LastInventory') { continue }
        $fname = $FieldNames[$key]
        if (-not $existing.ContainsKey($fname)) { $missing.Add($fname); continue }
        $new = [string]$inv.$key
        if ((Normalize $existing[$fname].Value) -ne (Normalize $new)) {
            if ($volatile -contains $key) { $volatileChanges[$fname] = $new } else { $stableChanges[$fname] = $new }
        }
    }
    if ($missing.Count -gt 0) {
        Write-Log ("These fields are not in this asset model's fieldset, so they were skipped: {0}. Run Setup-SnipeITFields.ps1 for model '{1}'." -f ($missing -join ', '), $asset.model.name) 'WARN'
    }

    # Heartbeat due when Last Inventory is empty, unreadable or older than HeartbeatDays.
    $lastName = $FieldNames['LastInventory']
    $heartbeatDue = $false
    if ($existing.ContainsKey($lastName)) {
        $prev = [datetime]::MinValue
        $ok = [datetime]::TryParseExact((Normalize $existing[$lastName].Value), 'yyyy-MM-dd HH:mm',
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$prev)
        $heartbeatDue = (-not $ok) -or (((Get-Date) - $prev).TotalDays -ge $HeartbeatDays)
    }

    $payload = [ordered]@{}
    $changed = @()
    if ($stableChanges.Count -gt 0 -or $heartbeatDue) {
        foreach ($set in @($stableChanges, $volatileChanges)) {
            foreach ($fname in $set.Keys) {
                $payload[$existing[$fname].Column] = $set[$fname]
                $changed += $fname
            }
        }
        if ($existing.ContainsKey($lastName)) {
            $payload[$existing[$lastName].Column] = Get-Date -Format 'yyyy-MM-dd HH:mm'
        }
    }

    if ($payload.Count -eq 0) {
        Write-Log ("No significant changes and heartbeat not due. Nothing sent{0}." -f $(if ($volatileChanges.Count) { " (pending: $($volatileChanges.Keys -join ', '))" } else { '' }))
        exit 0
    }

    if ($DryRun) {
        Write-Log ("Dry run: would update asset {0} fields: {1}" -f $asset.asset_tag, ((@($changed) + $lastName) -join ', '))
        exit 0
    }

    $null = Invoke-Snipe -Method PATCH -Path "hardware/$($asset.id)" -Body $payload
    Write-Log ("Updated asset {0}: {1}" -f $asset.asset_tag, $(if ($changed.Count) { $changed -join ', ' } else { 'heartbeat only' }))
    exit 0
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    exit 1
}
