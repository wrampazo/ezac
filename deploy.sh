#!/usr/bin/env bash
# Deploy a secure Azure VM running OpenVPN (macOS/Linux)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="ezac"
RESOURCE_GROUP="${PREFIX}-rg"
DEPLOYMENT_NAME="${PREFIX}-deploy-$(date +%s)"

# ── helpers ────────────────────────────────────────────────────────────────────

info()  { echo "[INFO]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" &>/dev/null || error "'$1' is not installed. $2"
}

# ── pre-flight checks ──────────────────────────────────────────────────────────

info "Checking dependencies..."
require_cmd az   "Install the Azure CLI: https://aka.ms/install-azure-cli"
require_cmd ssh-keygen "Install OpenSSH."
require_cmd base64 ""

info "Checking Azure login..."
az account show --output none 2>/dev/null || error "Not logged in. Run: az login"
SUBSCRIPTION=$(az account show --query name -o tsv)
info "Subscription: $SUBSCRIPTION"

info "Installing/updating Bicep..."
az bicep install 2>/dev/null || az bicep upgrade 2>/dev/null || true

# Resource providers must be registered once per subscription before their
# resources can be deployed. This is idempotent and safe to re-run.
info "Ensuring required resource providers are registered..."
for ns in Microsoft.Compute Microsoft.Network Microsoft.Storage; do
  state=$(az provider show --namespace "$ns" --query registrationState -o tsv 2>/dev/null || echo "NotRegistered")
  if [[ "$state" != "Registered" ]]; then
    info "  Registering $ns (this can take 1-2 minutes)..."
    az provider register --namespace "$ns" --wait \
      || error "Failed to register resource provider '$ns'."
  fi
done

# ── region selection ───────────────────────────────────────────────────────────

info "Fetching available Azure regions..."
REGIONS=()
while IFS= read -r line; do
  REGIONS+=("$line")
done < <(az account list-locations --query "[].name" -o tsv | sort)

echo ""
echo "Available regions:"
for i in "${!REGIONS[@]}"; do
  printf "  %3d) %s\n" "$((i+1))" "${REGIONS[$i]}"
done
echo ""

