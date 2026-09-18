# ================================
# Snipe-IT Auto-Registration (TESTING VERSION)
# - NOT for production / USB deployment
# - API token is loaded from a local .env file (excluded from git, never deployed)
# - No automatic checkout: asset is created/updated and left unassigned
# - Robust status-label handling (find, update, fallback create)
# - Category: Notebook / Desktop (auto-detected)
# - Manufacturer via WMI (find-or-create)
# - Custom fields: only sent if present in the model's fieldset
# ================================

# ==== CONFIG ====
$SnipeUrl = "https://snipe-it.cci.drexel.edu"

function Get-EnvValue {
    # Reads a single KEY=value line out of a local .env file.
    # Testing convenience only -- not part of the eventual secure-retrieval design.
    param(
        [Parameter(Mandatory)][string] $Key,
        [string] $EnvPath = ".\.env"
    )
    if (-not (Test-Path $EnvPath)) {
        throw "Could not find .env file at '$EnvPath'."
    }
    $line = (Select-String -Path $EnvPath -Pattern "^$Key\s*=").Line
    if (-not $line) {
        throw "Key '$Key' not found in '$EnvPath'."
    }
    $value = ($line -split '=', 2 | Select-Object -Last 1)
    return $value.Trim().Trim('"').Trim("'")
}

$ApiToken = Get-EnvValue -Key "snipe-it_api_key"

$CategoryNameNotebook = "Laptop"
$CategoryNameDesktop  = "Desktop/Stationary/AIO"
# $CategoryNameServer   = "Server"
$DesiredDeployLabelName = "Loaner Equipment"              # preferred name (will try to use)
$FallbackNewLabelName   = "Loaner Equipment" # created if nothing suitable exists

$CompanyId  = $null
$LocationId = $null
$UseManufacturerFromWmi = $true

# Known custom fields (only sent if present in the model's fieldset)
$CF_DEVICE_NAME = "_snipeit_geratename_9"
$CF_SERIAL_OPT  = "_snipeit_seriennummer_10"

# ==== HTTP ====
$Headers = @{
  "Authorization" = "Bearer $ApiToken"
  "Accept"        = "application/json"
  "Content-Type"  = "application/json"
}

function Invoke-SnipeApi {
  param(
    [Parameter(Mandatory)][ValidateSet("GET","POST","PATCH","PUT","DELETE")] [string] $Method,
    [Parameter(Mandatory)] [string] $Endpoint,
    [hashtable] $Body = $null
  )
  $uri = "$SnipeUrl/api/v1/$Endpoint"
  Write-Host "API $Method $Endpoint" -ForegroundColor Cyan
  try {
    if ($Body) {
      $json = ($Body | ConvertTo-Json -Depth 7)
      Write-Host "Body: $json" -ForegroundColor DarkGray
      $resp = Invoke-RestMethod -Method $Method -Uri $uri -Headers $Headers -Body $json -ErrorAction Stop
    } else {
      $resp = Invoke-RestMethod -Method $Method -Uri $uri -Headers $Headers -ErrorAction Stop
    }
    if ($resp.status -or $resp.messages) {
      Write-Host ("Result: status={0} messages={1}" -f $resp.status, (($resp.messages -join " | "))) -ForegroundColor Yellow
    }
    return $resp
  } catch {
    Write-Warning "API error $Method $Endpoint : $($_.Exception.Message)"
    if ($_.Exception.Response -and $_.Exception.Response.GetResponseStream()) {
      $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
      $respText = $sr.ReadToEnd()
      Write-Warning "Response body: $respText"
    }
    throw
  }
}

# ==== Utils ====
function Get-EntityIdFromResponse {
  param([Parameter(Mandatory)] $Response)
  if ($Response.id) { return [int]$Response.id }
  if ($Response.payload -and $Response.payload.id) { return [int]$Response.payload.id }
  return $null
}

