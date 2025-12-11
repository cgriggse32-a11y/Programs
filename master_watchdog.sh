#!/bin/bash

### ============================================================
###   MASTER SCANNER — SINGLE-RUN / WINDOWS-SAFE VERSION
### ============================================================

NETWORK_RANGE="192.168.1.0/24"

# Log files
SCAN_LOG="scan_results.txt"
NEW_DEVICES_LOG="new_devices.txt"

# Email/SMS placeholders
GMAIL_USER="cgriggse32@gmail.com"
GMAIL_PASS="YOUR_APP_PASSWORD"
SMS_TO="3046571689@tmomail.net"   # T‑Mobile gateway

echo "----------------------------------------"
echo "     MASTER SCANNER — SINGLE RUN"
echo "----------------------------------------"
echo

# Create log files if missing
[ ! -f "$SCAN_LOG" ] && touch "$SCAN_LOG"
[ ! -f "$NEW_DEVICES_LOG" ] && touch "$NEW_DEVICES_LOG"


### ============================================================
###  SEND EMAIL/SMS — FIXED FOR WINDOWS (NO /proc ERRORS)
### ============================================================
send_sms() {
    SUBJECT="Network Alert"
    MESSAGE="$1"

    TMP_FILE=$(mktemp)
    echo -e "Subject: $SUBJECT\n\n$MESSAGE" > "$TMP_FILE"

    curl -s --url "smtps://smtp.gmail.com:465" \
        --ssl-reqd \
        --mail-from "$GMAIL_USER" \
        --mail-rcpt "$SMS_TO" \
        --upload-file "$TMP_FILE" \
        --user "$GMAIL_USER:$GMAIL_PASS"

    rm -f "$TMP_FILE"
}


### ============================================================
###  NETWORK SCAN
### ============================================================
echo "[*] Running network sweep at: $(date)"

mapfile -t DEVICES < <(nmap -sn "$NETWORK_RANGE" | grep "Nmap scan report" | awk '{print $5}')

for DEVICE in "${DEVICES[@]}"; do
    # Fetch MAC safely
    MAC=$(arp -a "$DEVICE" | awk '{print $4}')

    echo "Detected: $DEVICE ($MAC)"
    echo "$(date) - Detected: $DEVICE ($MAC)" >> "$SCAN_LOG"

    if ! grep -q "$DEVICE" "$NEW_DEVICES_LOG"; then
        echo "⚠️ New device detected: $DEVICE ($MAC)"
        echo "$DEVICE ($MAC)" >> "$NEW_DEVICES_LOG"

        # Send alert
        send_sms "New device detected on your network: $DEVICE ($MAC)"
    fi
done

echo
echo "----------------------------------------"
echo "     MASTER SCANNER — SCAN COMPLETE"
echo "----------------------------------------"