#!/bin/sh
# ==============================================================================
# Autonomous JioFi 2 M2S Wi-Fi Range Extender & Repeater Daemon
# Uplink: OnePlus Hotspot ("daijizaiten" / "nomoreno") on Channel 6
# Downlink AP: "JioFiRepeater" on Channel 6
# ==============================================================================

# Ignore SIGHUP so disconnecting USB/terminal never stops this daemon
trap '' HUP

LOG="/var/volatile/repeater.log"
exec > "$LOG" 2>&1

PIDFILE="/var/volatile/run/repeater.pid"
mkdir -p /var/volatile/run 2>/dev/null
if [ -f "$PIDFILE" ]; then
    OLDPID=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$OLDPID" ] && [ -d "/proc/$OLDPID" ]; then
        exit 0
    fi
fi
echo "$$" > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT INT TERM

CONF_FILE="/ww_data/repeater.conf"
[ -f "$CONF_FILE" ] && . "$CONF_FILE"

SSID="${SSID:-daijizaiten}"
PASS="${PASS:-nomoreno}"
CHAN="${CHAN:-6}"
MAC="${MAC:-BC:8A:E8:13:21:27}"
FALLBACK_IP="${FALLBACK_IP:-10.21.0.137}"
FALLBACK_GW="${FALLBACK_GW:-10.21.0.48}"
HOSTNAME="${HOSTNAME:-JioFiRepeater}"

echo "[$(date)] === Autonomous JioFi Extender Starting ==="
echo "[$(date)] Target Hotspot: $SSID, Virtual MAC: $MAC, Channel: $CHAN, Hostname: $HOSTNAME"

# 0. Performance tuning: Lock CPU frequency to maximum (1.305 GHz)
echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null

# Kill carrier bloatware to free up Qualcomm CPU for NAT routing
killall -9 cwmpc patrol volte_mal embms_mal hf_server miniupnpd 2>/dev/null

# Tune kernel TCP/network buffers
sysctl -w net.core.rmem_max=2097152 net.core.wmem_max=2097152 net.core.netdev_max_backlog=5000 2>/dev/null
sysctl -w net.ipv4.tcp_rmem='4096 87380 2097152' net.ipv4.tcp_wmem='4096 65536 2097152' 2>/dev/null

# Set system hostname
hostname "$HOSTNAME" 2>/dev/null
echo "$HOSTNAME" > /etc/hostname 2>/dev/null

# Initial state: offline (Tower LED red)
rm -f /tmp/repeater_online

# 1. Wait for base Wi-Fi interface (wlan0)
echo "[$(date)] Waiting for wlan0 interface..."
for i in $(seq 1 45); do
    if [ -d /sys/class/net/wlan0 ]; then
        echo "[$(date)] wlan0 detected after ${i}s."
        break
    fi
    sleep 1
done

if [ ! -d /sys/class/net/wlan0 ]; then
    echo "[$(date)] FATAL: wlan0 interface not available!"
    exit 1
fi

# Allow sysconf, iwcontrol, and wscd to settle
sleep 6

# Optimize radio parameters on physical AP & virtual STA (Overdrive Driver Tuning)
# 1. Force 40 MHz width and disable neighbor coexistence fallback
iwpriv wlan0 set_mib use40M=1 2>/dev/null
iwpriv wlan0 set_mib coexist=0 2>/dev/null

# 2. Enable Short Guard Interval (11% speed boost)
iwpriv wlan0 set_mib shortGI20M=1 2>/dev/null
iwpriv wlan0 set_mib shortGI40M=1 2>/dev/null

# 3. Maximize Frame Aggregation (Reduces Wi-Fi overhead)
iwpriv wlan0 set_mib max_xmitbuf_agg=1 2>/dev/null
iwpriv wlan0 set_mib max_recvbuf_agg=1 2>/dev/null
iwpriv wlan0 set_mib qos_enable=1 2>/dev/null
iwpriv wlan0 set_mib ampdu=1 2>/dev/null
iwpriv wlan0 set_mib amsdu=1 2>/dev/null

# 4. Disable Wi-Fi Power Saving (Stops latency spikes)
iwpriv wlan0 set_mib ps_level=0 2>/dev/null

# Ensure base radio channel matches target channel
CUR_CHAN=$(cat /proc/wlan0/mib_rf 2>/dev/null | grep "dot11channel:" | awk '{print $2}')
if [ -n "$CUR_CHAN" ] && [ "$CUR_CHAN" != "$CHAN" ]; then
    echo "[$(date)] Switching base radio from Channel $CUR_CHAN to Channel $CHAN..."
    iwpriv wlan0 set_mib switch_chan=1,"$CHAN" 2>/dev/null
    sleep 2
