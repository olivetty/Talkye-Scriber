#!/usr/bin/env bash
# Talkye Scriber — AppImage build script
# Usage: ./build-appimage.sh
# Output: TalkyeScriber-x86_64.AppImage

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.appimage-build"
APPDIR="$BUILD_DIR/TalkyeScriber.AppDir"
TOOLS_DIR="$BUILD_DIR/tools"
PYTHON_DIR="$BUILD_DIR/python-standalone"

# Python standalone version (astral-sh)
PYTHON_RELEASE="20260211"
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-3.12.12%2B${PYTHON_RELEASE}-x86_64-unknown-linux-gnu-install_only.tar.gz"

# appimagetool
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"

echo "=== Talkye Scriber AppImage Builder ==="
echo ""

# ── Step 1: Build Flutter app ──
echo "[1/7] Building Flutter app..."
(cd "$SCRIPT_DIR/app" && flutter build linux --release)
echo "  ✓ Flutter build complete"

# ── Step 2: Clean previous build ──
echo "[2/7] Preparing AppDir..."
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/data"
mkdir -p "$APPDIR/usr/sidecar" "$APPDIR/usr/whisper" "$APPDIR/usr/python"
mkdir -p "$APPDIR/usr/sox/lib"
mkdir -p "$TOOLS_DIR"

# ── Step 3: Copy Flutter bundle ──
echo "[3/7] Copying Flutter bundle..."
BUNDLE="$SCRIPT_DIR/app/build/linux/x64/release/bundle"
# Flutter expects lib/ and data/ relative to the binary
cp "$BUNDLE/talkye_app" "$APPDIR/usr/bin/"
cp -r "$BUNDLE/lib" "$APPDIR/usr/bin/"
cp -r "$BUNDLE/data" "$APPDIR/usr/bin/"
# Copy icon next to binary so GTK window icon resolves
if [ -f "$SCRIPT_DIR/app-icon.png" ]; then
  cp "$SCRIPT_DIR/app-icon.png" "$APPDIR/usr/bin/talkye-meet.png"
elif [ -f "$SCRIPT_DIR/app/assets/talkye-meet.png" ]; then
  cp "$SCRIPT_DIR/app/assets/talkye-meet.png" "$APPDIR/usr/bin/talkye-meet.png"
fi
echo "  ✓ Flutter bundle copied"

