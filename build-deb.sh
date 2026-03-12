#!/usr/bin/env bash
# Talkye Scriber — .deb package builder
# Usage: ./build-deb.sh
# Output: talkye-scriber_VERSION_amd64.deb

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.deb-build"
TOOLS_DIR="$BUILD_DIR/tools"
PYTHON_DIR="$BUILD_DIR/python-standalone"

# Install prefix inside the .deb
INSTALL_DIR="/opt/talkye-scriber"

# Python standalone version (astral-sh)
PYTHON_RELEASE="20260211"
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-3.12.12%2B${PYTHON_RELEASE}-x86_64-unknown-linux-gnu-install_only.tar.gz"

# Read version from version.dart
VERSION=$(grep -oP "appVersion = '\K[^']+" "$SCRIPT_DIR/app/lib/version.dart")
if [ -z "$VERSION" ]; then
  echo "ERROR: Could not read version from app/lib/version.dart"
  exit 1
fi

DEB_NAME="talkye-scriber_${VERSION}_amd64"
PKG_DIR="$BUILD_DIR/$DEB_NAME"

echo "=== Talkye Scriber .deb Builder (v$VERSION) ==="
echo ""

# ── Step 1: Build Flutter app ──
echo "[1/8] Building Flutter app..."
(cd "$SCRIPT_DIR/app" && flutter build linux --release)
echo "  ✓ Flutter build complete"

# ── Step 2: Clean previous build ──
echo "[2/8] Preparing package directory..."
chmod -R u+w "$PKG_DIR" 2>/dev/null || true
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR$INSTALL_DIR/bin"
mkdir -p "$PKG_DIR$INSTALL_DIR/lib"
mkdir -p "$PKG_DIR$INSTALL_DIR/data"
mkdir -p "$PKG_DIR$INSTALL_DIR/sidecar"
mkdir -p "$PKG_DIR$INSTALL_DIR/whisper"
mkdir -p "$PKG_DIR$INSTALL_DIR/python"
mkdir -p "$PKG_DIR$INSTALL_DIR/sox/lib"
mkdir -p "$PKG_DIR/usr/bin"
mkdir -p "$PKG_DIR/usr/share/applications"
mkdir -p "$PKG_DIR/usr/share/icons/hicolor/256x256/apps"
mkdir -p "$PKG_DIR/DEBIAN"
mkdir -p "$TOOLS_DIR"

# ── Step 3: Copy Flutter bundle ──
echo "[3/8] Copying Flutter bundle..."
BUNDLE="$SCRIPT_DIR/app/build/linux/x64/release/bundle"
cp "$BUNDLE/talkye_app" "$PKG_DIR$INSTALL_DIR/bin/"
cp -r "$BUNDLE/lib" "$PKG_DIR$INSTALL_DIR/bin/"
cp -r "$BUNDLE/data" "$PKG_DIR$INSTALL_DIR/bin/"

# Copy icon next to binary
if [ -f "$SCRIPT_DIR/app-icon.png" ]; then
  cp "$SCRIPT_DIR/app-icon.png" "$PKG_DIR$INSTALL_DIR/bin/talkye-meet.png"
elif [ -f "$SCRIPT_DIR/app/assets/talkye-meet.png" ]; then
  cp "$SCRIPT_DIR/app/assets/talkye-meet.png" "$PKG_DIR$INSTALL_DIR/bin/talkye-meet.png"
fi
echo "  ✓ Flutter bundle copied"

# Verify compiled version
COMPILED_VERSION=$(strings "$PKG_DIR$INSTALL_DIR/bin/lib/libapp.so" 2>/dev/null | grep -oP '^\d+\.\d+\.\d+$' | head -1)
if [ "$VERSION" != "$COMPILED_VERSION" ]; then
  echo "  ERROR: Version mismatch! version.dart=$VERSION but libapp.so=$COMPILED_VERSION"
  echo "  Run 'flutter clean' in app/ and retry."
  exit 1
