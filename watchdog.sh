#!/bin/bash

SCAN_RANGE="192.168.1.0/24"
KNOWN_FILE="known_devices.txt"
LOG_FILE="new_device_log.txt"
SMS_TO="3046571689@tmomail.net"
GMAIL_USER="YOUR_GMAIL@gmail.com"
GMAIL_PASS="YOUR_APP_PASSWORD"

send_sms() {
    SUBJECT="New Device Detected"
    MESSAGE="$1"

    curl -s --url "smtps://smtp.gmail.com:465" \
        --ssl-reqd \
        --mail-from "$GMAIL_USER" \
        --mail-rcpt "$SMS_TO" \
        --upload-file <(printf "Subject:$SUBJECT\n\n$MESSAGE") \
        --user "$GMAIL_USER:$GMAIL_PASS"
}

while true; do
    echo "[*] Running Bash Network Watchdog..."
    SCAN_OUTPUT=$(nmap -sn $SCAN_RANGE)

    NEW_DEVICES=$(echo "$SCAN_OUTPUT" | awk '
        /Nmap scan report for/ {ip=$NF}
        /MAC Address:/ {mac=$3; print ip "," mac}
    ')

    if [ ! -f "$KNOWN_FILE" ]; then
        touch "$KNOWN_FILE"
    fi

    echo "$NEW_DEVICES" | while read -r line; do
        if [[ -z "$line" ]]; then
            continue
        fi

        if ! grep -q "$line" "$KNOWN_FILE" 2>/dev/null; then
            echo "⚠️ New device detected: $line"
            echo "$line" >> "$KNOWN_FILE"
            echo "$(date): NEW DEVICE — $line" >> "$LOG_FILE"
            send_sms "New device detected: $line"
        fi
    done

    echo "[*] Waiting 5 minutes before next scan…"
    sleep 300   # 300 seconds = 5 minutes
done