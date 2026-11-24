#!/bin/bash
# Builds SnipeIT-Agent-<version>.pkg (run on macOS).
#   packaging/macos/build-pkg.sh <config.json> <version> <out-dir>
set -euo pipefail
CONFIG="$1"; VERSION="$2"; OUT="$3"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S=$(mktemp -d)
trap 'rm -rf "$S"' EXIT
cp "$ROOT/macos/snipeit-agent.js" "$ROOT/macos/install-mac.sh" "$S/"
cp "$CONFIG" "$S/config.json"
chmod 600 "$S/config.json"
cat > "$S/postinstall" <<'SH'
#!/bin/bash
# Runs as root after the package is installed.
HERE="$(cd "$(dirname "$0")" && pwd)"
/bin/bash "$HERE/install-mac.sh" --config "$HERE/config.json" --no-run || exit 1
# First report right away, in the background so the installer can finish.
/usr/bin/nohup /usr/bin/osascript -l JavaScript "/Library/Application Support/SnipeITAgent/snipeit-agent.js" >/dev/null 2>&1 &
exit 0
SH
chmod 755 "$S/postinstall" "$S/install-mac.sh"
mkdir -p "$OUT"
pkgbuild --nopayload --scripts "$S" --identifier com.wisilica.snipeit-agent --version "$VERSION" \
  "$OUT/SnipeIT-Agent-$VERSION.pkg"
