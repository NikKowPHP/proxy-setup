#!/bin/bash

# ==============================================================================
#             TUN2SOCKS - System-Wide Proxy Tunnel Stop Script
# ==============================================================================
# This script restores all network and DNS settings to their original state.

# --- Script Configuration ---
VIRTUAL_TUN_DEVICE="tun0"
EXEMPT_TABLE=100 # Must match table number in start_proxy.sh

# --- Pre-flight Checks ---
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Please use 'sudo ./stop_proxy.sh'"
   exit 1
fi

echo "--- Stopping System-Wide Proxy Tunnel ---"

# --- 1. Stop the tun2socks process ---
if [ -f /tmp/tun2socks.pid ]; then
    T2S_PID=$(cat /tmp/tun2socks.pid)
    echo "Stopping tun2socks process (PID $T2S_PID)..."
    kill $T2S_PID &> /dev/null
    rm -f /tmp/tun2socks.pid
else
    echo "Could not find tun2socks PID file. It may already be stopped."
fi

# --- 2. Restore Network Routing & Policy ---
echo "Restoring original network routes and policies..."

# Remove policy-based routing rules
ip rule del fwmark 1 table $EXEMPT_TABLE &> /dev/null
iptables -t mangle -F OUTPUT
ip route flush table $EXEMPT_TABLE
ip route flush cache
echo "Policy routing rules removed."

if [ -f /tmp/original_gateway.txt ] && [ -f /tmp/original_interface.txt ]; then
    ORIGINAL_GATEWAY=$(cat /tmp/original_gateway.txt)
    ORIGINAL_INTERFACE=$(cat /tmp/original_interface.txt)

    ip route del default > /dev/null 2>&1
    if ! ip route | grep -q '^default'; then
        ip route add default via $ORIGINAL_GATEWAY dev $ORIGINAL_INTERFACE
    fi

    rm -f /tmp/original_gateway.txt
    rm -f /tmp/original_interface.txt
    echo "Routing restored."
else
    echo "Original gateway/interface files not found. Manual route restoration may be needed."
fi

# --- 3. Decommission Virtual TUN device ---
echo "Deleting virtual TUN device ($VIRTUAL_TUN_DEVICE)..."
ip link set dev $VIRTUAL_TUN_DEVICE down &> /dev/null
ip tuntap del dev $VIRTUAL_TUN_DEVICE mode tun &> /dev/null
echo "TUN device deleted."

# --- 4. Restore APT Configuration ---
echo "Removing APT proxy configuration..."
rm -f /etc/apt/apt.conf.d/99proxy.conf
echo "APT configuration restored."

# --- 5. Restore DNS and NetworkManager Configuration ---
echo "Restoring original DNS configuration..."
if [ -f /etc/systemd/resolved.conf.backup ]; then
    mv /etc/systemd/resolved.conf.backup /etc/systemd/resolved.conf
fi
if [ -f /etc/NetworkManager/NetworkManager.conf.backup ]; then
    mv /etc/NetworkManager/NetworkManager.conf.backup /etc/NetworkManager/NetworkManager.conf
fi

echo "Restarting network services..."
systemctl restart NetworkManager
systemctl restart systemd-resolved
echo "DNS configuration restored."

# --- 6. Final Verification ---
echo ""
echo "=========================================================="
echo "          SUCCESS: PROXY TUNNEL IS DEACTIVATED"
echo "=========================================================="
echo "Your default route is now:"
ip route | head -n 1
