#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# 1. Build the App bundle
"$ROOT_DIR/scripts/build_app.sh"

BUILD_DIR="$ROOT_DIR/build"
DMG_STAGING_DIR="$BUILD_DIR/dmg_staging"
DMG_OUTPUT="$BUILD_DIR/CaffCtl.dmg"

echo "==> Preparing DMG staging folder..."
rm -rf "$DMG_STAGING_DIR" "$DMG_OUTPUT"
mkdir -p "$DMG_STAGING_DIR"

# Copy App bundle
cp -R "$BUILD_DIR/CaffCtl.app" "$DMG_STAGING_DIR/"

# Create symlink to /Applications for standard drag-and-drop install
ln -sf /Applications "$DMG_STAGING_DIR/Applications"

# Create double-clickable Install CLI script inside DMG
cat << 'EOF' > "$DMG_STAGING_DIR/Install CLI.command"
#!/usr/bin/env bash
set -e

echo "☕ CaffCtl CLI Installer"
echo "========================"
echo ""

APP_PATH="/Applications/CaffCtl.app"

if [ ! -d "$APP_PATH" ]; then
    echo "⚠️  Please drag CaffCtl.app into Applications first!"
    echo "   Press any key to exit..."
    read -n 1
    exit 1
fi

LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"
rm -f "$LOCAL_BIN/caffctl" "$LOCAL_BIN/caffeine"

ln -sf "$APP_PATH/Contents/MacOS/caffctl" "$LOCAL_BIN/caffeinate"

echo "✅ Successfully linked 'caffeinate' to $LOCAL_BIN/caffeinate"
echo ""
echo "🎉 You can now use 'caffeinate' in your Terminal!"
echo "   Closing in 2 seconds..."
sleep 2
EOF
chmod +x "$DMG_STAGING_DIR/Install CLI.command"

echo "==> Creating CaffCtl.dmg using hdiutil..."
hdiutil create -volname "CaffCtl" \
    -srcfolder "$DMG_STAGING_DIR" \
    -ov -format UDZO \
    "$DMG_OUTPUT"

rm -rf "$DMG_STAGING_DIR"

echo "==> DMG successfully created at: $DMG_OUTPUT"
