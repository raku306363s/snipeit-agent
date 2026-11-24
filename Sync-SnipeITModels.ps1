<#
.SYNOPSIS
    Cleans up asset models using the real hardware model the agents report.

.DESCRIPTION
    Every agent writes the device's real manufacturer and model into the "Hardware Model"
    field (e.g. "Dell Vostro 15 3510", "Lenovo ideapad 330-15IKB", "Apple Mac mini M4").
    This script groups assets by that value and moves each asset to one correct model:

      - If a model with that name already exists (ignoring case and spaces), it is reused.
      - Otherwise a model is created with the right manufacturer, the asset's current
        category and the "Inventory Agent" fieldset.
      - With -DeleteEmpty, models that this run left with no assets are deleted.
        Snipe-IT itself refuses to delete a model that still has assets.

    Assets whose agent hasn't reported yet are left alone, so it is safe to run while
    the rollout is still in progress and run again later.

    DRY RUN by default: it prints the plan and writes it to a CSV. Add -Apply to make
    the changes. Use an admin API token (prompted, or env var SNIPEIT_ADMIN_TOKEN).

.EXAMPLE
    .\Sync-SnipeITModels.ps1 -SnipeUrl http://192.168.1.35
    .\Sync-SnipeITModels.ps1 -SnipeUrl http://192.168.1.35 -Apply -DeleteEmpty
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SnipeUrl,
    [string]$CategoryPattern = 'Laptop|Desktop|PC|Computer|Workstation',
    [string]$FieldName = 'Hardware Model',
    [string]$FieldsetName = 'Inventory Agent',
    [string]$ReportPath = (Join-Path (Get-Location) 'model-cleanup-plan.csv'),
    [switch]$DeleteEmpty,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$SnipeUrl = $SnipeUrl.TrimEnd('/')
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
$Token = $env:SNIPEIT_ADMIN_TOKEN
if (-not $Token) {
    $sec = Read-Host -AsSecureString 'Snipe-IT admin API token'
    $Token = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}

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

function Get-Key([string]$s) { ([Net.WebUtility]::HtmlDecode($s) -replace '\s+', ' ').Trim().ToLowerInvariant() }
function Decode([string]$s) { ([Net.WebUtility]::HtmlDecode($s) -replace '\s+', ' ').Trim() }

$mode = if ($Apply) { 'APPLY' } else { 'DRY RUN (add -Apply to make changes)' }
Write-Host "Snipe-IT: $SnipeUrl   Mode: $mode`n" -ForegroundColor Cyan

# --- Load ------------------------------------------------------------------
$models = @(Get-All 'models')
$manufacturers = @(Get-All 'manufacturers')
$fieldset = @(Get-All 'fieldsets') | Where-Object { $_.name -eq $FieldsetName } | Select-Object -First 1
if (-not $fieldset) { throw "Fieldset '$FieldsetName' not found. Run Setup-SnipeITFields.ps1 first." }
$assets = @(Get-All 'hardware') | Where-Object { $_.category -and $_.category.name -match $CategoryPattern }
Write-Host "$($assets.Count) assets in categories matching '$CategoryPattern', $($models.Count) models`n"

$modelsByKey = @{}
foreach ($m in $models) {
    $k = Get-Key $m.name
    # Prefer the model with the most assets when names collide.
    if (-not $modelsByKey.ContainsKey($k) -or [int]$m.assets_count -gt [int]$modelsByKey[$k].assets_count) { $modelsByKey[$k] = $m }
}
$mfrByKey = @{}
foreach ($m in $manufacturers) { $mfrByKey[(Get-Key $m.name)] = $m }

# --- Plan ------------------------------------------------------------------
$plan = New-Object System.Collections.Generic.List[object]
$notReported = 0
foreach ($a in $assets) {
    $hw = ''
    if ($a.custom_fields -and $a.custom_fields.PSObject.Properties.Name -contains $FieldName) {
        $hw = Decode ([string]$a.custom_fields.$FieldName.value)
    }
    if (-not $hw) { $notReported++; continue }
    $parts = $hw.Split(' ', 2)
    $mfrName = $parts[0]
    $modelName = if ($parts.Count -gt 1) { $parts[1] } else { $hw }
    $current = Decode ([string]$a.model.name)
    if ((Get-Key $current) -eq (Get-Key $modelName)) { continue }   # already right
    $plan.Add([pscustomobject]@{
        AssetId      = $a.id
        AssetTag     = $a.asset_tag
        Serial       = $a.serial
        Category     = $a.category.name
        CategoryId   = $a.category.id
        CurrentModel = $current
        CurrentModelId = $a.model.id
        Manufacturer = $mfrName
        NewModel     = $modelName
        Action       = if ($modelsByKey.ContainsKey((Get-Key $modelName))) { 'move to existing model' } else { 'move to new model' }
        Result       = ''
    })
}

