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

# ── Install chatterbox-tts (optional, GPU-only) ──
# Chatterbox requires Python 3.11 (numpy<1.26 constraint).
# We use a SEPARATE venv (venv-chatterbox) managed by `uv`.
# Only install if user has opted in via settings or INSTALL_CHATTERBOX=1.

SETTINGS_FILE="$HOME/.config/talkye/settings.json"
CBX_VENV="$SIDECAR_DIR/venv-chatterbox"
CBX_PYTHON="$CBX_VENV/bin/python"
WANTS_CHATTERBOX=0

if [ "${INSTALL_CHATTERBOX:-0}" = "1" ]; then
    WANTS_CHATTERBOX=1
elif [ -f "$SETTINGS_FILE" ]; then
    if grep -q '"ttsBackend".*"chatterbox"' "$SETTINGS_FILE" 2>/dev/null; then
        WANTS_CHATTERBOX=1
    fi
fi

if [ "$WANTS_CHATTERBOX" = "1" ]; then
    # Check if already installed
    if [ -f "$CBX_PYTHON" ] && "$CBX_PYTHON" -c "import chatterbox" 2>/dev/null; then
        echo "[setup] chatterbox-tts already installed"
    else
        echo "[setup] Installing chatterbox-tts (GPU TTS, Python 3.11 venv)..."

        # Find uv
        UV=""
        if command -v uv &>/dev/null; then
            UV="uv"
        elif [ -f "$HOME/.local/bin/uv" ]; then
            UV="$HOME/.local/bin/uv"
        elif [ -f "$HOME/.cargo/bin/uv" ]; then
            UV="$HOME/.cargo/bin/uv"
        fi

        if [ -z "$UV" ]; then
            echo "[setup] Installing uv package manager..."
            curl -LsSf https://astral.sh/uv/install.sh | sh 2>&1 | tail -3
            UV="$HOME/.local/bin/uv"
        fi

        if [ ! -f "$UV" ] && ! command -v uv &>/dev/null; then
            echo "[setup] ERROR: uv not found — cannot install Chatterbox"
        else
            # Create venv with Python 3.11
            if [ ! -f "$CBX_PYTHON" ]; then
                echo "[setup] Creating Python 3.11 venv for Chatterbox..."
                "$UV" venv "$CBX_VENV" --python 3.11 2>&1 | tail -3
            fi

            if [ -f "$CBX_PYTHON" ]; then
                # Detect GPU type for correct PyTorch
                HAS_CUDA=0
                HAS_ROCM=0

                if command -v nvidia-smi &>/dev/null; then
                    HAS_CUDA=1
                fi
                if [ -d "/opt/rocm" ]; then
                    HAS_ROCM=1
                fi

                if [ "$HAS_CUDA" = "1" ]; then
                    echo "[setup] Installing PyTorch (CUDA) in chatterbox venv..."
                    "$UV" pip install --python "$CBX_PYTHON" \
                        torch torchaudio --index-url https://download.pytorch.org/whl/cu124 \
                        2>&1 | tail -3 || true
                elif [ "$HAS_ROCM" = "1" ]; then
                    echo "[setup] Installing PyTorch (ROCm) in chatterbox venv..."
                    "$UV" pip install --python "$CBX_PYTHON" \
                        torch torchaudio --index-url https://download.pytorch.org/whl/rocm6.2 \
                        2>&1 | tail -3 || true
                elif [ "$(uname)" = "Darwin" ]; then
                    echo "[setup] Installing PyTorch (macOS MPS) in chatterbox venv..."
                    "$UV" pip install --python "$CBX_PYTHON" \
                        torch torchaudio 2>&1 | tail -3 || true
                else
                    echo "[setup] No GPU detected — skipping Chatterbox"
                    WANTS_CHATTERBOX=0
                fi

                if [ "$WANTS_CHATTERBOX" = "1" ]; then
                    echo "[setup] Installing chatterbox-tts..."
                    "$UV" pip install --python "$CBX_PYTHON" \
                        chatterbox-tts fastapi "uvicorn[standard]" "setuptools<81" \
                        2>&1 | tail -5 || true

                    if "$CBX_PYTHON" -c "import chatterbox" 2>/dev/null; then
                        echo "[setup] chatterbox-tts installed OK"
                    else
                        echo "[setup] chatterbox-tts installation failed"
                    fi
                fi
            else
                echo "[setup] ERROR: Failed to create Python 3.11 venv"
            fi
        fi
    fi
fi

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