# ==== System info ====
$Hostname = $env:COMPUTERNAME
$Username = $env:USERNAME  # kept for logging only -- no longer used for checkout

$Bios   = Get-CimInstance -Class Win32_BIOS -ErrorAction SilentlyContinue
$Serial = ($Bios.SerialNumber | ForEach-Object { $_.Trim() }) -join ""
if (-not $Serial) { throw "Could not determine serial number." }

$CS          = Get-CimInstance -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
$ModelNumber = ($CS.Model | ForEach-Object { $_.Trim() }) -join ""
if (-not $ModelNumber) { $ModelNumber = "Unknown model" }

$WmiManufacturer = ($CS.Manufacturer | ForEach-Object { $_.Trim() }) -join ""
if (-not $WmiManufacturer) { $WmiManufacturer = "Unknown" }
switch -Regex ($WmiManufacturer) {
  "^(Hewlett Packard Enterprise|HPE)$"  { $WmiManufacturer = "HPE"; break }
  "^(Hewlett-Packard|Hewlett Packard)$" { $WmiManufacturer = "HP"; break }
  "^(Dell).*"     { $WmiManufacturer = "Dell"; break }
  "^(Lenovo).*"   { $WmiManufacturer = "Lenovo"; break }
  default { }
}

$Enclosure    = Get-CimInstance -Class Win32_SystemEnclosure -ErrorAction SilentlyContinue
$ChassisTypes = if ($Enclosure.ChassisTypes) { $Enclosure.ChassisTypes } else { @() }
$IsNotebook   = $false
if ($ChassisTypes) { $IsNotebook = $ChassisTypes | Where-Object { $_ -in 8,9,10,14 } | ForEach-Object { $true } | Select-Object -First 1 }
if (-not $ChassisTypes) { if (Get-CimInstance -Class Win32_Battery -ErrorAction SilentlyContinue) { $IsNotebook = $true } }
# $IsServerModel = $false
# if ($ModelNumber -match '(ProLiant|PowerEdge|ThinkSystem|PRIMERGY|ThinkServer)') { $IsServerModel = $true }

# Model name is the actual WMI model string (e.g. "Latitude 3400", "OptiPlex 7000 Micro"),
# not a generic Notebook/Desktop bucket -- matches how models are named in this Snipe-IT instance.
$ModelName = $ModelNumber
Write-Host "Detected -> Name: $Hostname | SN: $Serial | Model number: $ModelNumber | Manufacturer: $WmiManufacturer | User: $Username" -ForegroundColor Green

# ==== API helpers ====
function FindOrCreateCategory {
  param([string] $Name)
  $res = Invoke-SnipeApi -Method GET -Endpoint ("categories?search={0}&limit=100" -f [uri]::EscapeDataString($Name))
  $cat = $null
  if ($res.total -gt 0) { $cat = $res.rows | Where-Object { $_.name -eq $Name } | Select-Object -First 1 }
  if ($cat) { return $cat }
  return Invoke-SnipeApi -Method POST -Endpoint "categories" -Body @{ name = $Name; category_type = "asset" }
}

function FindOrCreateManufacturer {
  param([string] $Name)
  if ([string]::IsNullOrWhiteSpace($Name) -or $Name -eq "Unknown") { return $null }
  $res = Invoke-SnipeApi -Method GET -Endpoint ("manufacturers?search={0}&limit=100" -f [uri]::EscapeDataString($Name))
  $m = $null
  if ($res.total -gt 0) {
    $m = $res.rows | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if (-not $m) { $m = $res.rows | Select-Object -First 1 }
  }
  if ($m) { return $m }
  return Invoke-SnipeApi -Method POST -Endpoint "manufacturers" -Body @{ name = $Name }
}