# ── Step 4: Copy sidecar + whisper + sox ──
echo "[4/7] Copying sidecar, whisper-cli, sox..."
# Sidecar source
for f in "$SCRIPT_DIR"/sidecar/*.py "$SCRIPT_DIR"/sidecar/*.txt "$SCRIPT_DIR"/sidecar/*.sh; do
  [ -f "$f" ] && cp "$f" "$APPDIR/usr/sidecar/"
done
cp -r "$SCRIPT_DIR/sidecar/sounds" "$APPDIR/usr/sidecar/"
chmod +x "$APPDIR/usr/sidecar/setup.sh"

# whisper-cli
WHISPER_BIN="$SCRIPT_DIR/whisper.cpp/build/bin/whisper-cli"
if [ ! -f "$WHISPER_BIN" ]; then
  echo "  ERROR: whisper-cli not found at $WHISPER_BIN"
  echo "  Build whisper.cpp first: cd whisper.cpp && cmake -B build && cmake --build build --config Release"
  exit 1
fi
cp "$WHISPER_BIN" "$APPDIR/usr/whisper/"
chmod +x "$APPDIR/usr/whisper/whisper-cli"

# sox binary + libs
SOX_BIN="$(which sox 2>/dev/null || echo "")"
if [ -n "$SOX_BIN" ]; then
  cp "$SOX_BIN" "$APPDIR/usr/sox/"
  chmod +x "$APPDIR/usr/sox/sox"
  # Copy sox shared libs
  for lib in libsox.so.3 libltdl.so.7 libgsm.so.1; do
    src="/lib/x86_64-linux-gnu/$lib"
    [ -L "$src" ] && src="$(readlink -f "$src")"
    [ -f "$src" ] && cp "$src" "$APPDIR/usr/sox/lib/$lib"
  done
  echo "  ✓ sox bundled"
else
  echo "  WARNING: sox not found, 'subtle' sound theme won't work"
fi
echo "  ✓ Sidecar + whisper-cli copied"

# ── Step 5: Download Python standalone ──
echo "[5/7] Setting up Python standalone..."
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
cp -r "$PYTHON_DIR/python/"* "$APPDIR/usr/python/"
echo "  ✓ Python bundled"

# Install sidecar deps into bundled Python (no venv needed at runtime)
echo "  Installing sidecar dependencies into bundled Python..."
"$APPDIR/usr/python/bin/python3" -m pip install -q \
  -r "$APPDIR/usr/sidecar/requirements-base.txt" 2>&1 | tail -5
echo "  ✓ Python deps installed"

# ── Step 6: Create AppRun + .desktop + icon ──
echo "[6/7] Creating AppRun, .desktop, icon..."

cat > "$APPDIR/AppRun" << 'APPRUN_EOF'
#!/usr/bin/env bash
APPDIR="$(cd "$(dirname "$0")" && pwd)"

# Flutter libs (relative to binary in usr/bin/)
export LD_LIBRARY_PATH="$APPDIR/usr/bin/lib:$APPDIR/usr/sox/lib:${LD_LIBRARY_PATH:-}"

# Bundled tools for sidecar
export TALKYE_WHISPER_BIN="$APPDIR/usr/whisper/whisper-cli"
export TALKYE_SIDECAR_DIR="$APPDIR/usr/sidecar"
export TALKYE_PYTHON="$APPDIR/usr/python/bin/python3"
export TALKYE_SOX="$APPDIR/usr/sox/sox"

# Data path for Flutter
export FLUTTER_ASSET_DIR="$APPDIR/usr/data"

exec "$APPDIR/usr/bin/talkye_app" "$@"
APPRUN_EOF
chmod +x "$APPDIR/AppRun"

cat > "$APPDIR/talkye-scriber.desktop" << 'DESKTOP_EOF'
[Desktop Entry]
Name=Talkye Scriber
Comment=Voice-to-text dictation tool
Exec=talkye_app
Icon=talkye-scriber
Type=Application
Categories=Utility;Accessibility;
DESKTOP_EOF

# Icon
if [ -f "$SCRIPT_DIR/app-icon.png" ]; then
  cp "$SCRIPT_DIR/app-icon.png" "$APPDIR/talkye-scriber.png"
elif [ -f "$SCRIPT_DIR/app/assets/talkye-meet.png" ]; then
  cp "$SCRIPT_DIR/app/assets/talkye-meet.png" "$APPDIR/talkye-scriber.png"
fi

echo "  ✓ AppRun + .desktop + icon created"

# ── Step 7: Build AppImage ──
echo "[7/7] Building AppImage..."
APPIMAGETOOL="$TOOLS_DIR/appimagetool"
if [ ! -f "$APPIMAGETOOL" ]; then
  echo "  Downloading appimagetool..."
  wget -q --show-progress -O "$APPIMAGETOOL" "$APPIMAGETOOL_URL"
  chmod +x "$APPIMAGETOOL"
fi

OUTPUT="$SCRIPT_DIR/TalkyeScriber-x86_64.AppImage"
ARCH=x86_64 "$APPIMAGETOOL" "$APPDIR" "$OUTPUT" 2>&1 | tail -5

chmod +x "$OUTPUT"
SIZE=$(du -h "$OUTPUT" | cut -f1)
echo ""
echo "=== Done ==="
echo "  Output: $OUTPUT"
echo "  Size:   $SIZE"
echo ""
echo "  Run it: ./TalkyeScriber-x86_64.AppImage"
