#!/usr/bin/env bash

echo "──────────────"
echo " NMAP SETUP BOT"
echo "──────────────"
echo ""

# Resolve username automatically
USER_NAME=$(whoami)

# Winget path (Git Bash compatible)
WINGET_PATH="/c/Users/$USER_NAME/AppData/Local/Microsoft/WindowsApps/winget.exe"

# 1. Check if winget exists
echo "[1/5] Checking for Winget…"
if [ -f "$WINGET_PATH" ]; then
    echo "✓ Winget detected at: $WINGET_PATH"
    echo "[2/5] Installing Nmap with Winget…"
    "$WINGET_PATH" install -e --id Insecure.Nmap

else
    echo "✗ Winget not found. Switching to fallback installer…"
    echo "[2/5] Downloading official Nmap installer…"

    curl -L -o nmap-setup.exe https://nmap.org/dist/nmap-7.95-setup.exe

    echo "[3/5] Launching installer…"
    ./nmap-setup.exe
fi

# 2. Verify installation
echo ""
echo "[4/5] Verifying Nmap installation…"
if command -v nmap >/dev/null 2>&1; then
    echo "✓ Nmap installed successfully!"
else
    echo "✗ Nmap not detected in PATH."
    echo "You may need to restart Git Bash or reboot Windows."
    exit 1
fi

# 3. Run a simple scan
echo ""
echo "[5/5] Running test scan on your local gateway…"
GATEWAY=$(ipconfig | grep -i "Default Gateway" | awk '{print $3}' | head -n 1)

if [ -z "$GATEWAY" ]; then
    echo "Could not automatically detect gateway — skipping scan."
else
    echo "Scanning $GATEWAY…"
    nmap -sP "$GATEWAY"/24
fi

echo ""
echo "──────────────"
echo "   DONE ✔"
echo "──────────────"