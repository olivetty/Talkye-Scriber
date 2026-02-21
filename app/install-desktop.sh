#!/bin/bash
# Install Talkye Meet desktop entry + icon for GNOME dock integration.
# Run once after first build: ./install-desktop.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ID="com.talkye.meet"
ICON_SRC="$SCRIPT_DIR/assets/talkye-meet.png"
BUNDLE_DIR="$SCRIPT_DIR/build/linux/x64/release/bundle"

if [ ! -f "$BUNDLE_DIR/talkye_app" ]; then
    echo "❌ Build not found. Run first: cd app && flutter build linux --release"
    exit 1
fi

# Install icon
ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
mkdir -p "$ICON_DIR"
cp "$ICON_SRC" "$ICON_DIR/$APP_ID.png"

# Install .desktop with absolute Exec path
mkdir -p "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/$APP_ID.desktop" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Talkye Meet
Comment=Live translation assistant for video calls
Exec=$BUNDLE_DIR/talkye_app
Icon=$APP_ID
Terminal=false
StartupWMClass=$APP_ID
Categories=AudioVideo;
EOF

gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
echo "✅ Done! Talkye Meet icon installed."
