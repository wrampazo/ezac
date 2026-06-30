# Ezac — Azure OpenVPN Deployment

Deploys a secure Linux VM on Azure running OpenVPN with **password-only authentication** (PAM). No certificates, no PKI. Designed for Apple TV and any OpenVPN client that supports username/password auth.

Only SSH (22) and OpenVPN (1194/UDP) are exposed.

## Prerequisites

| Requirement | macOS/Linux | Windows |
|---|---|---|
| Azure CLI | `brew install azure-cli` | [Download](https://aka.ms/install-azure-cli-windows) |
| Bicep | installed automatically by script | installed automatically by script |
| OpenSSH | built-in | built-in (Windows 10+) |
| Python 3 | built-in | [Download](https://python.org) |
| PowerShell 5.1+ | — | built-in |

Log in to Azure before running:
```
az login
```

## Deploy

**macOS / Linux**
```bash
chmod +x deploy.sh
./deploy.sh
```

**Windows (PowerShell)**
```powershell
.\deploy.ps1
```

Both scripts will:
1. List available Azure regions — you pick one.
2. Prompt for an OpenVPN username and password.
3. Generate an SSH key pair at `~/.ssh/ezac_id_rsa` (if one doesn't exist).
4. Create all Azure resources and deploy the VM.
5. Print connection details when done.

## Connect via OpenVPN

After deployment, retrieve the generated client config from the VM:

```bash
scp -i ~/.ssh/ezac_id_rsa azureuser@<VM-IP>:/etc/openvpn/client.ovpn ./client.ovpn
```

Import `client.ovpn` into any OpenVPN client. Enter the username and password you chose during deployment when prompted.

**Recommended clients:**
- macOS/iOS/tvOS: [OpenVPN Connect](https://openvpn.net/client/)
- Windows: [OpenVPN Connect](https://openvpn.net/client/) or [OpenVPN GUI](https://openvpn.net/community-downloads/)
- Android: OpenVPN for Android

**Apple TV:** Import `client.ovpn` via the OpenVPN Connect app on tvOS. Authentication is username + password only — no certificates required on the client.

> OpenVPN setup runs on first boot and takes ~2 minutes. If the connection is refused immediately after deploy, wait and retry.

## SSH Access

```bash
ssh -i ~/.ssh/ezac_id_rsa azureuser@<VM-IP>
```

## Tear Down

```bash
az group delete --name ezac-rg --yes
```

## Authentication Model

The real authentication is **username + password via PAM** — the server runs with `verify-client-cert none`, so it does not validate any client certificate.

For TLS, the VM generates two independent self-signed certs (no CA chain, no PKI):
- a **server** cert, embedded as `<ca>` in `client.ovpn` so the client can verify the server;
- a **client** cert/key, embedded as `<cert>`/`<key>` because OpenVPN clients (including Apple TV's OpenVPN Connect) require these blocks in a profile even when the server ignores them.

If you need to rebuild `client.ovpn` on an existing VM, run `regenerate-client.sh` on the VM via `sudo`.

## Architecture

```
Internet
   │
   │  TCP/22 (SSH)
   │  UDP/1194 (OpenVPN)
   ▼
NSG (ezac-nsg)  ← all other inbound blocked
   │
   ▼
Public IP (ezac-pip)
   │
   ▼
NIC (ezac-nic)
   │
   ▼
VM (ezac-vm)  Ubuntu 22.04 LTS, Standard_B1s
   │
   └── VNet 10.0.0.0/16 / Subnet 10.0.1.0/24
       OpenVPN tunnel: 10.8.0.0/24
```

### Files

| File | Purpose |
|---|---|
| `deploy.sh` | macOS/Linux deployment (Bash + Azure CLI) |
| `deploy.ps1` | Windows deployment (PowerShell + Bicep) |
| `main.bicep` | Azure resource definitions |
| `cloud-init.yaml` | VM bootstrap: installs OpenVPN, generates self-signed cert, configures PAM auth |
