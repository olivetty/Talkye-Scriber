#!/bin/bash
# Start Talkye Python Sidecar
# Usage: ./sidecar/start.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Create venv if needed
if [ ! -d "$SCRIPT_DIR/venv" ]; then
    echo "Creating Python venv..."
    python3 -m venv "$SCRIPT_DIR/venv"
    "$SCRIPT_DIR/venv/bin/pip" install -r "$SCRIPT_DIR/requirements.txt" -q
    echo "Done."
fi

echo "Starting Talkye Sidecar on http://127.0.0.1:8179"
exec "$SCRIPT_DIR/venv/bin/uvicorn" server:app \
    --host 127.0.0.1 \
    --port 8179 \
    --app-dir "$SCRIPT_DIR"
