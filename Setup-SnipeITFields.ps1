<#
.SYNOPSIS
    One-time Snipe-IT setup for the inventory agent: creates the custom fields and
    adds them to the fieldsets of your laptop/desktop models.

.DESCRIPTION
    By default this is a DRY RUN: it only reads from Snipe-IT and prints what it would
    do. Add -Apply to make the changes.

    What -Apply changes:
      1. Creates any missing custom fields (Hostname, CPU, RAM (GB), ... Installed Software).
      2. For every asset model whose category matches -CategoryPattern:
           - if the model already has a fieldset, the missing fields are added to it;
           - if not, the model is given the "Inventory Agent" fieldset (created if needed).
    Nothing is deleted, and no asset values are touched.

    Run it from any machine with PowerShell 5.1+ or PowerShell 7 (Windows or Linux) as a
    Snipe-IT admin. Use an admin API token here, NOT the low-privilege token the agents use.

.PARAMETER SnipeUrl
    Base URL of Snipe-IT, e.g. https://hrms.wisilica.com/itasset

.PARAMETER CategoryPattern
    Regex matched against the model's category name. Default: Laptop|Desktop|PC|Computer|Workstation

.PARAMETER Apply
    Actually make the changes. Without it, nothing is written.

.EXAMPLE
    .\Setup-SnipeITFields.ps1 -SnipeUrl https://hrms.wisilica.com/itasset
    .\Setup-SnipeITFields.ps1 -SnipeUrl https://hrms.wisilica.com/itasset -Apply
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SnipeUrl,
    [string]$CategoryPattern = 'Laptop|Desktop|PC|Computer|Workstation',
    [string]$FieldsetName = 'Inventory Agent',
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$SnipeUrl = $SnipeUrl.TrimEnd('/')
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# Token: from env var SNIPEIT_ADMIN_TOKEN, otherwise prompt (hidden input).
$Token = $env:SNIPEIT_ADMIN_TOKEN
if (-not $Token) {
    $sec = Read-Host -AsSecureString 'Snipe-IT admin API token'
    $Token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}

# Must match the defaults in SnipeIT-Agent.ps1 (or the FieldNames override in config.json).
$Fields = @(
    @{ name = 'Hostname';             element = 'text';     help = 'Computer name reported by the agent' }
    @{ name = 'CPU';                  element = 'text';     help = 'Processor model' }
    @{ name = 'RAM (GB)';             element = 'text';     help = 'Installed memory in GB' }
    @{ name = 'Storage';              element = 'text';     help = 'Physical drives (type, size, model)' }
    @{ name = 'Disk Free C: (GB)';    element = 'text';     help = 'Free space on C: in GB' }
    @{ name = 'Volumes';              element = 'text';     help = 'Free / total per local volume' }
    @{ name = 'Operating System';     element = 'text';     help = 'OS name and version' }
    @{ name = 'OS Build';             element = 'text';     help = 'OS build number' }
    @{ name = 'IP Address';           element = 'text';     help = 'IPv4 of the primary adapter' }
    @{ name = 'MAC Address (Agent)';  element = 'text';     help = 'MAC of the primary adapter' }
    @{ name = 'Last Logged-in User';  element = 'text';     help = 'Console user at last inventory' }
    @{ name = 'Software Count';       element = 'text';     help = 'Number of installed applications' }
    @{ name = 'Installed Software';   element = 'textarea'; help = 'Installed applications, one per line' }
    @{ name = 'Last Inventory';       element = 'text';     help = 'When the agent last reported (yyyy-MM-dd HH:mm)' }
)

function Invoke-Snipe {
    param([string]$Method, [string]$Path, $Body)
    $params = @{
        Uri             = "$SnipeUrl/api/v1/$($Path.TrimStart('/'))"
        Method          = $Method
        Headers         = @{ Authorization = "Bearer $Token"; Accept = 'application/json' }
        UseBasicParsing = $true
        TimeoutSec      = 60
    }
    if ($null -ne $Body) {
        $params.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 6 -Compress))
        $params.ContentType = 'application/json; charset=utf-8'
    }
    $resp = Invoke-WebRequest @params
    $reader = New-Object IO.StreamReader($resp.RawContentStream, [Text.Encoding]::UTF8)
    $result = $reader.ReadToEnd() | ConvertFrom-Json
    if ($result.PSObject.Properties.Name -contains 'status' -and $result.status -eq 'error') {
        throw "Snipe-IT error on $Method $Path : $($result.messages | ConvertTo-Json -Depth 4 -Compress)"
    }
    $result
}

function Get-All([string]$Path) {
    $out = @(); $offset = 0; $limit = 200
    do {
        $sep = if ($Path -match '\?') { '&' } else { '?' }
        $r = Invoke-Snipe GET "$Path${sep}limit=$limit&offset=$offset"
        $out += @($r.rows)
        $offset += $limit
    } while ($offset -lt [int]$r.total)
    $out
}

