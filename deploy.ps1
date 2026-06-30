#Requires -Version 5.1
<#
.SYNOPSIS
    Deploy a secure Azure VM running OpenVPN (Windows / PowerShell + Bicep).
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir  = $PSScriptRoot
$Prefix     = 'ezac'
$ResourceGroup = "$Prefix-rg"
$DeployName = "$Prefix-deploy-$(Get-Date -Format 'yyyyMMddHHmmss')"

# ── helpers ────────────────────────────────────────────────────────────────────

function Write-Info  { param($Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Cyan }
function Write-Err   { param($Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red; exit 1 }

# ── pre-flight checks ──────────────────────────────────────────────────────────

Write-Info "Checking for Azure CLI..."
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Err "Azure CLI not found. Install from: https://aka.ms/install-azure-cli-windows"
}

Write-Info "Checking Azure login..."
try {
    $null = az account show 2>&1
} catch {
    Write-Err "Not logged in. Run: az login"
}
$Subscription = az account show --query name -o tsv
Write-Info "Subscription: $Subscription"

Write-Info "Installing/updating Bicep..."
az bicep install 2>$null; az bicep upgrade 2>$null

# Resource providers must be registered once per subscription before their
# resources can be deployed. This is idempotent and safe to re-run.
Write-Info "Ensuring required resource providers are registered..."
foreach ($Ns in @('Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage')) {
    $State = (az provider show --namespace $Ns --query registrationState -o tsv 2>$null)
    if ($State -ne 'Registered') {
        Write-Info "  Registering $Ns (this can take 1-2 minutes)..."
        az provider register --namespace $Ns --wait
        if ($LASTEXITCODE -ne 0) { Write-Err "Failed to register resource provider '$Ns'." }
    }
}

# ── region selection ───────────────────────────────────────────────────────────

Write-Info "Fetching available Azure regions..."
$Regions = (az account list-locations --query "[].name" -o tsv) -split "`n" | Sort-Object

Write-Host ""
Write-Host "Available regions:"
for ($i = 0; $i -lt $Regions.Count; $i++) {
    Write-Host ("  {0,3}) {1}" -f ($i + 1), $Regions[$i])
}
Write-Host ""

$Location = $null
do {
    $Input = Read-Host "Enter region number"
    if ($Input -match '^\d+$') {
        $Num = [int]$Input
        if ($Num -ge 1 -and $Num -le $Regions.Count) {
            $Location = $Regions[$Num - 1]
        }
    }
    if (-not $Location) { Write-Host "Invalid selection. Enter a number between 1 and $($Regions.Count)." }
} while (-not $Location)

Write-Info "Selected region: $Location"

# ── VM size selection ─────────────────────────────────────────────────────────

Write-Info "Finding an available VM size in '$Location' (one moment)..."
# Preferred order: cheapest first. Default list-skus (no --all) already
# excludes capacity/subscription-restricted sizes, so anything returned is deployable.
$PreferredSizes = @(
    "Standard_B1s",    "Standard_B1ms",   "Standard_B2s",    "Standard_B2ms",
    "Standard_B4ms",   "Standard_A1_v2",  "Standard_A2_v2",  "Standard_F1s",
    "Standard_F2s_v2", "Standard_D2s_v3", "Standard_D2as_v4","Standard_D2s_v4",
    "Standard_D2s_v5", "Standard_E2s_v3", "Standard_DS1_v2"
)

# Single API call: list all VM sizes usable in this region for this subscription.
$AvailableSizes = (az vm list-skus `
    --location $Location `
    --resource-type virtualMachines `
    --query "[].name" -o tsv 2>$null) -split "`n" | ForEach-Object { $_.Trim() }
if (-not $AvailableSizes) { Write-Err "Could not retrieve VM sizes for '$Location'. Check your Azure access and try again." }

$VmSize = $null
foreach ($Size in $PreferredSizes) {
    if ($AvailableSizes -contains $Size) { $VmSize = $Size; break }
}
if (-not $VmSize) {
    $Suggestions = ($AvailableSizes | Where-Object { $_ -match 'Standard_(B|D[0-9]|DS[0-9]|F[0-9])' } | Select-Object -First 8) -join " "
    Write-Err "None of the preferred sizes are available in '$Location'.`n  Some sizes that ARE available here: $Suggestions`n  Re-run, pick a different region, or add one of the above to `$PreferredSizes."
}
Write-Info "VM size: $VmSize"
Write-Info "VM size: $VmSize"

# ── credentials ───────────────────────────────────────────────────────────────

Write-Host ""
do {
    $VpnUser = Read-Host "OpenVPN username"
} while ([string]::IsNullOrWhiteSpace($VpnUser))

do {
    $VpnPass1 = Read-Host "OpenVPN password" -AsSecureString
    $VpnPass2 = Read-Host "Confirm password" -AsSecureString
    $Plain1   = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($VpnPass1))
    $Plain2   = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
                    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($VpnPass2))
    if ($Plain1 -ne $Plain2 -or [string]::IsNullOrEmpty($Plain1)) {
        Write-Host "Passwords do not match or are empty. Try again."
    }
} while ($Plain1 -ne $Plain2 -or [string]::IsNullOrEmpty($Plain1))

