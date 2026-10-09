#!/usr/bin/env bash
#
# Builds the Synology package:  synology/build.sh [build number]  →  dist/freescout-<version>-<build>.spk
# The build number (1 unless given) goes after the app's own version, as DSM
# wants one: a package rebuilt for the same release gets the next.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(tr -d ' \n' < VERSION)
BUILD=${1:-1}
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "The build number is a number: synology/build.sh 2" >&2; exit 2; }
SPK_VERSION="$VERSION-$BUILD"

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
spk=$work/spk; target=$work/target
mkdir -p "$spk" "$target/app" dist

# The app's compose project — only what's meant to ship, never a .env or data.
cp app/compose.yaml app/env.example "$target/app/"
cp -r synology/target/. "$target/"
cp -r synology/setup "$target/setup"
cp -r modules "$target/modules"
cp CHANGELOG.md "$target/CHANGELOG.md" 2>/dev/null || true
echo "$SPK_VERSION" > "$target/build-id"
# DSM keeps a window's script until its version changes.
sed -i "s/\"version\": \"1\"/\"version\": \"$SPK_VERSION\"/" "$target/ui/config"

# Icons: PACKAGE_ICON.PNG (64), PACKAGE_ICON_256.PNG (256), ui/images/<n>.png.
# DSM shows them as supplied — draw a rounded tile with transparent corners.
python3 synology/icon.py "$spk" --ui "$target/ui/images" --sizes 16,24,32,48,64,72,128,256 \
  --letter F --top '#2f8be6' --bottom '#1659a8'

find "$target" -type d -exec chmod 755 {} +
find "$target" -type f -exec chmod 644 {} +
chmod 755 "$target/ui/api.cgi" "$target/setup/run.sh"
tar -C "$target" --owner=0 --group=0 --numeric-owner -czf "$spk/package.tgz" .

cp -r synology/scripts synology/conf synology/WIZARD_UIFILES "$spk/"
chmod 755 "$spk"/scripts/* "$spk"/WIZARD_UIFILES/*.sh
chmod 644 "$spk/scripts/common" "$spk"/conf/* "$spk/WIZARD_UIFILES/uninstall_uifile"
sed "s/@VERSION@/$SPK_VERSION/" synology/INFO.in > "$spk/INFO"
echo "extractsize=\"$(du -sk "$target" | cut -f1)\"" >> "$spk/INFO"
echo "checksum=\"$(md5sum "$spk/package.tgz" | cut -d' ' -f1)\"" >> "$spk/INFO"

out="dist/freescout-$SPK_VERSION.spk"
tar -C "$spk" --owner=0 --group=0 --numeric-owner -cf "$out" \
  INFO package.tgz scripts conf WIZARD_UIFILES PACKAGE_ICON.PNG PACKAGE_ICON_256.PNG
echo "$out ($(du -h "$out" | cut -f1))"
