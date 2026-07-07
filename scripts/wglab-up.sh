#!/usr/bin/env bash
set -euo pipefail

IFACE="wglab"
PRIVKEY_FILE="/etc/wireguard/privkey-client.txt"
SERVER_PUBKEY="ETyOuKb69LUNMs9iRJD0KJc5nq4M1+dlM8oxEkcXfTo="
ENDPOINT="shanks-homelab.duckdns.org:41820"
ALLOWED_IPS="10.10.1.0/24,10.200.200.0/24"
LOCAL_IP="10.200.200.2/24"

if ip link show "$IFACE" &>/dev/null; then
    echo "Interface $IFACE déjà active."
    exit 0
fi

sudo ip link add "$IFACE" type wireguard
sudo wg set "$IFACE" private-key "$PRIVKEY_FILE"
sudo wg set "$IFACE" peer "$SERVER_PUBKEY" endpoint "$ENDPOINT" allowed-ips "$ALLOWED_IPS" persistent-keepalive 25
sudo ip address add "$LOCAL_IP" dev "$IFACE"
sudo ip link set "$IFACE" up

echo "Tunnel $IFACE établi."
sudo wg show "$IFACE"