$VpnPass = $Plain1

# ── SSH key ───────────────────────────────────────────────────────────────────

$SshKeyPath = "$env:USERPROFILE\.ssh\${Prefix}_id_rsa"
if (-not (Test-Path "${SshKeyPath}.pub")) {
    Write-Info "Generating SSH key pair at $SshKeyPath..."
    ssh-keygen -t rsa -b 4096 -f $SshKeyPath -N '""' -C "${Prefix}-vm"
}
$SshPublicKey = Get-Content "${SshKeyPath}.pub" -Raw
Write-Info "Using SSH public key: ${SshKeyPath}.pub"

# ── cloud-init ────────────────────────────────────────────────────────────────

Write-Info "Preparing cloud-init configuration..."
$CloudInitFile = Join-Path $ScriptDir 'cloud-init.yaml'
if (-not (Test-Path $CloudInitFile)) { Write-Err "cloud-init.yaml not found at $CloudInitFile" }

$CloudInitContent = Get-Content $CloudInitFile -Raw

# Base64-encode credentials so any special characters survive YAML injection
# and shell handling on the VM unchanged. base64 output is always YAML-safe.
$VpnUserB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($VpnUser))
$VpnPassB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($VpnPass))

# Inject the encoded credentials into cloud-init's write_files section
$ExtraWrites = @"

  - path: /root/.vpn_user.b64
    content: "$VpnUserB64"
    owner: root:root
    permissions: '0600'

  - path: /root/.vpn_pass.b64
    content: "$VpnPassB64"
    owner: root:root
    permissions: '0600'
"@

if ($CloudInitContent -notmatch 'write_files:') {
    Write-Err "'write_files:' marker not found in cloud-init.yaml"
}
# Use a literal-text replace (avoid regex; base64 has no regex-special chars but the YAML body might)
$MergedCloudInit = $CloudInitContent -replace 'write_files:', "write_files:$ExtraWrites"
$CloudInitB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($MergedCloudInit))

# ── deploy ────────────────────────────────────────────────────────────────────

Write-Info "Creating resource group '$ResourceGroup' in '$Location'..."
az group create --name $ResourceGroup --location $Location --output none

Write-Info "Validating deployment template..."
$null = az deployment group validate `
    --resource-group $ResourceGroup `
    --template-file (Join-Path $ScriptDir 'main.bicep') `
    --parameters `
        location=$Location `
        prefix=$Prefix `
        vmSize=$VmSize `
        "adminSshPublicKey=$($SshPublicKey.Trim())" `
        cloudInitBase64=$CloudInitB64 `
    --output none
if ($LASTEXITCODE -ne 0) { Write-Err "Template validation failed. Aborting." }

Write-Info "Deploying infrastructure (this takes ~5 minutes)..."
$DeployOutput = az deployment group create `
    --resource-group $ResourceGroup `
    --name $DeployName `
    --template-file (Join-Path $ScriptDir 'main.bicep') `
    --parameters `
        location=$Location `
        prefix=$Prefix `
        vmSize=$VmSize `
        "adminSshPublicKey=$($SshPublicKey.Trim())" `
        cloudInitBase64=$CloudInitB64 `
    --output json | ConvertFrom-Json

$VmIp = $DeployOutput.properties.outputs.vmPublicIp.value

# ── output ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host " Deployment complete"                                     -ForegroundColor Green
Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host " VM Public IP : $VmIp"
Write-Host " SSH command  : ssh -i $SshKeyPath azureuser@$VmIp"
Write-Host ""
Write-Host " OpenVPN client setup:"
Write-Host "   Server   : $VmIp"
Write-Host "   Port     : 1194 / UDP"
Write-Host "   Protocol : Password authentication"
Write-Host "   Username : $VpnUser"
Write-Host "   Password : (the password you entered)"
Write-Host ""
Write-Host " Note: OpenVPN may take 2-3 minutes after first boot"
Write-Host "       to finish setup on the VM."
Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Green
