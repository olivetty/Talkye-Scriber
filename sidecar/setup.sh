#!/usr/bin/env bash
# Talkye Sidecar — one-time setup script
# Called by Flutter app on startup. Creates venv, installs deps.
# Idempotent — fast no-op when everything is already installed.

set -e

SIDECAR_DIR="$(cd "$(dirname "$0")" && pwd)"

# Venv goes in user home (AppImage is read-only)
VENV_DIR="${TALKYE_VENV_DIR:-$SIDECAR_DIR/venv}"
PYTHON="${VENV_DIR}/bin/python"
PIP="${VENV_DIR}/bin/pip"

# Use bundled Python if available (set by AppRun in AppImage)
SYSTEM_PYTHON="${TALKYE_PYTHON:-python3}"

# ── Create venv if needed (or recreate if broken) ──
NEED_VENV=0
if [ ! -e "$PYTHON" ]; then
    NEED_VENV=1
elif ! "$PYTHON" -c "import sys" 2>/dev/null; then
    # Venv python is broken (e.g. stale symlink from old AppImage mount)
    echo "[setup] Venv python broken, recreating..."
    rm -rf "$VENV_DIR"
    NEED_VENV=1
fi

if [ "$NEED_VENV" = "1" ]; then
    echo "[setup] Creating Python venv in $VENV_DIR (using $SYSTEM_PYTHON)..."
    mkdir -p "$(dirname "$VENV_DIR")"
    "$SYSTEM_PYTHON" -m venv "$VENV_DIR"
fi

# ── Install base deps (fast if already installed) ──
echo "[setup] Syncing base dependencies..."
"$PIP" install -q -r "$SIDECAR_DIR/requirements-base.txt" 2>&1 | grep -v "already satisfied" || true

echo "[setup] Done"
