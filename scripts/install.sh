#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# 1. Build the App bundle
"$ROOT_DIR/scripts/build_app.sh"

echo "==> Installing CaffCtl.app to /Applications..."
pkill -f CaffCtlApp || true
rm -rf /Applications/CaffCtl.app
cp -R "$ROOT_DIR/build/CaffCtl.app" /Applications/
touch /Applications/CaffCtl.app

echo "==> Setting up caffeinate symlink in ~/.local/bin..."
mkdir -p "$HOME/.local/bin"
rm -f "$HOME/.local/bin/caffctl" "$HOME/.local/bin/caffeine"
ln -sf "/Applications/CaffCtl.app/Contents/MacOS/caffctl" "$HOME/.local/bin/caffeinate"

echo "==> Installation complete!"
echo "    App installed: /Applications/CaffCtl.app"
echo "    Wrapper:       $HOME/.local/bin/caffeinate"