# Finds a deployable status label; repairs/creates one if needed
function FindOrCreateDeployableStatusLabel {
  param([string] $PreferredName, [string] $NewNameIfNeeded)

  function Test-IsDeployable($lbl) {
    if ($null -eq $lbl) { return $false }
    if ($lbl.PSObject.Properties.Name -contains 'status_type' -and $lbl.status_type -eq 'deployable') { return $true }
    if ($lbl.PSObject.Properties.Name -contains 'type'        -and $lbl.type        -eq 'deployable') { return $true }
    if ($lbl.PSObject.Properties.Name -contains 'deployable'  -and $lbl.deployable  -eq $true)        { return $true }
    return $false
  }

  function Try-UpdateToDeployable($id, $name) {
    try {
      $null = Invoke-SnipeApi -Method PUT -Endpoint ("statuslabels/{0}" -f $id) -Body @{ name = $name; status_type = "deployable" }
      return $true
    } catch { Write-Warning "PUT status_type failed: $($_.Exception.Message)" }

    try {
      $null = Invoke-SnipeApi -Method PUT -Endpoint ("statuslabels/{0}" -f $id) -Body @{ name = $name; type = "deployable" }
      return $true
    } catch { Write-Warning "PUT type=deployable failed: $($_.Exception.Message)" }

    try {
      $null = Invoke-SnipeApi -Method PATCH -Endpoint ("statuslabels/{0}" -f $id) -Body @{ deployable = $true; pending = $false; archived = $false }
      return $true
    } catch { Write-Warning "PATCH deployable/pending/archived failed: $($_.Exception.Message)" }

    return $false
  }

  function Try-CreateDeployable {
    param([string] $name)
    try {
      return Invoke-SnipeApi -Method POST -Endpoint "statuslabels" -Body @{ name = $name; status_type = "deployable" }
    } catch { Write-Warning "POST status_type=deployable failed: $($_.Exception.Message)" }
    try {
      return Invoke-SnipeApi -Method POST -Endpoint "statuslabels" -Body @{ name = $name; type = "deployable" }
    } catch { Write-Warning "POST type=deployable failed: $($_.Exception.Message)" }
    try {
      return Invoke-SnipeApi -Method POST -Endpoint "statuslabels" -Body @{ name = $name; deployable = $true; pending = $false; archived = $false }
    } catch { Write-Warning "POST legacy flags failed: $($_.Exception.Message)" }
    return $null
  }

  # 1) Try the preferred name first
  $res = Invoke-SnipeApi -Method GET -Endpoint ("statuslabels?search={0}&limit=100" -f [uri]::EscapeDataString($PreferredName))
  if ($res.total -gt 0) {
    $label = $res.rows | Where-Object { $_.name -eq $PreferredName } | Select-Object -First 1
    if ($label -and (Test-IsDeployable $label)) { return $label }
    if ($label -and -not (Test-IsDeployable $label)) {
      if (Try-UpdateToDeployable -id $label.id -name $label.name) {
        $refreshed = Invoke-SnipeApi -Method GET -Endpoint ("statuslabels/{0}" -f $label.id)
        if (Test-IsDeployable $refreshed) { return $refreshed }
      }
      return $label
    }
  }

  # 2) Find any existing deployable label
  $all = Invoke-SnipeApi -Method GET -Endpoint "statuslabels?limit=100"
  if ($all.total -gt 0) {
    $deploy = $all.rows | Where-Object { Test-IsDeployable $_ } | Select-Object -First 1
    if ($deploy) { return $deploy }
  }

  # 3) Nothing found -> create one (tries all variants)
  Write-Host "No deployable status label found -> creating '$NewNameIfNeeded'..." -ForegroundColor Magenta
  $created = Try-CreateDeployable -name $NewNameIfNeeded
  if ($created -and (Test-IsDeployable $created)) { return $created }

  throw "Could not determine or create a deployable status label."
}

