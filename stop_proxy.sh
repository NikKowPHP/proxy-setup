#!/bin/bash

# ==============================================================================
#             TUN2SOCKS - System-Wide Proxy Tunnel Stop Script
# ==============================================================================
# This script restores all network and DNS settings to their original state.

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
    kill $T2S_PID
    rm /tmp/tun2socks.pid
else
    echo "Could not find tun2socks PID file. It may already be stopped."
fi

# --- 2. Restore Network Routing ---
echo "Restoring original network routes..."
ORIGINAL_GATEWAY=$(cat /tmp/original_gateway.txt)
ORIGINAL_INTERFACE=$(cat /tmp/original_interface.txt)

# Delete new default route and proxy-specific route
ip route del default > /dev/null 2>&1
ip route del $PROXY_IP > /dev/null 2>&1

# Restore original default route
ip route add default via $ORIGINAL_GATEWAY dev $ORIGINAL_INTERFACE

# Cleanup tmp files
rm /tmp/original_gateway.txt
rm /tmp/original_interface.txt

echo "Routing restored."

# --- 3. Restore DNS and NetworkManager Configuration ---
echo "Restoring original DNS configuration..."
if [ -f /etc/systemd/resolved.conf.backup ]; then
    mv /etc/systemd/resolved.conf.backup /etc/systemd/resolved.conf
fi
if [ -f /etc/NetworkManager/NetworkManager.conf.backup ]; then
    mv /etc/NetworkManager/NetworkManager.conf.backup /etc/NetworkManager/NetworkManager.conf
fi

# Restart services to apply original settings
systemctl restart NetworkManager
systemctl restart systemd-resolved
echo "DNS configuration restored."

# --- 4. Final Verification ---
echo ""
echo "=========================================================="
echo "          SUCCESS: PROXY TUNNEL IS DEACTIVATED"
echo "=========================================================="
echo "Your default route is now:"
ip route | head -n 1