function Get-FieldsetFieldIds([int]$FieldsetId) {
    $fs = Invoke-Snipe GET "fieldsets/$FieldsetId"
    @($fs.fields.rows | ForEach-Object { [int]$_.id })
}

$mode = if ($Apply) { 'APPLY' } else { 'DRY RUN (add -Apply to make changes)' }
Write-Host "Snipe-IT: $SnipeUrl   Mode: $mode`n" -ForegroundColor Cyan

# 1. Fields -----------------------------------------------------------------
$allFields = Get-All 'fields'
$fieldIds = @{}
foreach ($f in $Fields) {
    $hit = $allFields | Where-Object { $_.name -eq $f.name } | Select-Object -First 1
    if ($hit) {
        $fieldIds[$f.name] = [int]$hit.id
        Write-Host ("  field exists : {0}  ({1})" -f $f.name, $hit.db_column_name)
        continue
    }
    if ($Apply) {
        $body = @{ name = $f.name; element = $f.element; format = 'ANY'; help_text = $f.help }
        $r = Invoke-Snipe POST 'fields' $body
        $fieldIds[$f.name] = [int]$r.payload.id
        Write-Host "  field created: $($f.name)" -ForegroundColor Green
    } else {
        $fieldIds[$f.name] = $null
        Write-Host "  would create field: $($f.name) [$($f.element)]" -ForegroundColor Yellow
    }
}

# 2. Models -----------------------------------------------------------------
$models = Get-All 'models' | Where-Object { $_.category -and $_.category.name -match $CategoryPattern }
Write-Host "`n$(@($models).Count) models in categories matching '$CategoryPattern'"
if (-not $models) { Write-Host 'No matching models. Check -CategoryPattern against your category names.' -ForegroundColor Yellow; return }

$fieldsets = Get-All 'fieldsets'
$ourSet = $fieldsets | Where-Object { $_.name -eq $FieldsetName } | Select-Object -First 1

# Fieldsets that need our fields: the ones already on models, plus ours for models without one.
$targets = @{}
$modelsWithout = @()
foreach ($m in $models) {
    if ($m.fieldset -and $m.fieldset.id) {
        $targets[[int]$m.fieldset.id] = $m.fieldset.name
    } else {
        $modelsWithout += $m
    }
}

if ($modelsWithout.Count -gt 0) {
    if (-not $ourSet) {
        if ($Apply) {
            $r = Invoke-Snipe POST 'fieldsets' @{ name = $FieldsetName }
            $ourSet = [pscustomobject]@{ id = [int]$r.payload.id; name = $FieldsetName }
            Write-Host "  fieldset created: $FieldsetName" -ForegroundColor Green
        } else {
            Write-Host "  would create fieldset: $FieldsetName" -ForegroundColor Yellow
        }
    }
    if ($ourSet) { $targets[[int]$ourSet.id] = $ourSet.name }
}

# 3. Associate fields with each target fieldset -----------------------------
foreach ($fsId in $targets.Keys) {
    $have = Get-FieldsetFieldIds $fsId
    foreach ($f in $Fields) {
        $fid = $fieldIds[$f.name]
        if ($fid -and ($have -contains $fid)) { continue }
        if ($Apply) {
            $null = Invoke-Snipe POST "fields/$fid/associate" @{ fieldset_id = $fsId; required = $false }
            Write-Host "  added '$($f.name)' to fieldset '$($targets[$fsId])'" -ForegroundColor Green
        } else {
            Write-Host "  would add '$($f.name)' to fieldset '$($targets[$fsId])'" -ForegroundColor Yellow
        }
    }
}
if ($modelsWithout.Count -gt 0 -and -not $ourSet) {
    Write-Host "  would add all fields to new fieldset '$FieldsetName'" -ForegroundColor Yellow
}

# 4. Give models without a fieldset our fieldset ----------------------------
foreach ($m in $modelsWithout) {
    if ($Apply) {
        $null = Invoke-Snipe PATCH "models/$($m.id)" @{ fieldset_id = [int]$ourSet.id }
        Write-Host "  model '$($m.name)' -> fieldset '$FieldsetName'" -ForegroundColor Green
    } else {
        Write-Host "  would set model '$($m.name)' ($($m.category.name)) -> fieldset '$FieldsetName'" -ForegroundColor Yellow
    }
}
foreach ($m in ($models | Where-Object { $_.fieldset -and $_.fieldset.id })) {
    Write-Host "  model '$($m.name)' keeps its fieldset '$($m.fieldset.name)' (fields added there)"
}

Write-Host "`nDone. $mode" -ForegroundColor Cyan
