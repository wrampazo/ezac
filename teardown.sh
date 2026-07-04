#!/usr/bin/env bash
# Tear down the entire Azure OpenVPN environment (macOS/Linux).
# Deletes the resource group (VM, NIC, IP, VNet, NSG, disks — everything)
# and cleans up local artifacts so the next ./deploy.sh starts fresh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="ezac"
RESOURCE_GROUP="${PREFIX}-rg"

info()  { echo "[INFO]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

# ── pre-flight checks ──────────────────────────────────────────────────────────

command -v az &>/dev/null || error "'az' is not installed. Install the Azure CLI: https://aka.ms/install-azure-cli"

info "Checking Azure login..."
az account show --output none 2>/dev/null || error "Not logged in. Run: az login"
SUBSCRIPTION=$(az account show --query name -o tsv)
info "Subscription: $SUBSCRIPTION"

# ── show what will be deleted ──────────────────────────────────────────────────

if [[ "$(az group exists --name "$RESOURCE_GROUP")" != "true" ]]; then
  info "Resource group '$RESOURCE_GROUP' does not exist — nothing to tear down in Azure."
else
  echo ""
  echo "Resources in '$RESOURCE_GROUP' that will be PERMANENTLY deleted:"
  az resource list --resource-group "$RESOURCE_GROUP" \
    --query "[].{Name:name, Type:type}" -o table
  echo ""

  read -rp "Delete resource group '$RESOURCE_GROUP' and ALL resources above? [y/N] " REPLY
  case "$REPLY" in
    y|Y|yes|YES) ;;
    *) echo "Aborted. Nothing was deleted."; exit 0 ;;
  esac

  info "Deleting resource group '$RESOURCE_GROUP' (takes a few minutes)..."
  az group delete --name "$RESOURCE_GROUP" --yes --output none
  info "Resource group deleted."
fi

# ── local cleanup ──────────────────────────────────────────────────────────────

# The client profile hard-codes the old VM's IP — useless after teardown.
if [[ -f "$SCRIPT_DIR/client.ovpn" ]]; then
  info "Removing stale local client.ovpn (it points at the deleted VM)..."
  rm -f "$SCRIPT_DIR/client.ovpn"
fi

# Host keys of the deleted VM; the next deploy records fresh ones.
rm -f "$HOME/.ssh/${PREFIX}_known_hosts" "$HOME/.ssh/${PREFIX}_known_hosts.old"

# The SSH key pair (~/.ssh/ezac_id_rsa) is kept on purpose: deploy.sh
# reuses it, and it is useless without a VM that trusts it.

echo ""
echo "════════════════════════════════════════════════════════"
echo " Teardown complete."
echo ""
echo " To redeploy from scratch:  ./deploy.sh"
echo "════════════════════════════════════════════════════════"
