#!/bin/bash

# ==============================================================================
#           TUN2SOCKS - System-Wide Proxy Tunnel Start Script
# ==============================================================================
# This script configures the system to route all traffic through an HTTP proxy
# using tun2socks, including robust DNS-over-TLS configuration, exemptions
# for critical services like the database, and native Docker Proxy injection.

# --- Script Configuration (Edit these variables if your setup changes) ---
PROXY_IP="172.16.2.254"
PROXY_PORT="3128"
PHYSICAL_INTERFACE="enp2s0" # Your main network card (e.g., eth0, wlan0)
VIRTUAL_TUN_DEVICE="tun0"
VIRTUAL_TUN_IP="10.0.0.1" # Use a standard RFC1918 private IP for the virtual device
DNS_SERVERS="1.1.1.1 8.8.8.8"
DNS_SERVERS_WITH_HOSTNAMES="1.1.1.1#cloudflare-dns.com 8.8.8.8#dns.google"
# Add all database hosts to exempt here
DB_HOSTS=(
  "aws-0-us-west-1.pooler.supabase.com"
  "aws-0-eu-central-1.pooler.supabase.com"
  "oscdn.apple.com"
)

# --- Pre-flight Checks ---
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Please use 'sudo ./start_proxy.sh'"
   exit 1
fi

if ! ip route | grep -q '^default'; then
    echo "WARNING: No default gateway found. Attempting to restore it using the proxy IP as the gateway."
    ip route add default via "$PROXY_IP" dev "$PHYSICAL_INTERFACE"
    sleep 1 
    if ping -c 1 -W 3 8.8.8.8 &> /dev/null; then
        echo "SUCCESS: Default route has been restored. Continuing script..."
    else
        echo "CRITICAL ERROR: Failed to restore the default route automatically."
        echo "Please check your physical network connection and try again."
        exit 1
    fi
fi

if ! command -v tun2socks &> /dev/null; then
    echo "tun2socks is not installed. Please install it first."
    exit 1
fi

if ! command -v dig &> /dev/null; then
    echo "'dig' command not found. Please install dnsutils (Debian/Ubuntu) or bind-utils (CentOS/RHEL)."
    exit 1
fi

echo "--- Starting System-Wide Proxy Tunnel Setup ---"

# --- 1. Pre-run Cleanup ---
echo "Performing pre-run cleanup..."
if [ -f /tmp/tun2socks.pid ]; then
    kill $(cat /tmp/tun2socks.pid) &> /dev/null
    rm -f /tmp/tun2socks.pid
fi
ip link del $VIRTUAL_TUN_DEVICE &> /dev/null
ip rule del priority 500 &> /dev/null
ip route flush table 100 &> /dev/null
iptables -t mangle -F OUTPUT &> /dev/null
echo "Cleanup complete."

# --- 2. Configure DNS ---
echo "Configuring DNS for DNS-over-TLS to bypass proxy DNS issues..."[ ! -f /etc/systemd/resolved.conf.backup ] && cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.backup[ ! -f /etc/NetworkManager/NetworkManager.conf.backup ] && cp /etc/NetworkManager/NetworkManager.conf /etc/NetworkManager/NetworkManager.conf.backup
sed -i -e '/^#?DNS=.*/d' -e '/^#?DNSOverTLS=.*/d' -e '/^#?DNSOverHTTPS=.*/d' /etc/systemd/resolved.conf
if ! grep -q -E "^\s*\[Resolve\]" /etc/systemd/resolved.conf; then echo -e "\n[Resolve]" >> /etc/systemd/resolved.conf; fi
sed -i "/\[Resolve\]/a DNS=${DNS_SERVERS_WITH_HOSTNAMES}\nDNSOverTLS=yes" /etc/systemd/resolved.conf
if ! grep -q "dns=none" /etc/NetworkManager/NetworkManager.conf; then sed -i '/\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf; fi
rm -f /etc/resolv.conf && ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
systemctl restart NetworkManager && systemctl restart systemd-resolved
sleep 3
if ! (resolvectl status | grep -q '+DNSOverTLS'); then
    echo "ERROR: Failed to activate DNS-over-TLS. Cannot continue."
    resolvectl status
    exit 1
fi
echo "DNS configured successfully."

