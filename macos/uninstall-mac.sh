#!/bin/bash
# Removes the Snipe-IT inventory agent from this Mac. Data already in Snipe-IT is kept.
set -u
if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo." >&2; exit 1; fi
PLIST="/Library/LaunchDaemons/com.wisilica.snipeit-agent.plist"
launchctl bootout system "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
rm -rf "/Library/Application Support/SnipeITAgent"
echo "Snipe-IT agent removed."
