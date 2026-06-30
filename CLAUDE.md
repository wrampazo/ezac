# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Goal

Deploy a secure Linux VM on Azure running OpenVPN with password-only authentication. Deployment must work on both Windows (PowerShell + Bicep) and macOS/Linux (Bash + Azure CLI).

## Planned Deliverables

- `deploy.ps1` — Windows deployment script (PowerShell + Bicep)
- `deploy.sh` — macOS/Linux deployment script (Bash + Azure CLI)
- `main.bicep` — Azure Bicep template (VM + networking resources)
- `cloud-init.yaml` — OpenVPN installation and password-only configuration
- `README.md`

## Azure Resources Created

Each deployment provisions: resource group, VNet + subnet, NSG with restricted inbound rules (SSH 22 and OpenVPN 1194/UDP only), public IP, NIC, and VM.

## Forbidden Components

These are hard constraints — violating them breaks Apple TV compatibility:
- Do NOT install easy-rsa.
- Do NOT generate certificates or keys via PKI tooling.
- Do NOT initialize a PKI or create a CA chain.
- Do NOT create `server.key`, `ca.crt`, or `ta.key`.
- Do NOT use TLS-auth (`tls-auth`, `tls-crypt`) in any OpenVPN config.
- OpenVPN client authentication must use PAM (username + password) only. No client certificates.

A single self-signed server cert generated with `openssl req -x509` is the only acceptable crypto material — needed for TLS handshake but not a PKI. Clients do not present any certificate.

## Coding Standards

- Scripts must be idempotent.
- No hard-coded credentials — prompt user for OpenVPN username and password.
- Use only supported LTS Linux distributions for the VM (Ubuntu 22.04 LTS preferred).
- No deprecated Azure CLI commands.
- Print clear progress messages throughout script execution.

## Required Script Behaviors

Every deployment script must:
1. Check for Azure CLI installation.
2. Verify user is logged in (`az account show`).
3. List available Azure regions and let the user pick from the list.
4. Validate the region input before proceeding.
5. Install required dependencies (Bicep, Azure CLI extensions).
6. Handle errors gracefully.

## Script Output

Final output must include:
- VM public IP address
- SSH command to connect
- OpenVPN client configuration instructions
