#!/bin/bash
#
# connect-vpn.sh
# Connect to the VPN using an already-installed openvpn CLI (macOS/Linux).
#
# Install first (macOS): ./install-openvpn-cli.sh
#
# Usage:
#   ./connect-vpn.sh [path-to-client.ovpn]
#
#   path-to-client.ovpn   Optional. Defaults to the first of:
#                           client.ovpn next to this script, ~/Downloads/client.ovpn
#
# Ctrl-C disconnects.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OVPN_FILE="${1:-}"

case "$OVPN_FILE" in
  -h|--help)
    grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac

# ----------------------------------------------------------------------
# Locate the openvpn binary (Homebrew's sbin is often missing from PATH)
# ----------------------------------------------------------------------
OPENVPN_BIN="$(command -v openvpn 2>/dev/null || true)"
if [ -z "$OPENVPN_BIN" ]; then
  for cand in /opt/homebrew/sbin/openvpn /usr/local/sbin/openvpn \
              "$(brew --prefix 2>/dev/null)/sbin/openvpn"; do
    [ -x "$cand" ] && OPENVPN_BIN="$cand" && break
  done
fi
if [ -z "$OPENVPN_BIN" ]; then
  echo "ERROR: openvpn CLI not found. Install it first:"
  echo "  ./install-openvpn-cli.sh        # macOS (Homebrew)"
  echo "  sudo apt-get install openvpn    # Debian/Ubuntu"
  exit 1
fi

# ----------------------------------------------------------------------
# Locate the client profile
# ----------------------------------------------------------------------
if [ -z "$OVPN_FILE" ]; then
  for cand in "$SCRIPT_DIR/client.ovpn" "$HOME/Downloads/client.ovpn"; do
    if [ -f "$cand" ]; then OVPN_FILE="$cand"; break; fi
  done
fi
if [ -z "$OVPN_FILE" ] || [ ! -f "$OVPN_FILE" ]; then
  echo "ERROR: no client.ovpn found (looked next to this script and in ~/Downloads)."
  echo "deploy.sh downloads it automatically; to fetch it manually from the VM:"
  echo "  scp -i ~/.ssh/ezac_id_rsa azureuser@<VM-IP>:client.ovpn ./client.ovpn"
  exit 1
fi

echo "════════════════════════════════════════════════════════"
echo " Connecting to the VPN (Ctrl-C to disconnect)"
echo "════════════════════════════════════════════════════════"
echo "  Profile: $OVPN_FILE"
echo
echo "  Two sets of credentials are needed, in this order:"
echo "    1. 'Password:'            -> your macOS login password (sudo)"
echo "    2. 'Enter Auth Username:' -> your VPN username"
echo "       'Enter Auth Password:' -> your VPN password"
echo
echo "  Look for: 'Initialization Sequence Completed'"
echo
exec sudo "$OPENVPN_BIN" --config "$OVPN_FILE"
