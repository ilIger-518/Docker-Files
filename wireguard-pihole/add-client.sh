#!/usr/bin/env bash
# add-client.sh – Add a new WireGuard peer to the running stack.
#
# Usage:
#   ./add-client.sh <client-name>
#
# Requirements:
#   - The wireguard and pihole containers must be running
#     (docker compose up -d)
#   - A .env file with at least SERVER_URL must exist in this directory
#     (copy .env.example and fill in the values)
#
# The script will:
#   1. Generate a key pair and preshared key inside the WireGuard container
#   2. Find the next free IP in the 10.13.13.0/24 tunnel subnet
#   3. Add the peer to the live WireGuard interface (takes effect immediately)
#   4. Append the peer block to wg0.conf so it survives container restarts
#   5. Write the client config to config/wireguard/peer_<name>/<name>.conf
#   6. Print a QR code for easy import into the WireGuard mobile app

set -euo pipefail

# ── helpers ────────────────────────────────────────────────────────────────────
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }

# ── load .env ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a

# ── arguments & config ─────────────────────────────────────────────────────────
CLIENT_NAME="${1:-}"
[[ -n "$CLIENT_NAME" ]] || die "Usage: $0 <client-name>"

# Validate: alphanumeric, hyphens and underscores only
[[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]] \
    || die "Client name must contain only letters, numbers, hyphens, or underscores."

CONTAINER="${CONTAINER_NAME:-wireguard}"
WG_IFACE="wg0"
WG_SUBNET="10.13.13"
DNS_IP="172.20.0.2"
SERVER_PORT="${SERVER_PORT:-51820}"
CONFIG_DIR="${SCRIPT_DIR}/config/wireguard"
PEER_DIR="${CONFIG_DIR}/peer_${CLIENT_NAME}"
SERVER_CONF="${CONFIG_DIR}/wg_confs/${WG_IFACE}.conf"

[[ -n "${SERVER_URL:-}" ]] \
    || die "SERVER_URL is not set. Copy .env.example to .env and fill in SERVER_URL."

# ── pre-flight ─────────────────────────────────────────────────────────────────
docker info > /dev/null 2>&1 || die "Docker is not running or the current user lacks permissions."
docker inspect --type=container "$CONTAINER" > /dev/null 2>&1 \
    || die "Container '$CONTAINER' is not running. Start the stack with: docker compose up -d"

[[ -f "$SERVER_CONF" ]] \
    || die "Server config not found at $SERVER_CONF. Has the container initialised yet?"

# Check for duplicate peer name
if [[ -d "$PEER_DIR" ]]; then
    die "Peer '$CLIENT_NAME' already exists at $PEER_DIR"
fi

# ── key generation ─────────────────────────────────────────────────────────────
echo "Generating keys for '$CLIENT_NAME'..."
PRIVATE_KEY=$(docker exec "$CONTAINER" wg genkey)
PUBLIC_KEY=$(printf '%s' "$PRIVATE_KEY" | docker exec -i "$CONTAINER" wg pubkey)
PRESHARED_KEY=$(docker exec "$CONTAINER" wg genpsk)
SERVER_PUBLIC_KEY=$(docker exec "$CONTAINER" cat /config/server_publickey)

# ── find next free IP ──────────────────────────────────────────────────────────
NEXT_OCTET=2
while docker exec "$CONTAINER" wg show "$WG_IFACE" allowed-ips 2>/dev/null \
      | grep -q "${WG_SUBNET}\.${NEXT_OCTET}/32"; do
    NEXT_OCTET=$((NEXT_OCTET + 1))
    [[ $NEXT_OCTET -lt 255 ]] || die "No free IPs left in the ${WG_SUBNET}.0/24 subnet."
done
CLIENT_IP="${WG_SUBNET}.${NEXT_OCTET}"

# ── add peer to live WireGuard interface ───────────────────────────────────────
echo "Adding peer to live WireGuard interface (IP: ${CLIENT_IP}/32)..."
PSK_TMPFILE=$(docker exec "$CONTAINER" mktemp)
printf '%s' "$PRESHARED_KEY" | docker exec -i "$CONTAINER" sh -c "cat > '$PSK_TMPFILE'"
docker exec "$CONTAINER" wg set "$WG_IFACE" \
    peer "$PUBLIC_KEY" \
    preshared-key "$PSK_TMPFILE" \
    allowed-ips "${CLIENT_IP}/32"
docker exec "$CONTAINER" rm -f "$PSK_TMPFILE"

# ── persist peer in server config ─────────────────────────────────────────────
echo "Persisting peer in ${SERVER_CONF}..."
cat >> "$SERVER_CONF" << EOF

# Peer: ${CLIENT_NAME}
[Peer]
PublicKey = ${PUBLIC_KEY}
PresharedKey = ${PRESHARED_KEY}
AllowedIPs = ${CLIENT_IP}/32
EOF

# ── write client config ────────────────────────────────────────────────────────
mkdir -p "$PEER_DIR"
CLIENT_CONF="${PEER_DIR}/${CLIENT_NAME}.conf"
cat > "$CLIENT_CONF" << EOF
[Interface]
# /32 assigns this single IP to the client interface; routing is handled by AllowedIPs below.
Address = ${CLIENT_IP}/32
PrivateKey = ${PRIVATE_KEY}
DNS = ${DNS_IP}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
PresharedKey = ${PRESHARED_KEY}
Endpoint = ${SERVER_URL}:${SERVER_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
chmod 600 "$CLIENT_CONF"

# ── output ─────────────────────────────────────────────────────────────────────
echo ""
echo "✓ Peer '${CLIENT_NAME}' added successfully"
info "Tunnel IP : ${CLIENT_IP}/32"
info "DNS       : ${DNS_IP} (Pi-hole)"
info "Config    : ${CLIENT_CONF}"
echo ""

# Try to display a QR code for easy mobile import
QR_SHOWN=false

if command -v qrencode &>/dev/null; then
    echo "Scan the QR code with the WireGuard app:"
    qrencode -t ansiutf8 < "$CLIENT_CONF"
    QR_SHOWN=true
elif docker exec "$CONTAINER" sh -c 'command -v qrencode' &>/dev/null; then
    echo "Scan the QR code with the WireGuard app:"
    docker exec -i "$CONTAINER" sh -c "cat | qrencode -t ansiutf8" < "$CLIENT_CONF"
    QR_SHOWN=true
fi

if [[ "$QR_SHOWN" == false ]]; then
    echo "Install qrencode on the host for a QR code:  apt-get install qrencode"
    echo ""
    echo "Client config (${CLIENT_NAME}.conf):"
    echo "────────────────────────────────────────"
    cat "$CLIENT_CONF"
    echo "────────────────────────────────────────"
fi
