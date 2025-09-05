#!/bin/bash

# ==============================================================================
#           TUN2SOCKS - System-Wide Proxy Tunnel Start Script
# ==============================================================================
# This script configures the system to route all traffic through an HTTP proxy
# using tun2socks, including robust DNS-over-TLS configuration.

# --- Script Configuration (Edit these variables if your setup changes) ---
PROXY_IP="172.16.2.254"
PROXY_PORT="3128"
PHYSICAL_INTERFACE="enp2s0" # Your main network card (e.g., eth0, wlan0)
VIRTUAL_TUN_DEVICE="tun0"
VIRTUAL_TUN_IP="192.168.255.1"
DNS_SERVERS="1.1.1.1 8.8.8.8"
DNS_SERVERS_WITH_HOSTNAMES="1.1.1.1#cloudflare-dns.com 8.8.8.8#dns.google"

# --- Pre-flight Checks ---
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Please use 'sudo ./start_proxy.sh'"
   exit 1
fi

echo "--- Starting System-Wide Proxy Tunnel Setup ---"

# --- 1. Install tun2socks (if not present) ---
if ! command -v tun2socks &> /dev/null; then
    echo "tun2socks not found. Installing gvisor-tun2socks..."
    wget -q --show-progress -O /tmp/tun2socks-linux-amd64 https://github.com/google/gvisor-tun2socks/releases/download/v0.6.0/tun2socks-linux-amd64
    if [[ $? -ne 0 ]]; then echo "Failed to download tun2socks. Exiting."; exit 1; fi
    chmod +x /tmp/tun2socks-linux-amd64
    mv /tmp/tun2socks-linux-amd64 /usr/local/bin/tun2socks
    echo "tun2socks installed successfully."
fi

# --- 2. Configure DNS for DNS-over-TLS (DoT) ---
echo "Configuring DNS for DNS-over-TLS to bypass proxy DNS issues..."

# Backup original configs if they haven't been backed up already
[ ! -f /etc/systemd/resolved.conf.backup ] && cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.backup
[ ! -f /etc/NetworkManager/NetworkManager.conf.backup ] && cp /etc/NetworkManager/NetworkManager.conf /etc/NetworkManager/NetworkManager.conf.backup

# 1. Delete any existing DNS-related lines to avoid conflicts.
sed -i -e '/^#?DNS=.*/d' \
       -e '/^#?DNSOverTLS=.*/d' \
       -e '/^#?DNSOverHTTPS=.*/d' \
       /etc/systemd/resolved.conf

# 2. Ensure the [Resolve] section header exists.
if ! grep -q -E "^\s*\[Resolve\]" /etc/systemd/resolved.conf; then
    echo "" >> /etc/systemd/resolved.conf
    echo "[Resolve]" >> /etc/systemd/resolved.conf
fi

# 3. Add the desired settings under the [Resolve] section.
sed -i "/\[Resolve\]/a DNS=${DNS_SERVERS_WITH_HOSTNAMES}" /etc/systemd/resolved.conf
sed -i "/\[Resolve\]/a DNSOverTLS=yes" /etc/systemd/resolved.conf

# Configure NetworkManager to leave DNS alone
if ! grep -q "dns=none" /etc/NetworkManager/NetworkManager.conf; then
    sed -i '/\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf
fi

# Force resolv.conf to use the systemd stub resolver
rm -f /etc/resolv.conf
ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Restart services to apply changes
echo "Restarting network services..."
systemctl restart NetworkManager
systemctl restart systemd-resolved

# Verify DoT is active
sleep 3 # Give services time to start and establish a DoT connection
echo "Verifying DNS-over-TLS status..."
GLOBAL_STATUS_OUTPUT=$(resolvectl status | grep -A 2 '^Global')
if ! (echo "${GLOBAL_STATUS_OUTPUT}" | grep -q '+DNSOverTLS'); then
    echo "ERROR: Failed to activate DNS-over-TLS. Verification check failed. Cannot continue."
    echo "Full resolvectl status provided below for debugging:"
    resolvectl status # Show full status on failure
    exit 1
fi
echo "DNS configured successfully."

# --- 3. Start tun2socks in the background ---
echo "Starting tun2socks process..."
tun2socks -device "tun://$VIRTUAL_TUN_DEVICE" \
          -interface "$PHYSICAL_INTERFACE" \
          -proxy "http://$PROXY_IP:$PROXY_PORT" &

# Save the Process ID (PID) so we can stop it later
T2S_PID=$!
echo $T2S_PID > /tmp/tun2socks.pid
echo "tun2socks started with PID $T2S_PID."
sleep 2 # Give the tun device time to be created

# --- 4. Configure System Routing ---
echo "Configuring network routing table..."

# Save original gateway for the stop script and for creating exemptions
ip route | grep default | awk '{print $3}' > /tmp/original_gateway.txt
ORIGINAL_GATEWAY=$(cat /tmp/original_gateway.txt)
if [ -z "$ORIGINAL_GATEWAY" ]; then
    echo "ERROR: Could not determine original gateway. Cannot create exemptions."
    exit 1
fi

# Activate the virtual interface and assign IP. Use 'replace' to be idempotent.
ip link set dev $VIRTUAL_TUN_DEVICE up
ip addr replace ${VIRTUAL_TUN_IP}/24 dev $VIRTUAL_TUN_DEVICE

# Add specific routes for proxy and DNS to go out the physical device (prevents loop)
# Using 'replace' is idempotent and avoids "File exists" errors on re-runs.
echo "Adding route exemptions for proxy and DNS servers..."
ip route replace $PROXY_IP via $ORIGINAL_GATEWAY
for DNS_SERVER in $DNS_SERVERS; do
    echo "Exempting DNS server: $DNS_SERVER"
    ip route replace $DNS_SERVER via $ORIGINAL_GATEWAY
done

# Delete the old default route and add the new one via our tunnel
ip route del default
ip route add default via $VIRTUAL_TUN_IP

# --- 5. Final Verification ---
echo ""
echo "=========================================================="
echo "          SUCCESS: PROXY TUNNEL IS NOW ACTIVE"
echo "=========================================================="
echo "Your new default route is:"
ip route | head -n 1
echo ""
echo "Testing connection (Note: this may fail if proxy blocks 'curl' user-agent)..."
curl -A "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/117.0" --connect-timeout 5 https://icanhazip.com || echo "Test failed, but tunnel may still be working for browsers."
echo "To stop the tunnel, run: sudo ./stop_proxy.sh"
      