#!/usr/bin/env bash
# ==============================================================================
# JioFi 2 (M2S) Wi-Fi Repeater Uninstaller & Stock Restore
# ==============================================================================

set -e

echo "=========================================================="
echo "    JioFi 2 (M2S) Repeater Uninstaller                    "
echo "=========================================================="
echo ""

ADB_CMD=""
if command -v adb >/dev/null 2>&1; then
    ADB_CMD="adb"
elif [ -f "$HOME/platform-tools/adb" ]; then
    ADB_CMD="$HOME/platform-tools/adb"
else
    echo "[-] Error: 'adb' command not found."
    exit 1
fi

"$ADB_CMD" wait-for-device
DEVICE_ID=$("$ADB_CMD" devices | awk 'NR>1 && $2=="device" {print $1; exit}')

PREFIX=""
TEST_OUT=$("$ADB_CMD" -s "$DEVICE_ID" shell "id" 2>&1 || true)
if echo "$TEST_OUT" | grep -q "uid=0"; then
    PREFIX=""
else
    PREFIX="f381a9a20579d908; "
fi

adb_exec() {
    "$ADB_CMD" -s "$DEVICE_ID" shell "${PREFIX}$*"
}

echo "[*] Stopping repeater and LED daemons..."
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
"

echo "[*] Restoring original stock key_led binary..."
adb_exec "
if [ -f /app/bin/key_led.orig ]; then
    cp -f /app/bin/key_led.orig /app/bin/key_led
    chmod 755 /app/bin/key_led
    nohup /app/bin/key_led >/dev/null 2>&1 &
fi
"

echo "[*] Removing repeater autostart from appautorun.sh..."
adb_exec "
if [ -f /etc/init.d/appautorun.sh.orig ]; then
    cp -f /etc/init.d/appautorun.sh.orig /etc/init.d/appautorun.sh
else
    sed -i '/Autonomous Wi-Fi Repeater Startup/d' /etc/init.d/appautorun.sh 2>/dev/null || true
    sed -i '/repeater.sh/d' /etc/init.d/appautorun.sh 2>/dev/null || true
fi
sync
"

echo "[*] Removing repeater scripts..."
adb_exec "
rm -f /ww_data/repeater.sh /ww_bata/repeater.sh /ww_data/udhcpc.script /tmp/repeater_online /var/volatile/run/repeater.pid 2>/dev/null || true
sync
"

echo ""
echo "[✔] Stock firmware configuration restored successfully."
