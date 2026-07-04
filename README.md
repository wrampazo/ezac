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
2. Prompt for an OpenVPN username and password (minimum 12 characters; 16+ recommended — the password is the only client secret).
3. Generate an SSH key pair at `~/.ssh/ezac_id_rsa` (if one doesn't exist).
4. Create all Azure resources and deploy the VM.
5. Wait for OpenVPN setup to finish on the VM and **download `client.ovpn` automatically** into the repo folder.
6. Print connection details when done.

## Connect via OpenVPN

The deploy script downloads the client config to `./client.ovpn` for you. If that step timed out (the VM was still booting), fetch it manually:

```bash
scp -i ~/.ssh/ezac_id_rsa azureuser@<VM-IP>:client.ovpn ./client.ovpn
```

Import `client.ovpn` into any OpenVPN client. Enter the username and password you chose during deployment when prompted.

**Recommended clients:**
- macOS: **openvpn CLI** (see below) — most reliable; the OpenVPN Connect GUI has a known bug on macOS (see [Troubleshooting](#troubleshooting))
- iOS/tvOS: [OpenVPN Connect](https://openvpn.net/client/)
- Windows: [OpenVPN Connect](https://openvpn.net/client/) or [OpenVPN GUI](https://openvpn.net/community-downloads/)
- Android: OpenVPN for Android

**Apple TV:** Import `client.ovpn` via the OpenVPN Connect app on tvOS. Authentication is username + password only — no certificates required on the client.

> OpenVPN setup runs on first boot and takes ~2 minutes. If the connection is refused immediately after deploy, wait and retry.

### Connect from macOS (recommended: openvpn CLI)

On macOS the OpenVPN Connect GUI can fail with `Error calling protect() method on socket` (see [Troubleshooting](#troubleshooting)). The classic `openvpn` CLI is not affected. This repo ships a helper that installs it and connects:

```bash
chmod +x install-openvpn-cli.sh
./install-openvpn-cli.sh ./client.ovpn --connect
```

**Prerequisites (checked by the script):** macOS, and [Homebrew](https://brew.sh). The script installs the `openvpn` formula, locates your `client.ovpn`, and connects. When you see `Initialization Sequence Completed`, you are connected. Leave the terminal open; Ctrl-C disconnects.

You can also install without connecting (omit `--connect`) and run the printed `sudo openvpn --config …` command yourself.

## Multiple users / simultaneous connections

Authentication is per **system user** on the VM. To add another VPN user, SSH to the VM and create a Linux account — no service restart needed (PAM checks credentials live):

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin newuser
sudo passwd newuser
```

The same `client.ovpn` is used by everyone (the embedded client cert is **not** validated server-side — `verify-client-cert none`). The only per-user secret is the password. Two machines on the **same public IP / network** can connect at the same time as long as they use **different usernames** (the server uses `username-as-common-name`, so the usernames are distinct identities and NAT gives each machine a different source port). Using the *same* username on two machines simultaneously would require `duplicate-cn` on the server.

## SSH Access

```bash
ssh -i ~/.ssh/ezac_id_rsa azureuser@<VM-IP>
```

## Tear Down

```bash
./teardown.sh        # macOS/Linux
.\teardown.ps1       # Windows
```

Shows every resource in `ezac-rg`, asks for confirmation, deletes the whole resource group, and removes stale local artifacts (`client.ovpn`, recorded host keys) so the next deploy starts clean. The SSH key pair is kept and reused.

## Authentication Model

The real authentication is **username + password via PAM** — the server runs with `verify-client-cert none`, so it does not validate any client certificate.

For TLS, the VM generates two independent self-signed certs (no CA chain, no PKI):
- a **server** cert, embedded as `<ca>` in `client.ovpn` so the client can verify the server;
- a **client** cert/key, embedded as `<cert>`/`<key>` because OpenVPN clients (including Apple TV's OpenVPN Connect) require these blocks in a profile even when the server ignores them.

If you need to rebuild `client.ovpn` on an existing VM, run `regenerate-client.sh` on the VM via `sudo`.

## Security Hardening

Built into the deployment:

- **Brute-force lockout** — `pam_faillock` locks a VPN account for 15 minutes after 5 failed login attempts (the password is the only client secret, so this matters).
- **Minimum password length** — deploy scripts enforce 12+ characters.
- **Automatic security updates** — `unattended-upgrades` keeps the VM patched after first boot.
- **Trusted Launch** — the VM runs with Secure Boot + vTPM enabled.
- **No secrets in deployment history** — the cloud-init payload (which carries the VPN credentials) is a `@secure()` Bicep parameter, so it never appears in Azure's deployment logs; the on-disk copies Azure leaves behind (`/var/lib/waagent`, cloud-init user-data) are deleted during setup.
- **SSH is key-only** — password authentication is disabled for the admin user.

Worth doing manually if your situation allows: restrict the NSG source address for SSH (22) — and even OpenVPN (1194) — to your home/ISP IP range instead of `*`.

## Troubleshooting

### macOS OpenVPN Connect: "Error calling protect() method on socket"

**Symptom:** the OpenVPN Connect GUI shows a *Connection timeout* dialog reading `Error calling protect() method on socket : 30 times`. It happens for **any** username/password because the failure occurs on the client *before* credentials are ever sent — so creating new VPN users makes no difference.

**Cause:** `protect()` keeps OpenVPN Connect's own control socket outside the tunnel. On macOS this relies on the app's network/system extension; when that extension fails to load or was never approved, `protect()` fails repeatedly and the client times out before reaching the server. It is a client/OS-side issue, not a server or auth problem.

**Fix:** stop using the GUI on macOS and use the `openvpn` CLI instead:

```bash
# 1. Remove OpenVPN Connect completely
chmod +x uninstall-openvpn-connect.sh
./uninstall-openvpn-connect.sh

# 2. Install the CLI and connect
chmod +x install-openvpn-cli.sh
./install-openvpn-cli.sh ./client.ovpn --connect
```

If you prefer to keep the GUI: in **System Settings → General → Login Items & Extensions → Network Extensions** (older macOS: **Privacy & Security**) approve the blocked "OpenVPN" extension, fully quit the app, reboot, and retry.

### uninstall-openvpn-connect.sh — app not removed ("Permission denied")

**Fixed.** OpenVPN Connect's PKG installer places the app in a **root-owned** folder `/Applications/OpenVPN Connect/` (alongside its own *Uninstall OpenVPN Connect.app*). An earlier version of the uninstaller tried to delete it as the normal user and printed `Permission denied` for every file. The script now removes the application with `sudo` (step 3) and also clears the leftover **Dock icon** (step 4). If you hit the old behaviour, either re-run the current script or remove it manually:

```bash
sudo rm -rf "/Applications/OpenVPN Connect"
```

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
| `teardown.sh` / `teardown.ps1` | Delete the entire Azure environment + stale local artifacts |
| `cloud-init.yaml` | VM bootstrap: installs OpenVPN, generates self-signed cert, configures PAM auth |
| `regenerate-client.sh` | Rebuild `client.ovpn` on an existing VM (run on the VM via `sudo`) |
| `install-openvpn-cli.sh` | macOS client: install the `openvpn` CLI and connect (works around the OpenVPN Connect `protect()` bug) |
| `uninstall-openvpn-connect.sh` | macOS client: completely remove the OpenVPN Connect GUI app, its data, Dock icon and extensions |
