#!/usr/bin/env bash
# Talkye Sidecar — one-time setup script
# Called by Flutter app on startup. Creates venv, installs deps,
# detects CUDA and installs llama-cpp-python with GPU support.
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

# ── Install llama-cpp-python with CUDA ──
if "$PYTHON" -c "import llama_cpp" 2>/dev/null; then
    echo "[setup] llama-cpp-python already installed"
    exit 0
fi

echo "[setup] Installing llama-cpp-python..."

# Detect NVIDIA GPU
if command -v nvcc &>/dev/null || command -v nvidia-smi &>/dev/null; then
    echo "[setup] NVIDIA GPU detected"

    # Try pre-built CUDA 12.4 wheel first (instant, works if libcudart.so.12 exists)
    if "$PIP" install -q llama-cpp-python \
        --extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cu124 2>/dev/null; then
        # Verify it actually loads (might fail if CUDA runtime version mismatches)
        if "$PYTHON" -c "import llama_cpp" 2>/dev/null; then
            echo "[setup] Pre-built CUDA wheel OK"
            exit 0
        fi
        echo "[setup] Pre-built wheel installed but failed to load, recompiling..."
        "$PIP" uninstall -y llama-cpp-python 2>/dev/null || true
    fi

    # Compile from source with system CUDA (handles CUDA 13.x etc.)
    echo "[setup] Compiling llama-cpp-python with CUDA (this takes a few minutes first time)..."
    CMAKE_ARGS="-DGGML_CUDA=on" "$PIP" install llama-cpp-python --no-cache-dir 2>&1 | tail -5
    if "$PYTHON" -c "import llama_cpp" 2>/dev/null; then
        echo "[setup] CUDA build OK"
        exit 0
    fi
fi

# CPU fallback
echo "[setup] Installing llama-cpp-python (CPU)..."
"$PIP" install -q llama-cpp-python \
    --extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cpu 2>/dev/null \
    || "$PIP" install -q llama-cpp-python 2>/dev/null || true

echo "[setup] Done"
