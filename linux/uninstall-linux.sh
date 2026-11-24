#!/bin/sh
# Removes the agent installed by install-linux.sh (for the .deb: sudo apt remove snipeit-agent).
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
systemctl disable --now snipeit-agent.timer 2>/dev/null || true
rm -f /etc/systemd/system/snipeit-agent.service /etc/systemd/system/snipeit-agent.timer
systemctl daemon-reload 2>/dev/null || true
rm -rf /opt/snipeit-agent /etc/snipeit-agent /var/lib/snipeit-agent
echo "Snipe-IT agent removed."
