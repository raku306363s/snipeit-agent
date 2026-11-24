#!/bin/sh
# Installs the Snipe-IT inventory agent on a Linux machine without the .deb
# (Fedora, Arch, ...). Run from the folder that holds config.json:
#   sudo ./install-linux.sh
set -eu
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
command -v python3 >/dev/null || { echo "python3 is required." >&2; exit 1; }
install -d -m 755 /opt/snipeit-agent
install -m 755 "$HERE/snipeit-agent.py" /opt/snipeit-agent/snipeit-agent.py
install -d -m 700 /etc/snipeit-agent
[ -f "$HERE/config.json" ] && install -m 600 "$HERE/config.json" /etc/snipeit-agent/config.json
[ -f /etc/snipeit-agent/config.json ] || { echo "No config.json next to this script." >&2; exit 1; }
install -m 644 "$HERE/snipeit-agent.service" "$HERE/snipeit-agent.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now snipeit-agent.timer
systemctl start --no-block snipeit-agent.service
echo "Installed. Log: sudo tail /var/log/snipeit-agent.log"
