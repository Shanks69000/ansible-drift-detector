#!/usr/bin/env bash
set -euo pipefail

IFACE="wglab"

if ip link show "$IFACE" &>/dev/null; then
    sudo ip link delete "$IFACE"
    echo "Interface $IFACE supprimée."
else
    echo "Interface $IFACE inexistante."
fi
