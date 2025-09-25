#!/bin/bash

# ==============================================================================
#                      Network Diagnosis Script
# ==============================================================================
# This script checks DNS, routing, and firewall rules to help diagnose
# connectivity issues when the proxy tunnel script is active.
#
# Usage: Run this script with sudo AFTER start_proxy.sh has been run.
#        sudo ./diagnose_network.sh
# ==============================================================================

# --- Pre-flight Checks ---
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Please use 'sudo ./diagnose_network.sh'"
   exit 1
fi

echo "========================================"
echo "         Network State Diagnosis"
echo "========================================"
echo

# --- 0. Sanity Check ---
if ! ip link show tun0 &> /dev/null; then
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!! WARNING: The 'tun0' network device was not found.                   !!!"
    echo "!!! This script is meant to be run AFTER 'start_proxy.sh' is active.    !!!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo
fi


# --- 1. DNS Configuration ---
echo "--- [1] DNS Configuration ---"
echo "Checking /etc/resolv.conf (should be a symlink to a systemd-resolved file):"
ls -l /etc/resolv.conf
echo "Contents of /etc/resolv.conf (should point to 127.0.0.53):"
grep -v '^#' /etc/resolv.conf
echo
echo "Checking systemd-resolved status (first 15 lines)..."
resolvectl status | head -n 15
echo "..."
echo

# --- 2. Routing Tables ---
echo "--- [2] Routing Configuration ---"
DEFAULT_ROUTE_COUNT=$(ip route show | grep -c '^default')
echo "Showing main routing table (ip route show):"
ip route show
if [ "$DEFAULT_ROUTE_COUNT" -gt 1 ]; then
    echo
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!! WARNING: Found $DEFAULT_ROUTE_COUNT default routes in the main routing table.   !!!"
    echo "!!! This is a critical error and will cause unpredictable network behavior. !!!"
    echo "!!! There should only be ONE default route, pointing to the 'tun0' device.!!!"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
fi
echo
echo "Showing policy routing rules (ip rule show):"
ip rule show
echo
echo "Showing exemption routing table (ip route show table 100):"
ip route show table 100
if [ -f /etc/iproute2/rt_tables ]; then
    echo
    echo "Routing table names defined in /etc/iproute2/rt_tables:"
    cat /etc/iproute2/rt_tables
fi
echo

# --- 3. Firewall Rules ---
echo "--- [3] IPTables Mangle Rules ---"
echo "Showing packet counters for exemption rules. Non-zero counters mean the rule is being used."
iptables -t mangle -L OUTPUT -v -n
echo

# --- 4. Live Tests ---
echo "--- [4] Live Connectivity Tests ---"
echo "Attempting to resolve google.com using resolvectl (to test systemd-resolved directly)..."
resolvectl query google.com
echo
echo "Attempting to trace the route to a DNS server (1.1.1.1 on port 853 for DoT)..."
echo "This will show if the connection is going via the tunnel (e.g., 10.192.0.1) or the real gateway."
if ! command -v traceroute &> /dev/null; then
    echo "---"
    echo "WARNING: 'traceroute' command not found. This test will be skipped."
    echo "Please install it to enable this test: sudo apt-get update && sudo apt-get install -y traceroute"
    echo "---"
else
    traceroute -T -p 853 -n 1.1.1.1
fi
echo

echo "==========================================================================="
echo "                             Diagnosis Complete"
echo "==========================================================================="
echo "Key things to look for:"
echo "1. In [1], ensure 'DNSOverTLS' is 'yes' and servers are set correctly."
echo "2. In [2], there should be ONLY ONE 'default' route, via the 'tun0' device."
echo "3. In [3], after trying to browse, the 'pkts' count should be > 0 for the DNS"
echo "   server rules (e.g., for destination 1.1.1.1 on dpt 853)."
echo "4. In [4], the traceroute should show your system's REAL gateway as the first"
echo "   hop, NOT the tunnel IP (10.192.0.1)."
echo "==========================================================================="
      