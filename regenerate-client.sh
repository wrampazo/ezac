#!/bin/bash
# Run ON the VM (as root via sudo) to rebuild /etc/openvpn/client.ovpn with the
# <ca>, <cert>, and <key> blocks that OpenVPN clients require. No server restart
# needed: the server uses `verify-client-cert none`, so the client cert is not
# validated server-side — the PAM password remains the real authentication.
set -e

SERVER_DIR=/etc/openvpn/server

[[ -f "$SERVER_DIR/vpn.crt" ]] || { echo "ERROR: $SERVER_DIR/vpn.crt not found — is OpenVPN set up?"; exit 1; }

# Generate the client keypair if it doesn't already exist.
if [[ ! -f "$SERVER_DIR/client.crt" ]]; then
  echo "Generating client certificate..."
  openssl req -x509 -newkey rsa:2048 \
    -keyout "$SERVER_DIR/client.key" \
    -out    "$SERVER_DIR/client.crt" \
    -days 3650 -nodes \
    -subj "/CN=vpn-client"
  chmod 600 "$SERVER_DIR/client.key"
fi

SERVER_IP=$(curl -sf https://api.ipify.org || hostname -I | awk '{print $1}')
CA_CERT=$(cat "$SERVER_DIR/vpn.crt")
CLIENT_CERT=$(cat "$SERVER_DIR/client.crt")
CLIENT_KEY=$(cat "$SERVER_DIR/client.key")

cat > /etc/openvpn/client.ovpn <<OVPN
client
dev tun
proto udp
remote ${SERVER_IP} 1194
resolv-retry infinite
nobind
persist-key
persist-tun
cipher AES-256-GCM
auth SHA256
verb 3
auth-user-pass
<ca>
${CA_CERT}
</ca>
<cert>
${CLIENT_CERT}
</cert>
<key>
${CLIENT_KEY}
</key>
OVPN

chmod 600 /etc/openvpn/client.ovpn

# Copy into the admin user's home so it can be scp'd down without sudo
# ('azureuser' is the fixed admin username set in main.bicep).
install -o azureuser -g azureuser -m 600 \
  /etc/openvpn/client.ovpn /home/azureuser/client.ovpn

echo "Rebuilt /etc/openvpn/client.ovpn (copy in /home/azureuser/client.ovpn):"
grep -c "BEGIN CERTIFICATE" /etc/openvpn/client.ovpn | xargs echo "  certificate blocks:"
grep -c "BEGIN PRIVATE KEY" /etc/openvpn/client.ovpn | xargs echo "  private key blocks:"
echo "  remote: ${SERVER_IP} 1194"