fi

# Configure virtual STA interface
ifconfig wlan0-vxd hw ether "$MAC" 2>/dev/null
ifconfig wlan0-vxd up 2>/dev/null

# Apply MTU 1420 across all interfaces to match LTE/OnePlus uplink
ifconfig wlan0-vxd mtu 1420 2>/dev/null
ifconfig br0 mtu 1420 2>/dev/null
ifconfig wlan0 mtu 1420 2>/dev/null

apply_networking_rules() {
    echo 1 > /proc/sys/net/ipv4/ip_forward

    iptables -P FORWARD ACCEPT 2>/dev/null
    iptables -F FORWARD 2>/dev/null
    iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
    iptables -A FORWARD -i br0 -o wlan0-vxd -j ACCEPT 2>/dev/null
    iptables -A FORWARD -i wlan0-vxd -o br0 -j ACCEPT 2>/dev/null

    iptables -P INPUT ACCEPT 2>/dev/null
    iptables -A INPUT -i br0 -j ACCEPT 2>/dev/null
    iptables -A INPUT -i lo -j ACCEPT 2>/dev/null

    iptables -P OUTPUT ACCEPT 2>/dev/null

    iptables -t nat -D POSTROUTING -o wlan0-vxd -j MASQUERADE 2>/dev/null
    iptables -t nat -A POSTROUTING -o wlan0-vxd -j MASQUERADE 2>/dev/null

    iptables -t nat -D PREROUTING -i br0 -p udp --dport 53 -j DNAT --to-destination 8.8.8.8:53 2>/dev/null
    iptables -t nat -A PREROUTING -i br0 -p udp --dport 53 -j DNAT --to-destination 8.8.8.8:53 2>/dev/null
    iptables -t nat -D PREROUTING -i br0 -p tcp --dport 53 -j DNAT --to-destination 8.8.8.8:53 2>/dev/null
    iptables -t nat -A PREROUTING -i br0 -p tcp --dport 53 -j DNAT --to-destination 8.8.8.8:53 2>/dev/null
}

associate_once() {
    if cat /proc/wlan0-vxd/sta_keyinfo 2>/dev/null | grep -q "keyInCam: yes"; then
        return 0
    fi

    # Configure 802.11n high-throughput, QoS, aggregation, and WPA2-PSK parameters
    iwpriv wlan0-vxd set_mib band=11 2>/dev/null
    iwpriv wlan0-vxd set_mib nat25_disable=1 2>/dev/null
    iwpriv wlan0-vxd set_mib swcrypto=0 2>/dev/null
    iwpriv wlan0-vxd set_mib ps_level=0 2>/dev/null
    iwpriv wlan0-vxd set_mib max_xmitbuf_agg=1 2>/dev/null
    iwpriv wlan0-vxd set_mib max_recvbuf_agg=1 2>/dev/null
    iwpriv wlan0-vxd set_mib qos_enable=1 2>/dev/null
    iwpriv wlan0-vxd set_mib shortGI20M=1 2>/dev/null
    iwpriv wlan0-vxd set_mib shortGI40M=1 2>/dev/null
    iwpriv wlan0-vxd set_mib use40M=1 2>/dev/null
    iwpriv wlan0-vxd set_mib ampdu=1 2>/dev/null
    iwpriv wlan0-vxd set_mib amsdu=1 2>/dev/null
    iwpriv wlan0-vxd set_mib lgyEncRstrct=0 2>/dev/null
    iwpriv wlan0-vxd set_mib coexist=0 2>/dev/null
    iwpriv wlan0-vxd set_mib encmode=4 2>/dev/null
    iwpriv wlan0-vxd set_mib wpa_cipher=0 2>/dev/null
    iwpriv wlan0-vxd set_mib wpa2_cipher=8 2>/dev/null
    iwpriv wlan0-vxd set_mib psk_enable=2 2>/dev/null
    iwpriv wlan0-vxd set_mib passphrase="$PASS" 2>/dev/null
    iwpriv wlan0-vxd set_mib ssid="$SSID" 2>/dev/null

    # Trigger site survey on physical radio to scan and populate bss_desc
    iwpriv wlan0 at_ss 2>/dev/null
    sleep 3

    # Trigger association
    iwpriv wlan0-vxd at_join "$SSID" 2>/dev/null

    # Wait up to 18s for 4-way handshake to complete
    for s in $(seq 1 18); do
        sleep 1
        if cat /proc/wlan0-vxd/sta_keyinfo 2>/dev/null | grep -q "keyInCam: yes"; then
            return 0
        fi
    done
    return 1
}

