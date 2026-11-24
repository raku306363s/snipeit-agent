#!/bin/bash
# Builds snipeit-agent_<version>_all.deb with config.json baked in.
#   packaging/linux/build-deb.sh <config.json> <version> <out-dir>
set -euo pipefail
CONFIG="$1"; VERSION="$2"; OUT="$3"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
B=$(mktemp -d); chmod 755 "$B"
trap 'rm -rf "$B"' EXIT
install -d "$B/DEBIAN" "$B/opt/snipeit-agent" "$B/etc/snipeit-agent" "$B/lib/systemd/system"
install -m 755 "$ROOT/linux/snipeit-agent.py" "$B/opt/snipeit-agent/"
install -m 600 "$CONFIG" "$B/etc/snipeit-agent/config.json"
install -m 644 "$ROOT/linux/snipeit-agent.service" "$ROOT/linux/snipeit-agent.timer" "$B/lib/systemd/system/"
cat > "$B/DEBIAN/control" <<CTL
Package: snipeit-agent
Version: $VERSION
Section: admin
Priority: optional
Architecture: all
Depends: python3 (>= 3.6)
Maintainer: WiSilica IT <it@localhost>
Description: Snipe-IT inventory agent
 Reports this computer's hardware and installed applications to the
 company's Snipe-IT asset system once a day.
CTL
echo /etc/snipeit-agent/config.json > "$B/DEBIAN/conffiles"
cat > "$B/DEBIAN/postinst" <<'SH'
#!/bin/sh
set -e
chmod 700 /etc/snipeit-agent
chmod 600 /etc/snipeit-agent/config.json
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload
  systemctl enable --now snipeit-agent.timer
  systemctl start --no-block snipeit-agent.service || true
fi
exit 0
SH
cat > "$B/DEBIAN/prerm" <<'SH'
#!/bin/sh
set -e
if [ -d /run/systemd/system ]; then
  systemctl disable --now snipeit-agent.timer || true
fi
exit 0
SH
cat > "$B/DEBIAN/postrm" <<'SH'
#!/bin/sh
set -e
if [ "$1" = purge ]; then rm -rf /var/lib/snipeit-agent /etc/snipeit-agent; fi
if [ -d /run/systemd/system ]; then systemctl daemon-reload || true; fi
exit 0
SH
chmod 755 "$B/DEBIAN/postinst" "$B/DEBIAN/prerm" "$B/DEBIAN/postrm"
mkdir -p "$OUT"
dpkg-deb --root-owner-group --build "$B" "$OUT/snipeit-agent_${VERSION}_all.deb"
# Tarball for non-Debian distros
T=$(mktemp -d)
mkdir "$T/snipeit-agent-linux"
cp "$ROOT"/linux/{snipeit-agent.py,snipeit-agent.service,snipeit-agent.timer,install-linux.sh,uninstall-linux.sh} "$T/snipeit-agent-linux/"
install -m 600 "$CONFIG" "$T/snipeit-agent-linux/config.json"
tar -C "$T" -czf "$OUT/snipeit-agent-linux-${VERSION}.tar.gz" snipeit-agent-linux
rm -rf "$T"
