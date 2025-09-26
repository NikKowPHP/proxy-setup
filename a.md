```xml
<response>
  <reasoning>
    The user is reporting that `start_proxy.sh` fails during DNS resolution for a database host.
    The error log shows: `ERROR: Could not resolve database host IP for aws-0-us-west-1.pooler.supabase.com after 5 attempts. Exiting.`

    Looking at the `diagnose_network.sh` output, DNS resolution for that host works, but it returns a CNAME record before the A (IP address) records:
    ```
    -> Testing resolution for PROBLEMATIC HOST 'aws-0-us-west-1.pooler.supabase.com' using system resolver:
    pool-tcp-us-west-1-58aaa9f-fd46bdad3edd3d75.elb.us-west-1.amazonaws.com.
    52.8.172.168
    54.177.55.191
    ```

    The failing command in `start_proxy.sh` is:
    `IP=$(dig +time=2 +tries=1 +short $HOST | head -n 1 | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')`

    This command takes the first line of the `dig` output (`head -n 1`) and then checks if it's an IP address. When the first line is a CNAME, the `grep` fails, and the `IP` variable remains empty, causing the script to error out.

    The fix is to first filter for IP addresses with `grep` and then take the first result with `head -n 1`.

    My plan is:
    1.  Modify `start_proxy.sh` to correct the `dig` command's pipe order.
    2.  Create a `TASKS.md` file to track this task and mark it as complete, as one does not currently exist.
  </reasoning>
  <modifications>
    <file path="start_proxy.sh">
      <![CDATA[
#!/bin/bash

# ==============================================================================
#           TUN2SOCKS - System-Wide Proxy Tunnel Start Script
# ==============================================================================
# This script configures the system to route all traffic through an HTTP proxy
# using tun2socks, including robust DNS-over-TLS configuration and exemptions
# for critical services like the database.

# --- Script Configuration (Edit these variables if your setup changes) ---
PROXY_IP="172.16.2.254"
PROXY_PORT="3128"
PHYSICAL_INTERFACE="enp2s0" # Your main network card (e.g., eth0, wlan0)
VIRTUAL_TUN_DEVICE="tun0"
VIRTUAL_TUN_IP="192.18.255.1" # Corrected to a valid private IP range
DNS_SERVERS="1.1.1.1 8.8.8.8"
DNS_SERVERS_WITH_HOSTNAMES="1.1.1.1#cloudflare-dns.com 8.8.8.8#dns.google"
# Add all database hosts to exempt here
DB_HOSTS=(
  "aws-0-us-west-1.pooler.supabase.com"
  "aws-0-eu-central-1.pooler.supabase.com"
)

# --- Advanced Routing Configuration ---
EXEMPT_TABLE=100 # Routing table number for exemptions
FWMARK=1         # Firewall mark for exempted packets

# --- Pre-flight Checks ---
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Please use 'sudo ./start_proxy.sh'"
   exit 1
fi

if ! ip route | grep -q '^default'; then
    echo "CRITICAL ERROR: No default gateway found on your system."
    echo "This script requires a working internet connection to start."
    echo "Please restore your default route and try again."
    echo "You can check your routes with: ip route"
    echo "You may be able to fix this temporarily with: sudo ip route add default via <GATEWAY_IP> dev <INTERFACE>"
    exit 1
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

# --- 1. Pre-run Cleanup (for robustness) ---
echo "Performing pre-run cleanup..."
if [ -f /tmp/tun2socks.pid ]; then
    kill $(cat /tmp/tun2socks.pid) &> /dev/null
    rm -f /tmp/tun2socks.pid
fi
ip link del $VIRTUAL_TUN_DEVICE &> /dev/null
ip rule del fwmark $FWMARK table $EXEMPT_TABLE &> /dev/null
ip route flush table $EXEMPT_TABLE &> /dev/null
iptables -t mangle -F OUTPUT &> /dev/null
echo "Cleanup complete."

# --- 2. Configure DNS ---
echo "Configuring DNS for DNS-over-TLS to bypass proxy DNS issues..."
[ ! -f /etc/systemd/resolved.conf.backup ] && cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.backup
[ ! -f /etc/NetworkManager/NetworkManager.conf.backup ] && cp /etc/NetworkManager/NetworkManager.conf /etc/NetworkManager/NetworkManager.conf.backup
sed -i -e '/^#?DNS=.*/d' -e '/^#?DNSOverTLS=.*/d' -e '/^#?DNSOverHTTPS=.*/d' /etc/systemd/resolved.conf
if ! grep -q -E "^\s*\[Resolve\]" /etc/systemd/resolved.conf; then echo -e "\n[Resolve]" >> /etc/systemd/resolved.conf; fi
sed -i "/\[Resolve\]/a DNS=${DNS_SERVERS_WITH_HOSTNAMES}\nDNSOverTLS=yes" /etc/systemd/resolved.conf
if ! grep -q "dns=none" /etc/NetworkManager/NetworkManager.conf; then sed -i '/\[main\]/a dns=none' /etc/NetworkManager/NetworkManager.conf; fi
rm -f /etc/resolv.conf && ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
echo "Restarting network services..."
systemctl restart NetworkManager && systemctl restart systemd-resolved
sleep 3
echo "Verifying DNS-over-TLS status..."
if ! (resolvectl status | grep -q '+DNSOverTLS'); then
    echo "ERROR: Failed to activate DNS-over-TLS. Cannot continue."
    resolvectl status
    exit 1
fi
echo "DNS configured successfully."

# --- 3. Resolve DB Hosts for Exemption ---
DB_IPS=()
for HOST in "${DB_HOSTS[@]}"; do
    echo "Resolving database host IP for $HOST..."
    IP=""
    for i in {1..5}; do
        # Use a timeout for dig to avoid long hangs, and grep for an IP before taking the first line.
        IP=$(dig +time=2 +tries=1 +short $HOST | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
        if [ -n "$IP" ]; then
            break
        fi
        echo "DNS resolution failed for $HOST (attempt $i/5), retrying in 2 seconds..."
        sleep 2
    done

    if [ -z "$IP" ]; then
        echo "ERROR: Could not resolve database host IP for $HOST after 5 attempts. Exiting."
        exit 1
    fi
    echo "Database IP to be exempted: $IP"
    DB_IPS+=("$IP")
done

# --- 4. Configure APT for Proxy ---
echo "Configuring APT to use HTTP proxy..."
cat > /etc/apt/apt.conf.d/99proxy.conf << EOL
Acquire::http::Proxy "http://${PROXY_IP}:${PROXY_PORT}";
Acquire::https::Proxy "http://${PROXY_IP}:${PROXY_PORT}";
EOL
echo "APT configured."

# --- 5. Configure Policy-Based Routing for Exemptions ---
echo "Configuring policy-based routing for exemptions..."
DEFAULT_ROUTE_LINE=$(ip route | grep '^default' | head -n 1)
if [ -z "$DEFAULT_ROUTE_LINE" ]; then echo "ERROR: Could not determine default route." && exit 1; fi
ORIGINAL_GATEWAY=$(echo "$DEFAULT_ROUTE_LINE" | awk '{print $3}')
ORIGINAL_INTERFACE=$(echo "$DEFAULT_ROUTE_LINE" | awk '{print $5}')
echo "$ORIGINAL_GATEWAY" > /tmp/original_gateway.txt
echo "$ORIGINAL_INTERFACE" > /tmp/original_interface.txt

# STEP 1: Create a separate routing table that contains the original default route.
ip route add default via $ORIGINAL_GATEWAY dev $ORIGINAL_INTERFACE table $EXEMPT_TABLE

# STEP 2: Use iptables to "mark" any packet going to the proxy, DNS, or DB servers.
iptables -t mangle -A OUTPUT -d $PROXY_IP -j MARK --set-mark $FWMARK
for IP in "${DB_IPS[@]}"; do
    echo "Exempting database IP via policy route: $IP"
    iptables -t mangle -A OUTPUT -d $IP -j MARK --set-mark $FWMARK
done
for DNS_SERVER in $DNS_SERVERS; do
    echo "Exempting DNS server via policy route: $DNS_SERVER"
    iptables -t mangle -A OUTPUT -d $DNS_SERVER -j MARK --set-mark $FWMARK
done

# STEP 3: Create a routing rule that says "any packet with our mark must use our exempt table".
ip rule add fwmark $FWMARK table $EXEMPT_TABLE
ip route flush cache

# --- 6. Start tun2socks and Configure Main Routing ---
echo "Starting tun2socks process..."
ip tuntap add dev $VIRTUAL_TUN_DEVICE mode tun
tun2socks -device "tun://$VIRTUAL_TUN_DEVICE" \
          -interface "$PHYSICAL_INTERFACE" \
          -proxy "http://$PROXY_IP:$PROXY_PORT" &
T2S_PID=$!
echo $T2S_PID > /tmp/tun2socks.pid
echo "tun2socks started with PID $T2S_PID."
sleep 2

echo "Configuring main routing table..."
ip link set dev $VIRTUAL_TUN_DEVICE up
ip addr replace ${VIRTUAL_TUN_IP}/24 dev $VIRTUAL_TUN_DEVICE

# STEP 4: Change the main default route. All non-marked traffic will now go to the tunnel.
ip route del default
ip route add default via $VIRTUAL_TUN_IP

# --- 7. Final Verification ---
echo -e "\n=========================================================="
echo "          SUCCESS: PROXY TUNNEL IS NOW ACTIVE"
echo "=========================================================="
echo "Your new default route is:"
ip route | head -n 1
echo ""
echo "Testing connection..."
curl -A "Mozilla/5.0" --connect-timeout 5 https://icanhazip.com || echo "Test failed, but tunnel may still be working."
echo "To stop the tunnel, run: sudo ./stop_proxy.sh"
      ]]>
    </file>
    <file path="TASKS.md">
      <![CDATA[
# Tasks

- [x] Fix bug in `start_proxy.sh` where DB host resolution fails for hostnames that return a CNAME record.
      ]]>
    </file>
  </modifications>
</response>
```