function FindOrCreateModel {
  param(
    [string] $Name, [string] $ModelNumber, [int] $CategoryId, [int] $ManufacturerId = $null
  )

  # Try to search by model name first
  $resName = Invoke-SnipeApi -Method GET -Endpoint ("models?limit=100&search={0}" -f [uri]::EscapeDataString($Name))
  if ($resName.total -gt 0) {
    $hit = $resName.rows | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($hit) {
      Write-Host "Found existing model by name: $($hit.name) (ID $($hit.id))" -ForegroundColor Green
      return $hit
    }
  }

  # If no model is found by name, create a new one
  Write-Host "No model found with name '$Name' - creating new model..." -ForegroundColor Magenta
  $body = @{ name=$Name; model_number=$ModelNumber; category_id=$CategoryId }
  if ($ManufacturerId) { $body.manufacturer_id = [int]$ManufacturerId }
  $created = $null
  try {
    $created = Invoke-SnipeApi -Method POST -Endpoint "models" -Body $body
  } catch {
    Write-Warning "Model creation failed. Verifying via lookup..."
  }
  if ($created) {
    $newId = Get-EntityIdFromResponse -Response $created
    if ($newId) {
      $full = Invoke-SnipeApi -Method GET -Endpoint ("models/{0}" -f $newId)
      if ($full -and $full.id) { return $full }
    }
  }
  $res2 = Invoke-SnipeApi -Method GET -Endpoint ("models?limit=100&search={0}" -f [uri]::EscapeDataString($ModelNumber))
  if ($res2.total -gt 0) {
    $mdl = $res2.rows | Where-Object { $_.model_number -eq $ModelNumber } | Select-Object -First 1
    if ($mdl) { return $mdl }
  }
  # broader search fallback
  $res3 = Invoke-SnipeApi -Method GET -Endpoint ("models?limit=100&search={0}" -f [uri]::EscapeDataString(($ModelNumber -split '\s+')[0]))
  if ($res3.total -gt 0) {
    $mdl = $res3.rows | Where-Object { $_.model_number -eq $ModelNumber } | Select-Object -First 1
    if ($mdl) { return $mdl }
  }
  throw "Could not find/create a matching model (Name='$Name' ModelNumber='$ModelNumber')."
}

function GetModelFieldsetColumns {
  param([int] $ModelId)
  # Fetches the fieldset columns (db_column) for this model
  $full = Invoke-SnipeApi -Method GET -Endpoint ("models/{0}" -f $ModelId)
  $cols = @()
  if ($full -and $full.fieldset -and $full.fieldset.fields) {
    $cols = $full.fieldset.fields | ForEach-Object { $_.db_column } | Where-Object { $_ }
  }
  return $cols
}

function GetAssetBySerial {
  param([string] $Serial)
  try {
    $res = Invoke-SnipeApi -Method GET -Endpoint ("hardware/byserial/{0}" -f [uri]::EscapeDataString($Serial))
    if ($res -and $res.id) { return $res }
  } catch { }
  $res2 = Invoke-SnipeApi -Method GET -Endpoint ("hardware?search={0}&limit=50" -f [uri]::EscapeDataString($Serial))
  if ($res2.total -gt 0) { return $res2.rows | Where-Object { $_.serial -eq $Serial } | Select-Object -First 1 }
  return $null
}