# --- 3. Resolve DB Hosts for Exemption ---
DB_IPS=()
for HOST in "${DB_HOSTS[@]}"; do
    echo "Resolving database host IPs for $HOST..."
    RESOLVED_IPS=$(dig +time=2 +tries=1 +short $HOST | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    if [ -n "$RESOLVED_IPS" ]; then
        while IFS= read -r IP; do
            DB_IPS+=("$IP")
        done <<< "$RESOLVED_IPS"
    else
        echo "ERROR: Could not resolve database host IP for $HOST. Exiting."
        exit 1
    fi
done

# --- 4. Configure APT for Proxy ---
echo "Configuring APT to use HTTP proxy..."
cat > /etc/apt/apt.conf.d/99proxy.conf << EOL
Acquire::http::Proxy "http://${PROXY_IP}:${PROXY_PORT}";
Acquire::https::Proxy "http://${PROXY_IP}:${PROXY_PORT}";
EOL
echo "APT configured."

# --- 5. Configure Docker for Native Proxy Bypass (Method 2) ---
if command -v docker &> /dev/null; then
    echo "Configuring Docker to use HTTP proxy natively..."

    # 5.1 Configure Docker Daemon (handles 'docker pull')
    mkdir -p /etc/systemd/system/docker.service.d
    cat > /etc/systemd/system/docker.service.d/http-proxy.conf << EOL
[Service]
Environment="HTTP_PROXY=http://${PROXY_IP}:${PROXY_PORT}"
Environment="HTTPS_PROXY=http://${PROXY_IP}:${PROXY_PORT}"
Environment="NO_PROXY=localhost,127.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.supabase.co,.supabase.com,.pooler.supabase.com"
EOL
    systemctl daemon-reload
    systemctl restart docker

    # 5.2 Configure Docker Client (handles 'docker-compose build' and container proxy injection)
    if [ -n "$SUDO_USER" ]; then
        USER_HOME=$(eval echo ~$SUDO_USER)
    else
        USER_HOME=$HOME
    fi

    DOCKER_DIR="$USER_HOME/.docker"
    DOCKER_CONFIG="$DOCKER_DIR/config.json"
    mkdir -p "$DOCKER_DIR"

    # Backup existing config to avoid erasing logins (auths)
    if [ -f "$DOCKER_CONFIG" ]; then
        cp "$DOCKER_CONFIG" "$DOCKER_CONFIG.proxy_backup"
    fi

    # Safely inject proxy settings using python
    if command -v python3 &> /dev/null; then
        python3 -c '
import json, sys, os
conf_path = sys.argv[1]
proxy_ip = sys.argv[2]
proxy_port = sys.argv[3]
try:
    with open(conf_path, "r") as f:
        data = json.load(f)
except:
    data = {}
if "proxies" not in data:
    data["proxies"] = {}
data["proxies"]["default"] = {
    "httpProxy": f"http://{proxy_ip}:{proxy_port}",
    "httpsProxy": f"http://{proxy_ip}:{proxy_port}",
    "noProxy": "localhost,127.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.supabase.co,.supabase.com,.pooler.supabase.com"
}
with open(conf_path, "w") as f:
    json.dump(data, f, indent=2)
' "$DOCKER_CONFIG" "$PROXY_IP" "$PROXY_PORT"
        chown -R ${SUDO_USER:-root}:${SUDO_USER:-root} "$DOCKER_DIR"
        echo "Docker Daemon and Client configured natively."
    else
        echo "WARNING: python3 not found. Could not configure Docker client safely."
    fi
else
    echo "Docker not found on system. Skipping Docker configuration."
fi

# --- 6. Create Virtual Device & Adjust Kernel Parameters ---
echo "Creating virtual network device..."
ip tuntap add dev $VIRTUAL_TUN_DEVICE mode tun

echo "Temporarily disabling Reverse Path Filtering..."
INTERFACES_TO_MODIFY=("all" "$PHYSICAL_INTERFACE" "$VIRTUAL_TUN_DEVICE")
for iface in "${INTERFACES_TO_MODIFY[@]}"; do
    if [ -e "/proc/sys/net/ipv4/conf/$iface/rp_filter" ]; then
        original_rp_filter=$(cat /proc/sys/net/ipv4/conf/$iface/rp_filter)
        echo "$original_rp_filter" > "/tmp/rp_filter_${iface}.backup"
        echo 0 > /proc/sys/net/ipv4/conf/$iface/rp_filter
    fi
done

# --- 7. Configure Routing for Exemptions ---
echo "Configuring direct routing for exemptions..."
DEFAULT_ROUTE_LINE=$(ip route | grep '^default' | head -n 1)
if [ -z "$DEFAULT_ROUTE_LINE" ]; then echo "ERROR: Could not determine default route." && exit 1; fi
ORIGINAL_GATEWAY=$(echo "$DEFAULT_ROUTE_LINE" | awk '{print $3}')
ORIGINAL_INTERFACE=$(echo "$DEFAULT_ROUTE_LINE" | awk '{print $5}')
echo "$ORIGINAL_GATEWAY" > /tmp/original_gateway.txt
echo "$ORIGINAL_INTERFACE" > /tmp/original_interface.txt

EXEMPT_IPS=("$PROXY_IP" $DNS_SERVERS "${DB_IPS[@]}")
UNIQUE_EXEMPT_IPS=($(echo "${EXEMPT_IPS[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))

ROUTE_FILE="/tmp/proxy_added_routes.txt"
> "$ROUTE_FILE"

for IP in "${UNIQUE_EXEMPT_IPS[@]}"; do
    echo "-> Exempting $IP via direct route"
    ip route add "$IP" via "$ORIGINAL_GATEWAY"
    echo "$IP" >> "$ROUTE_FILE"
done

# --- 8. Start tun2socks and Configure Main Routing ---
echo "Starting tun2socks process..."
tun2socks -device "tun://$VIRTUAL_TUN_DEVICE" \
          -proxy "http://$PROXY_IP:$PROXY_PORT" &
T2S_PID=$!
echo $T2S_PID > /tmp/tun2socks.pid
echo "tun2socks started with PID $T2S_PID."
sleep 2

ip link set dev $VIRTUAL_TUN_DEVICE up
ip addr replace ${VIRTUAL_TUN_IP}/24 dev $VIRTUAL_TUN_DEVICE

ip route del default
ip route add default via $VIRTUAL_TUN_IP
ip route flush cache

# --- 9. Final Verification ---
echo -e "\n=========================================================="
echo "          SUCCESS: PROXY TUNNEL IS NOW ACTIVE"
echo "=========================================================="
ip route | head -n 1
curl -A "Mozilla/5.0" --connect-timeout 5 https://icanhazip.com || echo "Test failed, but tunnel may still be working."