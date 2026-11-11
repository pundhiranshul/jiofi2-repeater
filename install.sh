#!/usr/bin/env bash
# ==============================================================================
# JioFi 2 (M2S) Autonomous Wi-Fi Repeater Installer
# Target Hardware: PEG_M2S_W12 (Qualcomm MDM9607 + Realtek RTL8189ES)
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config/repeater.conf"

echo "=========================================================="
echo "    JioFi 2 (M2S) Wi-Fi Repeater Transformation Tool      "
echo "    Model: PEG_M2S_W12 (Qualcomm MDM9607 / RTL8189ES)     "
echo "=========================================================="
echo ""

# 1. Check for ADB
ADB_CMD=""
if command -v adb >/dev/null 2>&1; then
    ADB_CMD="adb"
elif [ -f "$HOME/platform-tools/adb" ]; then
    ADB_CMD="$HOME/platform-tools/adb"
else
    echo "[-] Error: 'adb' command not found."
    echo "    Please install Android Platform Tools (adb) and ensure it is in your PATH."
    exit 1
fi

echo "[+] Using ADB: $ADB_CMD"

# 2. Wait for Device
echo "[*] Waiting for JioFi 2 USB connection..."
"$ADB_CMD" wait-for-device

DEVICE_ID=$("$ADB_CMD" devices | awk 'NR>1 && $2=="device" {print $1; exit}')
if [ -z "$DEVICE_ID" ]; then
    echo "[-] Device attached but in offline or unauthorized state."
    echo "    Try replugging the USB cable."
    exit 1
fi

echo "[+] JioFi detected: $DEVICE_ID"

# 3. Detect ADB authentication key prefix if required by firmware
PREFIX=""
TEST_OUT=$("$ADB_CMD" -s "$DEVICE_ID" shell "id" 2>&1 || true)
if echo "$TEST_OUT" | grep -q "uid=0"; then
    PREFIX=""
    echo "[+] Standard root shell access confirmed."
else
    TEST_KEY=$("$ADB_CMD" -s "$DEVICE_ID" shell "f381a9a20579d908; id" 2>&1 || true)
    if echo "$TEST_KEY" | grep -q "uid=0"; then
        PREFIX="f381a9a20579d908; "
        echo "[+] Firmware challenge unlock key verified."
    else
        echo "[-] Error: Unable to acquire root shell via ADB."
        echo "    Output: $TEST_OUT"
        exit 1
    fi
fi

adb_exec() {
    "$ADB_CMD" -s "$DEVICE_ID" shell "${PREFIX}$*"
}

# 4. Configuration Setup
echo ""
echo "--- Repeater Configuration ---"
if [ -f "$CONFIG_FILE" ]; then
    echo "[*] Loading settings from config/repeater.conf..."
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi

read -r -p "Enter Target Uplink Wi-Fi SSID [${SSID:-daijizaiten}]: " INPUT_SSID
SSID="${INPUT_SSID:-${SSID:-daijizaiten}}"

read -r -p "Enter Target Uplink Wi-Fi Password [${PASS:-nomoreno}]: " INPUT_PASS
PASS="${INPUT_PASS:-${PASS:-nomoreno}}"

read -r -p "Enter 2.4 GHz Channel (1, 6, 11) [${CHAN:-6}]: " INPUT_CHAN
CHAN="${INPUT_CHAN:-${CHAN:-6}}"

read -r -p "Enter Repeater Hostname on Hotspot [${HOSTNAME:-JioFiRepeater}]: " INPUT_HOSTNAME
HOSTNAME="${INPUT_HOSTNAME:-${HOSTNAME:-JioFiRepeater}}"

# Save back to config
cat << EOF > "$CONFIG_FILE"
# ==============================================================================
# JioFi 2 (M2S) Wi-Fi Repeater Configuration
# ==============================================================================

SSID="$SSID"
PASS="$PASS"
CHAN="$CHAN"
MAC="${MAC:-BC:8A:E8:13:21:27}"
FALLBACK_IP="${FALLBACK_IP:-10.21.0.137}"
FALLBACK_GW="${FALLBACK_GW:-10.21.0.48}"
HOSTNAME="$HOSTNAME"
EOF

echo "[+] Configuration saved."

# 5. Back up Stock Binaries
echo "[*] Backing up original binaries on JioFi..."
adb_exec "[ ! -f /app/bin/key_led.orig ] && cp -f /app/bin/key_led /app/bin/key_led.orig 2>/dev/null || true"
adb_exec "[ ! -f /etc/init.d/appautorun.sh.orig ] && cp -f /etc/init.d/appautorun.sh /etc/init.d/appautorun.sh.orig 2>/dev/null || true"

# 6. Push Repeater Scripts
echo "[*] Installing repeater scripts to NAND flash..."
"$ADB_CMD" -s "$DEVICE_ID" push "${SCRIPT_DIR}/config/repeater.conf" /ww_data/repeater.conf
"$ADB_CMD" -s "$DEVICE_ID" push "${SCRIPT_DIR}/scripts/repeater.sh" /ww_data/repeater.sh
"$ADB_CMD" -s "$DEVICE_ID" push "${SCRIPT_DIR}/scripts/repeater.sh" /ww_bata/repeater.sh
"$ADB_CMD" -s "$DEVICE_ID" push "${SCRIPT_DIR}/scripts/udhcpc.script" /ww_data/udhcpc.script
"$ADB_CMD" -s "$DEVICE_ID" push "${SCRIPT_DIR}/scripts/key_led" /app/bin/key_led

adb_exec "chmod 755 /ww_data/repeater.sh /ww_bata/repeater.sh /ww_data/udhcpc.script /app/bin/key_led"

# 7. Configure Autostart on Boot
echo "[*] Configuring boot autostart..."
adb_exec "
if ! grep -q 'repeater.sh' /etc/init.d/appautorun.sh 2>/dev/null; then
    cat << 'AUTORUN' >> /etc/init.d/appautorun.sh

# Autonomous Wi-Fi Repeater Startup
if [ -x /ww_data/repeater.sh ]; then
    nohup /ww_data/repeater.sh >/dev/null 2>&1 &
fi
AUTORUN
fi
sync
"

# 8. Start Services
echo "[*] Starting daemons..."
adb_exec "
killall -9 sleep 2>/dev/null || true
OLD=\$(cat /var/volatile/run/repeater.pid 2>/dev/null || true)
[ -n \"\$OLD\" ] && kill -9 \$OLD 2>/dev/null || true

for p in /proc/[0-9]*; do
    if grep -q 'key_led' \$p/cmdline 2>/dev/null; then
        PID=\$(basename \$p)
        [ \"\$PID\" != \"\$\$\" ] && kill -9 \$PID 2>/dev/null || true
    fi
done

nohup /app/bin/key_led >/dev/null 2>&1 &
nohup /ww_data/repeater.sh >/dev/null 2>&1 &
sync
"

echo ""
echo "=========================================================="
echo "    [✔] JioFi 2 Repeater Installation Complete!           "
echo "=========================================================="
echo ""
echo "Status Indicators:"
echo "  - Tower Icon Solid GREEN : Connected to '$SSID' & Online"
echo "  - Tower Icon Solid RED   : Searching / Connecting"
echo "  - Wi-Fi Icon Solid GREEN : Downlink AP Active"
echo ""
echo "Power Control:"
echo "  - Long-press Power Button for 2s to cleanly turn off the unit."
echo ""
echo "The repeater will now start automatically whenever the JioFi boots."