while true; do
  read -rp "Enter region number: " REGION_NUM
  if [[ "$REGION_NUM" =~ ^[0-9]+$ ]] && (( REGION_NUM >= 1 && REGION_NUM <= ${#REGIONS[@]} )); then
    LOCATION="${REGIONS[$((REGION_NUM-1))]}"
    break
  fi
  echo "Invalid selection. Enter a number between 1 and ${#REGIONS[@]}."
done
info "Selected region: $LOCATION"

# ── VM size selection ─────────────────────────────────────────────────────────

info "Finding an available VM size in '$LOCATION' (one moment)..."
# Preferred order: cheapest first. Default list-skus (no --all) already
# excludes sizes that are capacity/subscription-restricted in this region,
# so anything returned here is actually deployable.
PREFERRED_SIZES=(
  "Standard_B1s"    "Standard_B1ms"   "Standard_B2s"    "Standard_B2ms"
  "Standard_B4ms"   "Standard_A1_v2"  "Standard_A2_v2"  "Standard_F1s"
  "Standard_F2s_v2" "Standard_D2s_v3" "Standard_D2as_v4" "Standard_D2s_v4"
  "Standard_D2s_v5" "Standard_E2s_v3" "Standard_DS1_v2"
)

# Single API call: list all VM sizes usable in this region for this subscription.
AVAILABLE_SIZES=$(az vm list-skus \
  --location "$LOCATION" \
  --resource-type virtualMachines \
  --query "[].name" -o tsv 2>/dev/null)
[[ -n "$AVAILABLE_SIZES" ]] || error "Could not retrieve VM sizes for '$LOCATION'. Check your Azure access and try again."

VM_SIZE=""
for size in "${PREFERRED_SIZES[@]}"; do
  if grep -qx "$size" <<< "$AVAILABLE_SIZES"; then
    VM_SIZE="$size"
    break
  fi
done
if [[ -z "$VM_SIZE" ]]; then
  SUGGESTIONS=$(grep -E 'Standard_(B|D[0-9]|DS[0-9]|F[0-9])' <<< "$AVAILABLE_SIZES" | head -8 | tr '\n' ' ')
  error "None of the preferred sizes are available in '$LOCATION'.
  Some sizes that ARE available here: $SUGGESTIONS
  Re-run, pick a different region, or add one of the above to PREFERRED_SIZES."
fi
info "VM size: $VM_SIZE"

# ── credentials ───────────────────────────────────────────────────────────────

echo ""
read -rp "OpenVPN username: " VPN_USER
while [[ -z "$VPN_USER" ]]; do
  read -rp "Username cannot be empty. OpenVPN username: " VPN_USER
done

while true; do
  read -rsp "OpenVPN password: " VPN_PASS; echo
  read -rsp "Confirm password: " VPN_PASS2; echo
  [[ "$VPN_PASS" == "$VPN_PASS2" && -n "$VPN_PASS" ]] && break
  echo "Passwords do not match or are empty. Try again."
done

# ── SSH key ───────────────────────────────────────────────────────────────────

SSH_KEY_PATH="$HOME/.ssh/${PREFIX}_id_rsa"
if [[ ! -f "${SSH_KEY_PATH}.pub" ]]; then
  info "Generating SSH key pair at ${SSH_KEY_PATH}..."
  ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -C "${PREFIX}-vm"
fi
SSH_PUBLIC_KEY=$(cat "${SSH_KEY_PATH}.pub")
info "Using SSH public key: ${SSH_KEY_PATH}.pub"

# ── cloud-init ────────────────────────────────────────────────────────────────

info "Preparing cloud-init configuration..."
CLOUD_INIT_FILE="$SCRIPT_DIR/cloud-init.yaml"
[[ -f "$CLOUD_INIT_FILE" ]] || error "cloud-init.yaml not found at $CLOUD_INIT_FILE"

# Base64-encode credentials so any special characters survive YAML injection
# and shell handling on the VM unchanged. base64 output is always YAML-safe.
VPN_USER_B64=$(printf '%s' "$VPN_USER" | base64 | tr -d '\n')
VPN_PASS_B64=$(printf '%s' "$VPN_PASS" | base64 | tr -d '\n')

# Inject the encoded credentials into cloud-init's write_files section
MERGED_CLOUD_INIT=$(
  CLOUD_INIT_FILE="$CLOUD_INIT_FILE" \
  VPN_USER_B64="$VPN_USER_B64" \
  VPN_PASS_B64="$VPN_PASS_B64" \
  python3 - <<'PYEOF'
import os

with open(os.environ['CLOUD_INIT_FILE']) as f:
    content = f.read()

user_b64 = os.environ['VPN_USER_B64']
pass_b64 = os.environ['VPN_PASS_B64']

inject = (
    "\n"
    "  - path: /root/.vpn_user.b64\n"
    f"    content: \"{user_b64}\"\n"
    "    owner: root:root\n"
    "    permissions: '0600'\n"
    "\n"
    "  - path: /root/.vpn_pass.b64\n"
    f"    content: \"{pass_b64}\"\n"
    "    owner: root:root\n"
    "    permissions: '0600'\n"
)

if "write_files:\n" not in content:
    raise SystemExit("ERROR: 'write_files:' marker not found in cloud-init.yaml")

print(content.replace("write_files:\n", "write_files:\n" + inject, 1), end="")
PYEOF
) || error "Failed to prepare cloud-init configuration."

# Use printf (not echo) so backslashes in the embedded script are never interpreted
CLOUD_INIT_B64=$(printf '%s' "$MERGED_CLOUD_INIT" | base64 | tr -d '\n')

# ── deploy ────────────────────────────────────────────────────────────────────

info "Creating resource group '$RESOURCE_GROUP' in '$LOCATION'..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --output none

info "Validating deployment template..."
az deployment group validate \
  --resource-group "$RESOURCE_GROUP" \
  --template-file "$SCRIPT_DIR/main.bicep" \
  --parameters \
      location="$LOCATION" \
      prefix="$PREFIX" \
      vmSize="$VM_SIZE" \
      adminSshPublicKey="$SSH_PUBLIC_KEY" \
      cloudInitBase64="$CLOUD_INIT_B64" \
  --output none || error "Template validation failed. Aborting."

info "Deploying infrastructure (this takes ~5 minutes)..."
DEPLOYMENT_OUTPUT=$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$DEPLOYMENT_NAME" \
  --template-file "$SCRIPT_DIR/main.bicep" \
  --parameters \
      location="$LOCATION" \
      prefix="$PREFIX" \
      vmSize="$VM_SIZE" \
      adminSshPublicKey="$SSH_PUBLIC_KEY" \
      cloudInitBase64="$CLOUD_INIT_B64" \
  --output json)

VM_IP=$(printf '%s' "$DEPLOYMENT_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['properties']['outputs']['vmPublicIp']['value'])")

# ── output ────────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════"
echo " Deployment complete"
echo "════════════════════════════════════════════════════════"
echo " VM Public IP : $VM_IP"
echo " SSH command  : ssh -i ${SSH_KEY_PATH} azureuser@${VM_IP}"
echo ""
echo " OpenVPN client setup:"
echo "   Server   : $VM_IP"
echo "   Port     : 1194 / UDP"
echo "   Protocol : Password authentication"
echo "   Username : $VPN_USER"
echo "   Password : (the password you entered)"
echo ""
echo " Note: OpenVPN may take 2-3 minutes after first boot"
echo "       to finish setup on the VM."
echo "════════════════════════════════════════════════════════"
