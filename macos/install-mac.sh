#!/bin/bash
# Installs the Snipe-IT inventory agent on this Mac.
#
#   sudo ./install-mac.sh --url http://192.168.1.35            # prompts for the token (hidden)
#   sudo ./install-mac.sh --config /path/to/config.json         # use a prepared config
#   sudo ./install-mac.sh --url ... --asset-tag WICDC/MAC/017   # only if the serial can't be matched
#
# What it does:
#   - copies snipeit-agent.js to /Library/Application Support/SnipeITAgent (root-only, 700)
#   - writes config.json there (600, holds the API token)
#   - installs a launchd daemon that runs as root at boot and daily at 11:00
#     (with up to 2 hours random delay; a Mac that was asleep runs it on wake)
#   - runs the agent once now
# Safe to rerun: it upgrades in place.
set -euo pipefail

DIR="/Library/Application Support/SnipeITAgent"
LABEL="com.wisilica.snipeit-agent"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
HERE="$(cd "$(dirname "$0")" && pwd)"

URL=""; CONFIG=""; TAG=""; RUN_NOW=1
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="${2%/}"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --asset-tag) TAG="$2"; shift 2 ;;
    --no-run) RUN_NOW=0; shift ;;
    *) echo "Unknown option: $1" >&2; exit 64 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then echo "Run with sudo." >&2; exit 1; fi

json_escape() { /usr/bin/osascript -l JavaScript -e 'function run(a){return JSON.stringify(a[0])}' "$1"; }

mkdir -p "$DIR"
chown root:wheel "$DIR"
chmod 700 "$DIR"
cp "$HERE/snipeit-agent.js" "$DIR/snipeit-agent.js"
chmod 600 "$DIR/snipeit-agent.js"

if [ -n "$CONFIG" ]; then
  cp "$CONFIG" "$DIR/config.json"
elif [ -n "$URL" ]; then
  printf 'Snipe-IT API token for the agent (input hidden): '
  read -rs TOKEN; echo
  [ -n "$TOKEN" ] || { echo "No token entered." >&2; exit 1; }
  umask 077
  cat > "$DIR/config.json" <<EOF
{
  "SnipeUrl": $(json_escape "$URL"),
  "ApiToken": $(json_escape "$TOKEN"),
  "HeartbeatDays": 7,
  "MaxSoftwareChars": 60000,
  "AssetTag": $(json_escape "$TAG")
}
EOF
  unset TOKEN
elif [ ! -f "$DIR/config.json" ]; then
  echo "Pass --url <Snipe-IT URL> (prompts for the token) or --config <config.json>." >&2
  exit 64
fi
chown root:wheel "$DIR/config.json"
chmod 600 "$DIR/config.json"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/osascript</string>
    <string>-l</string><string>JavaScript</string>
    <string>${DIR}/snipeit-agent.js</string>
    <string>--jitter</string><string>7200</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>11</integer><key>Minute</key><integer>0</integer></dict>
  <key>RunAtLoad</key><true/>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>${DIR}/launchd.err</string>
</dict>
</plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootout system "$PLIST" 2>/dev/null || true
# RunAtLoad would start a run with a random delay; that's fine, the manual run below is immediate.
launchctl bootstrap system "$PLIST"

echo "Installed to $DIR and loaded $LABEL."
if [ "$RUN_NOW" -eq 1 ]; then
  echo "Running once now..."
  /usr/bin/osascript -l JavaScript "$DIR/snipeit-agent.js" || true
  echo "Log: sudo tail -20 \"$DIR/agent.log\""
fi
