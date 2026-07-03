#!/bin/bash
#
# install-openvpn-cli.sh
# Install the OpenVPN command-line client on macOS and connect to the VPN.
#
# Why this exists: the OpenVPN Connect GUI app on macOS can fail with
# "Error calling protect() method on socket" — its network/system
# extension never loads, so the app times out before it ever reaches the
# server. The classic `openvpn` CLI does not use that extension and is not
# affected. Use uninstall-openvpn-connect.sh first to remove the GUI app,
# then run this script.
#
# Usage:
#   ./install-openvpn-cli.sh [path-to-client.ovpn] [--connect]
#
#   path-to-client.ovpn   Optional. Defaults to the first of:
#                           ./client.ovpn, ~/Downloads/client.ovpn
#   --connect             Start the VPN after installing (needs sudo).
#
# Idempotent: re-running only installs what is missing.

set -u

CONNECT=0
OVPN_FILE=""

for arg in "$@"; do
  case "$arg" in
    --connect) CONNECT=1 ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) OVPN_FILE="$arg" ;;
  esac
done

echo "════════════════════════════════════════════════════════"
echo " OpenVPN CLI — install & connect (macOS)"
echo "════════════════════════════════════════════════════════"

# ----------------------------------------------------------------------
# Prerequisites
# ----------------------------------------------------------------------
echo
echo "[1/4] Checking prerequisites..."

# 1. Must be macOS.
if [ "$(uname -s)" != "Darwin" ]; then
  echo "  ERROR: this script targets macOS (Darwin). Detected: $(uname -s)."
  echo "  On Linux, install openvpn with your package manager, e.g.:"
  echo "    sudo apt-get install -y openvpn      # Debian/Ubuntu"
  exit 1
fi
echo "  macOS detected: $(sw_vers -productVersion 2>/dev/null || echo unknown)"

# 2. Homebrew must be present (it is the supported install path).
if ! command -v brew >/dev/null 2>&1; then
  echo "  ERROR: Homebrew is not installed."
  echo "  Install it, then re-run this script:"
  echo '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  exit 1
fi
echo "  Homebrew found: $(brew --version | head -1)"

# ----------------------------------------------------------------------
# Install openvpn
# ----------------------------------------------------------------------
echo
echo "[2/4] Installing the openvpn CLI..."
if command -v openvpn >/dev/null 2>&1; then
  echo "  Already installed: $(openvpn --version 2>/dev/null | head -1)"
elif brew list openvpn >/dev/null 2>&1; then
  echo "  Homebrew reports openvpn installed; ensuring it is linked..."
  brew link --overwrite openvpn >/dev/null 2>&1 || true
else
  echo "  Running: brew install openvpn"
  if ! brew install openvpn; then
    echo "  ERROR: 'brew install openvpn' failed. See output above."
    exit 1
  fi
fi

# Resolve the openvpn binary. Homebrew links openvpn into its sbin
# (/opt/homebrew/sbin or /usr/local/sbin), which is frequently missing from
# PATH, so `command -v openvpn` can come up empty right after install.
OPENVPN_BIN="$(command -v openvpn 2>/dev/null || true)"
if [ -z "$OPENVPN_BIN" ]; then
  for cand in /opt/homebrew/sbin/openvpn /usr/local/sbin/openvpn \
              "$(brew --prefix 2>/dev/null)/sbin/openvpn"; do
    [ -x "$cand" ] && OPENVPN_BIN="$cand" && break
  done
fi
if [ -z "$OPENVPN_BIN" ]; then
  echo "  ERROR: openvpn installed but the binary could not be located."
  echo "  Try:  brew link --overwrite openvpn"
  exit 1
fi
echo "  openvpn binary: $OPENVPN_BIN"

# ----------------------------------------------------------------------
# Locate the client profile
# ----------------------------------------------------------------------
echo
echo "[3/4] Locating the client profile..."
if [ -z "$OVPN_FILE" ]; then
  for cand in "./client.ovpn" "$HOME/Downloads/client.ovpn"; do
    if [ -f "$cand" ]; then OVPN_FILE="$cand"; break; fi
  done
fi

if [ -z "$OVPN_FILE" ] || [ ! -f "$OVPN_FILE" ]; then
  echo "  No client.ovpn found (looked in ./ and ~/Downloads)."
  echo "  Retrieve it from the VM first, e.g.:"
  echo "    scp -i ~/.ssh/ezac_id_rsa azureuser@<VM-IP>:/etc/openvpn/client.ovpn ~/Downloads/client.ovpn"
  echo "  then re-run:  ./install-openvpn-cli.sh ~/Downloads/client.ovpn"
  # Not a fatal error for the install itself — the CLI is ready to use.
  OVPN_FILE=""
else
  echo "  Using profile: $OVPN_FILE"
fi

# ----------------------------------------------------------------------
# Connect (or print the command)
# ----------------------------------------------------------------------
echo
echo "[4/4] Ready."
if [ -n "$OVPN_FILE" ] && [ "$CONNECT" -eq 1 ]; then
  echo "  Connecting now (Ctrl-C to disconnect)..."
  echo "  You will be prompted for your VPN username and password."
  echo "  Look for: 'Initialization Sequence Completed'"
  echo
  exec sudo "$OPENVPN_BIN" --config "$OVPN_FILE"
fi

echo "════════════════════════════════════════════════════════"
echo " Install complete. To connect:"
if [ -n "$OVPN_FILE" ]; then
  echo "   sudo $OPENVPN_BIN --config \"$OVPN_FILE\""
  echo
  echo " Or re-run this script with --connect to start it now:"
  echo "   ./install-openvpn-cli.sh \"$OVPN_FILE\" --connect"
else
  echo "   sudo $OPENVPN_BIN --config <path-to-client.ovpn>"
fi
echo
echo " When connected you will see 'Initialization Sequence Completed'."
echo " Enter the VPN username + password you created on the server."
echo "════════════════════════════════════════════════════════"
