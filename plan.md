# Plan

## Goal
Deploy a secure Linux VM on Azure that runs OpenVPN with password-only authentication and allows SSH access. 
Deployment must support Windows (PowerShell + Bicep) and macOS/Linux (Shell + Azure CLI).

## Context
- VM hosts OpenVPN.
- Only ports allowed:
  - SSH (22)
  - OpenVPN (1194/UDP)
- User chooses Azure region.
- Scripts authenticate using `az login`.
- Scripts install required dependencies automatically.
- Deployment creates:
  - Resource group
  - VNet + subnet
  - NSG with restricted inbound rules
  - Public IP
  - NIC
  - VM
  - OpenVPN configuration (username + password)
  - OpenVPN must use password-only authentication (PAM).
- No PKI or certificate-based authentication.
- No easy-rsa installation.
- No TLS key generation (no ta.key).
- No client certificates or private keys.
- Apple TV compatibility is required; therefore, only username/password auth is allowed.

## Deliverables
- deploy.ps1 (Windows)
- deploy.sh (macOS/Linux)
- main.bicep (VM + networking)
- cloud-init.yaml (OpenVPN installation + password-only configuration)
- README.md

## Step-by-step Plan
1. Prompt user for region, OpenVPN username, OpenVPN password.
2. Validate Azure login.
3. Create resource group.
4. Create VNet, subnet, NSG.
5. Add inbound rules for SSH and OpenVPN.
6. Create public IP + NIC.
7. Deploy VM using Bicep.
8. Use cloud-init to install and configure OpenVPN with password-only auth.
9. Output connection details.

## Open Questions
- Should the VM use Ubuntu 22.04 LTS?
