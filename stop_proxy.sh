#!/bin/bash

# ==============================================================================
#           TUN2SOCKS - System-Wide Proxy Tunnel Stop Script
# ==============================================================================
# This script reverts all changes made by start_proxy.sh.

# --- Script Configuration ---
VIRTUAL_TUN_DEVICE="tun0"
# This needs to match the interface in start_proxy.sh to restore rp_filter
PHYSICAL_INTERFACE="enp2s0"

# --- Pre-flight Checks ---
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Please use 'sudo ./stop_proxy.sh'"
   exit 1
fi

echo "--- Stopping System-Wide Proxy Tunnel ---"

# --- 1. Kill tun2socks ---
if [ -f /tmp/tun2socks.pid ]; then
    echo "Stopping tun2socks process..."
    kill $(cat /tmp/tun2socks.pid) &> /dev/null
    rm -f /tmp/tun2socks.pid
else
    echo "tun2socks PID file not found. It might already be stopped."
fi

# --- 2. Restore Routing ---
echo "Restoring original network routes..."

# Delete specific routes added by start script
ROUTE_FILE="/tmp/proxy_added_routes.txt"
if [ -f "$ROUTE_FILE" ]; then
    echo "Removing specific exemption routes..."
    while IFS= read -r IP; do
        if [ -n "$IP" ]; then
            echo " -> Deleting route for $IP"
            ip route del "$IP" &> /dev/null
        fi
    done < "$ROUTE_FILE"
    rm -f "$ROUTE_FILE"
fi

if [ -f /tmp/original_gateway.txt ] && [ -f /tmp/original_interface.txt ]; then
    ORIGINAL_GATEWAY=$(cat /tmp/original_gateway.txt)
    ORIGINAL_INTERFACE=$(cat /tmp/original_interface.txt)
    ip route del default &> /dev/null
    ip route add default via $ORIGINAL_GATEWAY dev $ORIGINAL_INTERFACE
    rm -f /tmp/original_gateway.txt /tmp/original_interface.txt
    echo "Default route restored."
else
    echo "WARNING: Original gateway information not found. You may need to restore the default route manually."
    echo "Example: sudo ip route add default via <YOUR_GATEWAY_IP> dev <YOUR_INTERFACE>"
fi
ip route flush cache

# --- 3. Clean up old Policy Routing and Firewall Rules ---
echo "Cleaning up old policy routing rules and iptables marks (if any)..."
# These commands are kept for backward compatibility to clean up a system
# configured with an older version of the start script.
ip rule del priority 500 &> /dev/null
ip route flush table 100 &> /dev/null
iptables -t mangle -F OUTPUT &> /dev/null

# --- 4. Restore Kernel Parameters (Reverse Path Filtering) ---
echo "Restoring Reverse Path Filtering settings..."
INTERFACES_TO_RESTORE=("all" "$PHYSICAL_INTERFACE" "$VIRTUAL_TUN_DEVICE")
for iface in "${INTERFACES_TO_RESTORE[@]}"; do
    if [ -f "/tmp/rp_filter_${iface}.backup" ]; then
        original_value=$(cat "/tmp/rp_filter_${iface}.backup")
        # Check if interface exists before trying to write to it
        if [ -e "/proc/sys/net/ipv4/conf/$iface/rp_filter" ]; then
            echo "$original_value" > "/proc/sys/net/ipv4/conf/$iface/rp_filter"
            echo " -> rp_filter for '$iface' restored to '$original_value'"
        fi
        rm "/tmp/rp_filter_${iface}.backup"
    fi
done

# --- 5. Remove Virtual Device ---
echo "Deleting virtual network device..."
ip link del $VIRTUAL_TUN_DEVICE &> /dev/null

# --- 6. Restore Original DNS Settings ---
echo "Restoring original DNS configuration..."
if [ -f /etc/systemd/resolved.conf.backup ]; then
    mv /etc/systemd/resolved.conf.backup /etc/systemd/resolved.conf
fi
if [ -f /etc/NetworkManager/NetworkManager.conf.backup ]; then
    mv /etc/NetworkManager/NetworkManager.conf.backup /etc/NetworkManager/NetworkManager.conf
fi
echo "Restarting network services to apply DNS changes..."
systemctl restart NetworkManager && systemctl restart systemd-resolved
echo "DNS settings restored."

# --- 7. Restore APT settings ---
if [ -f /etc/apt/apt.conf.d/99proxy.conf ]; then
    rm -f /etc/apt/apt.conf.d/99proxy.conf
    echo "APT proxy configuration removed."
fi

echo -e "\n--- Proxy Tunnel Deactivated ---"
