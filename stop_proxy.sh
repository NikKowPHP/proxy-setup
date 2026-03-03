#!/bin/bash

# ==============================================================================
#           TUN2SOCKS - System-Wide Proxy Tunnel Stop Script
# ==============================================================================

# --- Script Configuration ---
VIRTUAL_TUN_DEVICE="tun0"
PHYSICAL_INTERFACE="enp2s0"

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
fi

# --- 2. Restore Routing ---
echo "Restoring original network routes..."
ROUTE_FILE="/tmp/proxy_added_routes.txt"
if [ -f "$ROUTE_FILE" ]; then
    echo "Removing specific exemption routes..."
    while IFS= read -r IP; do
        if [ -n "$IP" ]; then
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
fi
ip route flush cache

# --- 3. Clean up rules ---
ip rule del priority 500 &> /dev/null
ip route flush table 100 &> /dev/null
iptables -t mangle -F OUTPUT &> /dev/null

# --- 4. Restore Kernel Parameters ---
echo "Restoring Reverse Path Filtering settings..."
INTERFACES_TO_RESTORE=("all" "$PHYSICAL_INTERFACE" "$VIRTUAL_TUN_DEVICE")
for iface in "${INTERFACES_TO_RESTORE[@]}"; do
    if [ -f "/tmp/rp_filter_${iface}.backup" ]; then
        original_value=$(cat "/tmp/rp_filter_${iface}.backup")
        # Check if interface exists before trying to write to it
        if [ -e "/proc/sys/net/ipv4/conf/$iface/rp_filter" ]; then
            echo "$original_value" > "/proc/sys/net/ipv4/conf/$iface/rp_filter"
        fi
        rm "/tmp/rp_filter_${iface}.backup"
    fi
done

# --- 5. Remove Virtual Device ---
ip link del $VIRTUAL_TUN_DEVICE &> /dev/null

# --- 6. Restore DNS Settings ---
echo "Restoring original DNS configuration..."
if [ -f /etc/systemd/resolved.conf.backup ]; then
    mv /etc/systemd/resolved.conf.backup /etc/systemd/resolved.conf
fi
if [ -f /etc/NetworkManager/NetworkManager.conf.backup ]; then
    mv /etc/NetworkManager/NetworkManager.conf.backup /etc/NetworkManager/NetworkManager.conf
fi
systemctl restart NetworkManager && systemctl restart systemd-resolved

# --- 7. Restore APT settings ---
if [ -f /etc/apt/apt.conf.d/99proxy.conf ]; then
    rm -f /etc/apt/apt.conf.d/99proxy.conf
    echo "APT proxy configuration removed."
fi

# --- 8. Restore Docker Native Proxy Bypass ---
if command -v docker &> /dev/null; then
    echo "Restoring Docker native proxy settings..."
    
    # 8.1 Restore Docker Daemon
    if [ -f /etc/systemd/system/docker.service.d/http-proxy.conf ]; then
        rm -f /etc/systemd/system/docker.service.d/http-proxy.conf
        systemctl daemon-reload
        systemctl restart docker
    fi

    # 8.2 Restore Docker Client
    if [ -n "$SUDO_USER" ]; then
        USER_HOME=$(eval echo ~$SUDO_USER)
    else
        USER_HOME=$HOME
    fi

    DOCKER_CONFIG="$USER_HOME/.docker/config.json"
    if [ -f "$DOCKER_CONFIG.proxy_backup" ]; then
        mv "$DOCKER_CONFIG.proxy_backup" "$DOCKER_CONFIG"
        chown ${SUDO_USER:-root}:${SUDO_USER:-root} "$DOCKER_CONFIG"
        echo "Docker client configuration fully restored."
    elif command -v python3 &> /dev/null && [ -f "$DOCKER_CONFIG" ]; then
        # Fallback to python removal if no backup was found
        python3 -c '
import json, sys
conf_path = sys.argv[1]
try:
    with open(conf_path, "r") as f:
        data = json.load(f)
    if "proxies" in data:
        del data["proxies"]
        with open(conf_path, "w") as f:
            json.dump(data, f, indent=2)
except:
    pass
        ' "$DOCKER_CONFIG"
    fi
fi

echo -e "\n--- Proxy Tunnel Deactivated ---"