if ($plan.Count -eq 0) {
    Write-Host "Nothing to change. $notReported assets have no '$FieldName' yet (agent not installed or not reported)."
    return
}

foreach ($g in ($plan | Group-Object CurrentModel | Sort-Object Name)) {
    Write-Host ("  {0}  ({1} assets to move)" -f $g.Name, $g.Count) -ForegroundColor White
    foreach ($t in ($g.Group | Group-Object Manufacturer, NewModel, Action | Sort-Object Name)) {
        $f = $t.Group[0]
        Write-Host ("      -> {0} {1}  x{2}  [{3}]" -f $f.Manufacturer, $f.NewModel, $t.Count, $f.Action)
    }
}
$newModels = @($plan | Where-Object Action -eq 'move to new model' | ForEach-Object { "$($_.Manufacturer)|$($_.NewModel)" } | Sort-Object -Unique)
Write-Host "`n$($plan.Count) assets to move, $($newModels.Count) new models to create, $notReported assets not reported yet (left alone)."

if (-not $Apply) {
    $plan | Select-Object AssetTag, Serial, Category, CurrentModel, Manufacturer, NewModel, Action |
        Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8
    Write-Host "Plan saved to $ReportPath. Review it, then rerun with -Apply (and -DeleteEmpty to remove emptied models)." -ForegroundColor Yellow
    return
}

# --- Apply -----------------------------------------------------------------
function Get-ManufacturerId([string]$Name) {
    $k = Get-Key $Name
    if ($mfrByKey.ContainsKey($k)) { return [int]$mfrByKey[$k].id }
    $r = Invoke-Snipe POST 'manufacturers' @{ name = $Name }
    $m = [pscustomobject]@{ id = [int]$r.payload.id; name = $Name }
    $mfrByKey[$k] = $m
    Write-Host "  manufacturer created: $Name" -ForegroundColor Green
    return $m.id
}

$touchedModelIds = @{}
foreach ($p in $plan) {
    try {
        $k = Get-Key $p.NewModel
        if (-not $modelsByKey.ContainsKey($k)) {
            $body = @{
                name            = $p.NewModel
                model_number    = $p.NewModel
                category_id     = [int]$p.CategoryId
                manufacturer_id = Get-ManufacturerId $p.Manufacturer
                fieldset_id     = [int]$fieldset.id
            }
            $r = Invoke-Snipe POST 'models' $body
            $modelsByKey[$k] = [pscustomobject]@{ id = [int]$r.payload.id; name = $p.NewModel; assets_count = 0 }
            Write-Host "  model created: $($p.Manufacturer) $($p.NewModel)" -ForegroundColor Green
        }
        $null = Invoke-Snipe PATCH "hardware/$($p.AssetId)" @{ model_id = [int]$modelsByKey[$k].id }
        $touchedModelIds[[int]$p.CurrentModelId] = $p.CurrentModel
        $p.Result = 'moved'
        Write-Host "  $($p.AssetTag): $($p.CurrentModel) -> $($p.NewModel)"
    } catch {
        $p.Result = 'FAILED: ' + ($_.Exception.Message -replace '^.*? : ', '')
        Write-Host "  FAILED $($p.AssetTag): $($p.Result)" -ForegroundColor Red
    }
}

if ($DeleteEmpty -and $touchedModelIds.Count -gt 0) {
    Write-Host "`nDeleting models this run emptied:"
    foreach ($id in $touchedModelIds.Keys) {
        try {
            $m = Invoke-Snipe GET "models/$id"
            if ([int]$m.assets_count -gt 0) {
                Write-Host "  kept '$($touchedModelIds[$id])': still has $($m.assets_count) assets"
                continue
            }
            $null = Invoke-Snipe DELETE "models/$id"
            Write-Host "  deleted '$($touchedModelIds[$id])'" -ForegroundColor Green
        } catch {
            Write-Host "  could not delete '$($touchedModelIds[$id])': $($_.Exception.Message -replace '^.*? : ', '')" -ForegroundColor Red
        }
    }
}

$plan | Select-Object AssetTag, Serial, Category, CurrentModel, Manufacturer, NewModel, Action, Result |
    Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8
$failed = @($plan | Where-Object { $_.Result -like 'FAILED*' }).Count
Write-Host "`nDone. Moved $($plan.Count - $failed), failed $failed. Results saved to $ReportPath" -ForegroundColor Cyan