function CreateOrUpdateAsset {
  # No checkout: asset is created/updated and left unassigned.
  param([string] $Name, [string] $Serial, [int] $ModelId, [int] $StatusId)

  # Only send custom fields that this model's fieldset actually has
  $allowedCF = @(GetModelFieldsetColumns -ModelId $ModelId)
  $custom = @{}
  if ($allowedCF -contains $CF_DEVICE_NAME) { $custom[$CF_DEVICE_NAME] = $Name }
  if ($allowedCF -contains $CF_SERIAL_OPT)  { $custom[$CF_SERIAL_OPT]  = $Serial }

  $existing = GetAssetBySerial -Serial $Serial
  if ($existing) {
    Write-Host "Asset with SN '$Serial' already exists (ID $($existing.id)) -- updating..." -ForegroundColor Green
    $updBody = @{ name=$Name; model_id=[int]$ModelId; status_id=[int]$StatusId } + $custom
    if ($CompanyId)  { $updBody.company_id  = [int]$CompanyId }
    if ($LocationId) { $updBody.location_id = [int]$LocationId }
    $ru = Invoke-SnipeApi -Method PATCH -Endpoint ("hardware/{0}" -f $existing.id) -Body $updBody
    if ($ru.status -and $ru.status -ne "success") { throw "Update failed: $($ru | ConvertTo-Json -Depth 7)" }
    return GetAssetBySerial -Serial $Serial
  } else {
    Write-Host "Creating new asset..." -ForegroundColor Green
    $body = @{ name=$Name; serial=$Serial; model_id=[int]$ModelId; status_id=[int]$StatusId } + $custom
    if ($CompanyId)  { $body.company_id  = [int]$CompanyId }
    if ($LocationId) { $body.location_id = [int]$LocationId }

    $created = Invoke-SnipeApi -Method POST -Endpoint "hardware" -Body $body
    if ($created.status -and $created.status -ne "success") { throw "Creation failed: $($created | ConvertTo-Json -Depth 7)" }
    $assetId = Get-EntityIdFromResponse -Response $created
    if (-not $assetId) {
      # Fallback: look it up by serial
      $ref = GetAssetBySerial -Serial $Serial
      if ($ref -and $ref.id) { $assetId = [int]$ref.id }
    }
    if (-not $assetId) { throw "Creation returned no asset ID and lookup failed: $($created | ConvertTo-Json -Depth 7)" }

    return GetAssetBySerial -Serial $Serial
  }
}

# ==== Main flow ====
$status = FindOrCreateDeployableStatusLabel -PreferredName $DesiredDeployLabelName -NewNameIfNeeded $FallbackNewLabelName

$statusInfo = ""
if ($null -ne $status.status_type -and $status.status_type -ne "") {
    $statusInfo = "type=$($status.status_type)"
} elseif ($status.PSObject.Properties.Name -contains 'deployable') {
    $statusInfo = "deployable=$($status.deployable)"
}
Write-Host "Deployable status label: $($status.name) (ID $($status.id)) $statusInfo" -ForegroundColor Green

$catName = if ($IsNotebook) { $CategoryNameNotebook } else { $CategoryNameDesktop }
$cat = FindOrCreateCategory -Name $catName
Write-Host "Category: $($cat.name) (ID $($cat.id))" -ForegroundColor Green

$manuId = $null
if ($UseManufacturerFromWmi -and $WmiManufacturer -and $WmiManufacturer -ne "Unknown") {
  $manu = FindOrCreateManufacturer -Name $WmiManufacturer
  if ($manu -and $manu.id) {
    $manuId = [int]$manu.id
    Write-Host "Manufacturer: $($manu.name) (ID $($manu.id))" -ForegroundColor Green
  }
}

$model = FindOrCreateModel -Name $ModelName -ModelNumber $ModelNumber -CategoryId ([int]$cat.id) -ManufacturerId $manuId
Write-Host "Model: $($model.name) ($($model.model_number)) (ID $($model.id))" -ForegroundColor Green

$response = Read-Host -Prompt "The following asset will be created/updated: $Hostname | $Serial | $ModelName | $ModelNumber | $WmiManufacturer. Continue? (y/n)"
if ($response -ne "y") {
  Write-Host "Aborted." -ForegroundColor Red
  exit 1
}
$asset = CreateOrUpdateAsset -Name $Hostname -Serial $Serial -ModelId ([int]$model.id) -StatusId ([int]$status.id)

Write-Host "Done. Asset ID: $($asset.id) | Name: $($asset.name) | Left unassigned (no auto-checkout)." -ForegroundColor Green
Write-Host "Direct link: $SnipeUrl/hardware/$($asset.id)"