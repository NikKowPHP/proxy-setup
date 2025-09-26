#!/bin/bash

# ==============================================================================
#                      Network & DNS Diagnostics Script
# ==============================================================================
# This script runs a series of non-destructive checks to gather information
# about the system's network configuration, DNS resolution, and proxy
# connectivity to help diagnose issues with the proxy tunnel scripts.

# Run this script in a "clean" state (BEFORE running start_proxy.sh)
# and with sudo: `sudo ./diagnose_network.sh`

# --- Pre-flight Checks ---
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Please use 'sudo ./diagnose_network.sh'"
   exit 1
fi

echo "================================================================================"
echo "          STARTING NETWORK & DNS DIAGNOSTICS"
echo "================================================================================"

# --- Section 1: System Prerequisites ---
echo
echo "--- Checking for required tools... ---"
command -v dig &> /dev/null && echo "[OK] 'dig' is installed." || echo "[FAIL] 'dig' is not installed. Please install dnsutils."
command -v curl &> /dev/null && echo "[OK] 'curl' is installed." || echo "[FAIL] 'curl' is not installed."
command -v resolvectl &> /dev/null && echo "[OK] 'resolvectl' is installed." || echo "[FAIL] 'resolvectl' is not installed (system may not use systemd-resolved)."

# --- Section 2: General Network Connectivity ---
echo
echo "--- General Network Connectivity ---"
echo "-> Interfaces and IP Addresses (ip addr):"
ip addr
echo
echo "-> Kernel Routing Table (ip route):"
ip route
echo
echo "-> Policy Routing Rules (ip rule list):"
ip rule list
echo
echo "-> Exemption Routing Table (ip route show table 100):"
ip route show table 100
echo
echo "-> Pinging external IP (8.8.8.8) to test basic connectivity (bypasses DNS):"
ping -c 3 8.8.8.8

# --- Section 3: DNS Resolver Status ---
echo
echo "--- DNS Resolver Status (systemd-resolved) ---"
echo "-> Status of systemd-resolved service:"
systemctl status systemd-resolved --no-pager | cat # Use cat to avoid interactive pager
echo
echo "-> Contents of /etc/resolv.conf:"
cat /etc/resolv.conf
echo
echo "-> Detailed resolver status (resolvectl status):"
resolvectl status

# --- Section 4: DNS Resolution Tests ---
echo
echo "--- DNS Resolution Tests ---"
echo "-> Testing resolution for 'google.com' using system resolver:"
dig google.com +short
echo
echo "-> Testing resolution for 'google.com' DIRECTLY via 1.1.1.1:"
dig google.com @1.1.1.1 +short
echo
echo "-> Testing resolution for PROBLEMATIC HOST 'aws-0-us-west-1.pooler.supabase.com' using system resolver:"
dig aws-0-us-west-1.pooler.supabase.com +short
echo
echo "-> Testing resolution for PROBLEMATIC HOST 'aws-0-us-west-1.pooler.supabase.com' DIRECTLY via 1.1.1.1:"
dig aws-0-us-west-1.pooler.supabase.com @1.1.1.1 +short

# --- Section 5: Firewall Configuration ---
echo
echo "--- Firewall Rules (iptables) ---"
echo "-> Mangle Table (used by proxy scripts):"
iptables -t mangle -L -v -n
echo
echo "-> Filter Table (main firewall):"
iptables -L -v -n
echo
echo "-> NAT Table:"
iptables -t nat -L -v -n

# --- Section 6: Proxy Server Connectivity ---
PROXY_IP="172.16.2.254"
PROXY_PORT="3128"
echo
echo "--- Proxy Server Connectivity Test ---"
echo "-> Attempting to connect to google.com via proxy ${PROXY_IP}:${PROXY_PORT}..."
# We use -v for verbose output, --connect-timeout to avoid long hangs.
# The output will show if the TCP handshake with the proxy completes.
curl -v --connect-timeout 5 -x "http://${PROXY_IP}:${PROXY_PORT}" https://google.com &> /tmp/proxy_test.log
if grep -q "Connected to ${PROXY_IP}" /tmp/proxy_test.log; then
    echo "[SUCCESS] Successfully established a TCP connection to the proxy server."
    if grep -q "HTTP/1.1 200 OK" /tmp/proxy_test.log || grep -q "HTTP/2 200" /tmp/proxy_test.log; then
        echo "[SUCCESS] Proxy successfully fetched the page."
    else
        echo "[WARNING] Connected to proxy, but failed to fetch page. Proxy may require authentication or be misconfigured."
    fi
else
    echo "[FAIL] Could not establish a TCP connection to the proxy server at ${PROXY_IP}:${PROXY_PORT}."
fi
echo "-> Verbose curl output logged to /tmp/proxy_test.log"


echo
echo "================================================================================"
echo "          DIAGNOSTICS COMPLETE"
echo "================================================================================"
      