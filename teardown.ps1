#Requires -Version 5.1
<#
.SYNOPSIS
    Tear down the entire Azure OpenVPN environment (Windows / PowerShell).
    Deletes the resource group (VM, NIC, IP, VNet, NSG, disks — everything)
    and cleans up local artifacts so the next .\deploy.ps1 starts fresh.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir     = $PSScriptRoot
$Prefix        = 'ezac'
$ResourceGroup = "$Prefix-rg"

function Write-Info { param($Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Cyan }
function Write-Err  { param($Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red; exit 1 }

# ── pre-flight checks ──────────────────────────────────────────────────────────

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Err "Azure CLI not found. Install from: https://aka.ms/install-azure-cli-windows"
}

Write-Info "Checking Azure login..."
$null = az account show 2>&1
if ($LASTEXITCODE -ne 0) { Write-Err "Not logged in. Run: az login" }
$Subscription = az account show --query name -o tsv
Write-Info "Subscription: $Subscription"

# ── show what will be deleted ──────────────────────────────────────────────────

$GroupExists = az group exists --name $ResourceGroup
if ($GroupExists -ne 'true') {
    Write-Info "Resource group '$ResourceGroup' does not exist — nothing to tear down in Azure."
} else {
    Write-Host ""
    Write-Host "Resources in '$ResourceGroup' that will be PERMANENTLY deleted:"
    az resource list --resource-group $ResourceGroup --query "[].{Name:name, Type:type}" -o table
    Write-Host ""

    $Reply = Read-Host "Delete resource group '$ResourceGroup' and ALL resources above? [y/N]"
    if ($Reply -notmatch '^(y|yes)$') {
        Write-Host "Aborted. Nothing was deleted."
        exit 0
    }

    Write-Info "Deleting resource group '$ResourceGroup' (takes a few minutes)..."
    az group delete --name $ResourceGroup --yes --output none
    if ($LASTEXITCODE -ne 0) { Write-Err "Failed to delete resource group '$ResourceGroup'." }
    Write-Info "Resource group deleted."
}

# ── local cleanup ──────────────────────────────────────────────────────────────

# The client profile hard-codes the old VM's IP — useless after teardown.
$OvpnLocal = Join-Path $ScriptDir 'client.ovpn'
if (Test-Path $OvpnLocal) {
    Write-Info "Removing stale local client.ovpn (it points at the deleted VM)..."
    Remove-Item -Force $OvpnLocal
}

# Host keys of the deleted VM; the next deploy records fresh ones.
Remove-Item -Force -ErrorAction SilentlyContinue `
    "$env:USERPROFILE\.ssh\${Prefix}_known_hosts", `
    "$env:USERPROFILE\.ssh\${Prefix}_known_hosts.old"

# The SSH key pair (~\.ssh\ezac_id_rsa) is kept on purpose: deploy.ps1
# reuses it, and it is useless without a VM that trusts it.

Write-Host ""
Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host " Teardown complete."                                      -ForegroundColor Green
Write-Host ""
Write-Host " To redeploy from scratch:  .\deploy.ps1"
Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Green
