# Instructions

## Coding Standards
- Use Azure CLI commands compatible with Windows, macOS, and Linux.
- For Windows: PowerShell + Bicep.
- For macOS/Linux: Bash + Azure CLI.
- Scripts must be idempotent.
- Use clear variable names and comments.

## Constraints
- Only open ports: SSH (22) and OpenVPN (1194/UDP).
- No hard-coded credentials.
- VM must use a supported LTS Linux distribution.
- No deprecated Azure commands.

## Output Format
- Scripts must print clear progress messages.
- Final output must include:
  - VM public IP
  - SSH command
  - OpenVPN client configuration instructions

## Execution Requirements
- Scripts must check for Azure CLI installation.
- Scripts must check user login (`az account show`).
- Scripts must list the azure regions available and let user to pick one of the list.
- Scripts must validate region input.
- Scripts must install dependencies (Bicep, Azure CLI extensions).
- Scripts must handle errors gracefully.

## Forbidden Components
- Do NOT install easy-rsa.
- Do NOT generate certificates or keys.
- Do NOT initialize a PKI.
- Do NOT create server.key, ca.crt, or ta.key.
- Do NOT use TLS-auth or certificate-based OpenVPN configuration.
- OpenVPN must rely exclusively on PAM password authentication.