fi
echo "  ✓ Version verified: $COMPILED_VERSION"

# ── Step 4: Copy sidecar + whisper + sox ──
echo "[4/8] Copying sidecar, whisper-cli, sox..."
for f in "$SCRIPT_DIR"/sidecar/*.py "$SCRIPT_DIR"/sidecar/*.txt "$SCRIPT_DIR"/sidecar/*.sh; do
  [ -f "$f" ] && cp "$f" "$PKG_DIR$INSTALL_DIR/sidecar/"
done
cp -r "$SCRIPT_DIR/sidecar/sounds" "$PKG_DIR$INSTALL_DIR/sidecar/"
chmod +x "$PKG_DIR$INSTALL_DIR/sidecar/setup.sh"

# whisper-cli
WHISPER_BIN="$SCRIPT_DIR/whisper.cpp/build/bin/whisper-cli"
if [ ! -f "$WHISPER_BIN" ]; then
  echo "  ERROR: whisper-cli not found at $WHISPER_BIN"
  exit 1
fi
cp "$WHISPER_BIN" "$PKG_DIR$INSTALL_DIR/whisper/"
chmod +x "$PKG_DIR$INSTALL_DIR/whisper/whisper-cli"

# sox
SOX_BIN="$(which sox 2>/dev/null || echo "")"
if [ -n "$SOX_BIN" ]; then
  cp "$SOX_BIN" "$PKG_DIR$INSTALL_DIR/sox/"
  chmod +x "$PKG_DIR$INSTALL_DIR/sox/sox"
  for lib in libsox.so.3 libltdl.so.7 libgsm.so.1; do
    src="/lib/x86_64-linux-gnu/$lib"
    [ -L "$src" ] && src="$(readlink -f "$src")"
    [ -f "$src" ] && cp "$src" "$PKG_DIR$INSTALL_DIR/sox/lib/$lib"
  done
  echo "  ✓ sox bundled"
else
  echo "  WARNING: sox not found"
fi
echo "  ✓ Sidecar + whisper-cli copied"

# ── Step 5: Python standalone ──
echo "[5/8] Setting up Python standalone..."
if [ ! -d "$PYTHON_DIR/python" ]; then
  PYTHON_TAR="$TOOLS_DIR/python-standalone.tar.gz"
  if [ ! -f "$PYTHON_TAR" ]; then
    echo "  Downloading Python standalone..."
    wget -q --show-progress -O "$PYTHON_TAR" "$PYTHON_URL" || { rm -f "$PYTHON_TAR"; echo "  ERROR: Python download failed"; exit 1; }
  fi
  mkdir -p "$PYTHON_DIR"
  tar -xzf "$PYTHON_TAR" -C "$PYTHON_DIR"
  echo "  ✓ Python standalone extracted"
else
  echo "  ✓ Python standalone cached"
fi
cp -r "$PYTHON_DIR/python/"* "$PKG_DIR$INSTALL_DIR/python/"
echo "  ✓ Python bundled"

echo "  Installing sidecar dependencies..."
"$PKG_DIR$INSTALL_DIR/python/bin/python3" -m pip install -q \
  -r "$PKG_DIR$INSTALL_DIR/sidecar/requirements-base.txt" 2>&1 | tail -5
echo "  ✓ Python deps installed"

# ── Step 6: Create launcher script ──
echo "[6/8] Creating launcher script..."
cat > "$PKG_DIR$INSTALL_DIR/talkye-scriber" << 'LAUNCHER_EOF'
#!/usr/bin/env bash
TALKYE_DIR="/opt/talkye-scriber"

export LD_LIBRARY_PATH="$TALKYE_DIR/bin/lib:$TALKYE_DIR/sox/lib:${LD_LIBRARY_PATH:-}"
export TALKYE_WHISPER_BIN="$TALKYE_DIR/whisper/whisper-cli"
export TALKYE_SIDECAR_DIR="$TALKYE_DIR/sidecar"
export TALKYE_PYTHON="$TALKYE_DIR/python/bin/python3"
export TALKYE_SOX="$TALKYE_DIR/sox/sox"
export TALKYE_INSTALL_TYPE="deb"

exec "$TALKYE_DIR/bin/talkye_app" "$@"
LAUNCHER_EOF
chmod +x "$PKG_DIR$INSTALL_DIR/talkye-scriber"

# Symlink in /usr/bin
ln -sf "$INSTALL_DIR/talkye-scriber" "$PKG_DIR/usr/bin/talkye-scriber"

# ── Step 7: Desktop entry + icon ──
echo "[7/8] Creating .desktop + icon..."

cat > "$PKG_DIR/usr/share/applications/talkye-scriber.desktop" << 'DESKTOP_EOF'
[Desktop Entry]
Name=Talkye Scriber
Comment=Voice-to-text dictation tool
Exec=talkye-scriber
Icon=talkye-scriber
Type=Application
Categories=Utility;Accessibility;Audio;
StartupWMClass=com.talkye.scriber
DESKTOP_EOF

if [ -f "$SCRIPT_DIR/app-icon.png" ]; then
  cp "$SCRIPT_DIR/app-icon.png" "$PKG_DIR/usr/share/icons/hicolor/256x256/apps/talkye-scriber.png"
elif [ -f "$SCRIPT_DIR/app/assets/talkye-meet.png" ]; then
  cp "$SCRIPT_DIR/app/assets/talkye-meet.png" "$PKG_DIR/usr/share/icons/hicolor/256x256/apps/talkye-scriber.png"
fi

# ── DEBIAN control files ──

# Calculate installed size in KB
INSTALLED_SIZE=$(du -sk "$PKG_DIR$INSTALL_DIR" | cut -f1)

cat > "$PKG_DIR/DEBIAN/control" << EOF
Package: talkye-scriber
Version: $VERSION
Section: utils
Priority: optional
Architecture: amd64
Installed-Size: $INSTALLED_SIZE
Depends: libc6 (>= 2.35), libgtk-3-0, libblkid1, liblzma5
Maintainer: Olivetty <contact@talkye.com>
Homepage: https://github.com/olivetty/Talkye-Scriber
Description: Voice-to-text dictation tool
 Hold a key, speak, release — text appears at your cursor.
 Works system-wide in any application.
EOF

cat > "$PKG_DIR/DEBIAN/postinst" << 'POSTINST_EOF'
#!/bin/bash
set -e
# Update desktop database
if command -v update-desktop-database &>/dev/null; then
  update-desktop-database /usr/share/applications 2>/dev/null || true
fi
# Update icon cache
if command -v gtk-update-icon-cache &>/dev/null; then
  gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
fi
POSTINST_EOF
chmod 755 "$PKG_DIR/DEBIAN/postinst"

cat > "$PKG_DIR/DEBIAN/postrm" << 'POSTRM_EOF'
#!/bin/bash
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
  if command -v update-desktop-database &>/dev/null; then
    update-desktop-database /usr/share/applications 2>/dev/null || true
  fi
  if command -v gtk-update-icon-cache &>/dev/null; then
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
  fi
fi
POSTRM_EOF
chmod 755 "$PKG_DIR/DEBIAN/postrm"

# ── Step 8: Build .deb ──
echo "[8/8] Building .deb package..."
OUTPUT="$SCRIPT_DIR/talkye-scriber_${VERSION}_amd64.deb"
dpkg-deb --build --root-owner-group "$PKG_DIR" "$OUTPUT"

SIZE=$(du -h "$OUTPUT" | cut -f1)
echo ""
echo "=== Done ==="
echo "  Output: $OUTPUT"
echo "  Size:   $SIZE"
echo ""
echo "  Install: sudo dpkg -i $OUTPUT"
echo "  Remove:  sudo apt remove talkye-scriber"
