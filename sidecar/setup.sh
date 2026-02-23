#!/usr/bin/env bash
# Talkye Sidecar — one-time setup script
# Called by Flutter app on startup. Creates venv, installs deps.
# Idempotent — fast no-op when everything is already installed.

set -e

SIDECAR_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$SIDECAR_DIR/venv"
PYTHON="${VENV_DIR}/bin/python"
PIP="${VENV_DIR}/bin/pip"

# ── Create venv if needed ──
if [ ! -f "$PYTHON" ]; then
    echo "[setup] Creating Python venv..."
    python3 -m venv "$VENV_DIR"
fi

# ── Install base deps (fast if already installed) ──
echo "[setup] Syncing base dependencies..."
"$PIP" install -q -r "$SIDECAR_DIR/requirements-base.txt" 2>&1 | grep -v "already satisfied" || true

echo "[setup] Done"