connect_uplink() {
    echo "[$(date)] Attempting association to '$SSID' on Channel $CHAN..."
    ATTEMPTS=0
    while true; do
        ATTEMPTS=$((ATTEMPTS + 1))
        rm -f /tmp/repeater_online
        if associate_once; then
            echo "[$(date)] Association successful (keyInCam: yes) on attempt $ATTEMPTS!"
            break
        fi
        echo "[$(date)] Association attempt $ATTEMPTS failed, retrying in 2s..."
        sleep 2
    done

    # Broadcast Hostname via DHCP Option 12 & obtain lease from OnePlus
    echo "[$(date)] Announcing hostname '$HOSTNAME' to OnePlus DHCP server..."
    busybox udhcpc -i wlan0-vxd -n -q -t 2 -T 2 -r "$FALLBACK_IP" -x hostname:"$HOSTNAME" -F "$HOSTNAME" -s /ww_data/udhcpc.script >/dev/null 2>&1

    # Apply fast static IP if DHCP did not assign default route
    if ! ip route show | grep -q "^default via .* dev wlan0-vxd"; then
        echo "[$(date)] Setting static IP fallback ($FALLBACK_IP, GW: $FALLBACK_GW)..."
        ifconfig wlan0-vxd "$FALLBACK_IP" netmask 255.255.255.0 up 2>/dev/null
        while /sbin/route del default dev wlan0-vxd 2>/dev/null; do :; done
        /sbin/route add default gw "$FALLBACK_GW" dev wlan0-vxd 2>/dev/null
    fi

    # Set MTU 1420 & TCP advmss 1380 on routes to eliminate fragmentation black-holes
    ip route change default via "$FALLBACK_GW" dev wlan0-vxd mtu 1420 advmss 1380 2>/dev/null
    ip route change 192.168.0.0/16 dev br0 mtu 1420 advmss 1380 2>/dev/null

    echo "nameserver $FALLBACK_GW" > /var/volatile/resolv.conf
    echo "nameserver 8.8.8.8" >> /var/volatile/resolv.conf
    cp -f /var/volatile/resolv.conf /app/var/resolv.conf 2>/dev/null
    [ -f /etc/resolv.conf ] && cp -f /var/volatile/resolv.conf /etc/resolv.conf 2>/dev/null

    echo "[$(date)] Uplink configured. Default Gateway: $FALLBACK_GW"
    apply_networking_rules

    # Ensure wlan0 is bridged into br0
    ifconfig wlan0 up 2>/dev/null
    brctl addif br0 wlan0 2>/dev/null

    # Verify internet connectivity
    sleep 1
    if ping -c 1 -W 2 -I wlan0-vxd "$FALLBACK_GW" >/dev/null 2>&1 || ping -c 1 -W 2 -I wlan0-vxd 8.8.8.8 >/dev/null 2>&1; then
        echo "[$(date)] Internet verified! Setting repeater ONLINE (LED green)."
        touch /tmp/repeater_online
    else
        echo "[$(date)] WARNING: Initial ping check unconfirmed."
    fi
}

# Initial connection
connect_uplink

echo "[$(date)] Entering autonomous repeater supervision loop..."
FAIL_STRIKES=0

while true; do
    sleep 5

    KEY_OK=0
    if cat /proc/wlan0-vxd/sta_keyinfo 2>/dev/null | grep -q "keyInCam: yes"; then
        KEY_OK=1
    fi

    ONLINE=0
    if [ "$KEY_OK" -eq 1 ]; then
        if ping -c 1 -W 2 -I wlan0-vxd "$FALLBACK_GW" >/dev/null 2>&1 || ping -c 1 -W 2 -I wlan0-vxd 8.8.8.8 >/dev/null 2>&1; then
            ONLINE=1
        fi
    fi

    if [ "$ONLINE" -eq 1 ]; then
        FAIL_STRIKES=0
        [ ! -f /tmp/repeater_online ] && touch /tmp/repeater_online
    else
        FAIL_STRIKES=$((FAIL_STRIKES + 1))
        echo "[$(date)] Health check failed ($FAIL_STRIKES/3). Key: $KEY_OK"

        if [ "$FAIL_STRIKES" -ge 3 ]; then
            echo "[$(date)] Connection lost! Re-establishing uplink..."
            rm -f /tmp/repeater_online
            connect_uplink
            FAIL_STRIKES=0
        fi
    fi
done
