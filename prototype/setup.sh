#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
OS="$(uname -s)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Push-to-Talk Dictation — Setup       ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

# ── Detect user (handle sudo) ─────────────────────
REAL_USER="${SUDO_USER:-$USER}"
REAL_UID="$(id -u "$REAL_USER" 2>/dev/null || echo $UID)"
REAL_HOME="$(eval echo "~$REAL_USER")"

# ── Python venv ────────────────────────────────────
info "Setting up Python environment..."
if [ ! -d "$DIR/venv" ]; then
    python3 -m venv "$DIR/venv"
fi
"$DIR/venv/bin/pip" install -q --upgrade pip

if [ "$OS" = "Linux" ]; then
    "$DIR/venv/bin/pip" install -q -r "$DIR/requirements.txt" evdev
else
    "$DIR/venv/bin/pip" install -q -r "$DIR/requirements.txt"
fi
ok "Python dependencies installed"

# ── System dependencies ────────────────────────────
if [ "$OS" = "Linux" ]; then
    info "Checking system dependencies..."
    PKGS=""
    command -v parecord &>/dev/null || PKGS="$PKGS pulseaudio-utils"
    command -v sox &>/dev/null      || PKGS="$PKGS sox"
    command -v xclip &>/dev/null    || PKGS="$PKGS xclip"
    command -v xdotool &>/dev/null  || PKGS="$PKGS xdotool"
    command -v curl &>/dev/null     || PKGS="$PKGS curl"
    command -v cmake &>/dev/null    || PKGS="$PKGS cmake"
    command -v gcc &>/dev/null      || PKGS="$PKGS build-essential"
    dpkg -l ladspa-sdk &>/dev/null 2>&1 || PKGS="$PKGS ladspa-sdk"

    if [ -n "$PKGS" ]; then
        info "Installing:$PKGS"
        sudo apt-get install -y $PKGS
    fi
    ok "System dependencies ready"

    # ── RNNoise (noise suppression) ────────────────
    if [ ! -f /usr/lib/ladspa/librnnoise_ladspa.so ]; then
        info "Building RNNoise noise suppressor..."
        RNNOISE_TMP="/tmp/rnnoise-build-$$"
        git clone --depth 1 https://github.com/werman/noise-suppression-for-voice.git "$RNNOISE_TMP"
        cmake -B "$RNNOISE_TMP/build" -S "$RNNOISE_TMP" -DCMAKE_BUILD_TYPE=Release -Wno-dev 2>/dev/null
        cmake --build "$RNNOISE_TMP/build" --target rnnoise_ladspa -j"$(nproc)"
        sudo mkdir -p /usr/lib/ladspa
        sudo cp "$RNNOISE_TMP/build/bin/ladspa/librnnoise_ladspa.so" /usr/lib/ladspa/
        rm -rf "$RNNOISE_TMP"
        ok "RNNoise installed"
    else
        ok "RNNoise already installed"
    fi

    # ── PipeWire RNNoise filter ────────────────────
    FILTER_DIR="$REAL_HOME/.config/pipewire/filter-chain.conf.d"
    if [ ! -f "$FILTER_DIR/99-voice-enhance.conf" ]; then
        info "Configuring PipeWire noise suppression..."
        mkdir -p "$FILTER_DIR"
        cat > "$FILTER_DIR/99-voice-enhance.conf" << 'PWEOF'
context.modules = [
    { name = libpipewire-module-filter-chain
        flags = [ nofail ]
        args = {
            node.description = "Enhanced Microphone"
            media.name       = "Enhanced Microphone"
            filter.graph = {
                nodes = [
                    {
                        type   = ladspa
                        name   = rnnoise
                        plugin = "librnnoise_ladspa"
                        label  = noise_suppressor_mono
                        control = {
                            "VAD Threshold (%)" 40.0
                        }
                    }
                ]
            }
            audio.rate = 48000
            audio.position = [ MONO ]
            capture.props = {
                node.name = "effect_input.voice_enhance"
                node.passive = true
                audio.rate = 48000
            }
            playback.props = {
                node.name = "effect_output.voice_enhance"
                media.class = Audio/Source
                audio.rate = 48000
            }
        }
    }
]
PWEOF
        chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.config/pipewire"
        # Restart PipeWire to load the filter
        sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" \
            systemctl --user restart pipewire pipewire-pulse 2>/dev/null || true
        ok "PipeWire noise suppression configured"
    else
        ok "PipeWire noise suppression already configured"
    fi

elif [ "$OS" = "Darwin" ]; then
    info "Checking macOS dependencies..."
    if ! command -v sox &>/dev/null; then
        info "Installing sox..."
        brew install sox
    fi
    ok "macOS dependencies ready"
fi

# ── Interactive configuration ──────────────────────
echo ""
echo -e "${CYAN}── Configuration ──${NC}"
echo ""

if [ -f "$DIR/.env" ]; then
    echo "Existing .env found."
    read -rp "Reconfigure? [y/N] " RECONF
    if [[ ! "$RECONF" =~ ^[Yy]$ ]]; then
        info "Keeping existing .env"
        SKIP_CONFIG=true
    else
        SKIP_CONFIG=false
    fi
else
    cp "$DIR/.env.example" "$DIR/.env"
    SKIP_CONFIG=false
fi

if [ "${SKIP_CONFIG:-false}" = "false" ]; then
    # Groq API key
    echo ""
    echo "Groq provides free, ultra-fast speech-to-text."
    echo "Get a free API key at: https://console.groq.com"
    echo ""
    read -rp "Groq API key (gsk_...): " GROQ_KEY
    if [ -n "$GROQ_KEY" ]; then
        sed -i "s|^GROQ_API_KEY=.*|GROQ_API_KEY=$GROQ_KEY|" "$DIR/.env"
        sed -i "s|^DICTATE_MODE=.*|DICTATE_MODE=groq|" "$DIR/.env"
        ok "Groq API key saved"
    fi

    # Language
    echo ""
    read -rp "Default language [auto/ro/en] (default: auto): " LANG_CHOICE
    LANG_CHOICE="${LANG_CHOICE:-auto}"
    sed -i "s|^DICTATE_LANGUAGE=.*|DICTATE_LANGUAGE=$LANG_CHOICE|" "$DIR/.env"

    # Trigger key
    echo ""
    echo "Trigger key (hold to record, release to transcribe):"
    echo "  Linux: KEY_RIGHTCTRL, KEY_LEFTCTRL, KEY_RIGHTALT, etc."
    echo "  macOS: ctrl_r, ctrl_l, cmd_r, alt_r, etc."
    if [ "$OS" = "Linux" ]; then
        DEF_KEY="KEY_RIGHTCTRL"
    else
        DEF_KEY="ctrl_r"
    fi
    read -rp "Trigger key (default: $DEF_KEY): " KEY_CHOICE
    KEY_CHOICE="${KEY_CHOICE:-$DEF_KEY}"
    sed -i "s|^DICTATE_KEY=.*|DICTATE_KEY=$KEY_CHOICE|" "$DIR/.env"

    # LLM cleanup (optional)
    echo ""
    read -rp "Enable LLM text cleanup? [y/N] " LLM_CHOICE
    if [[ "$LLM_CHOICE" =~ ^[Yy]$ ]]; then
        sed -i "s|^LLM_CLEANUP=.*|LLM_CLEANUP=true|" "$DIR/.env"
        echo "LLM providers: groq (free tier), xai, openai"
        read -rp "LLM provider (default: groq): " LLM_PROV
        LLM_PROV="${LLM_PROV:-groq}"
        sed -i "s|^LLM_PROVIDER=.*|LLM_PROVIDER=$LLM_PROV|" "$DIR/.env"

        if [ "$LLM_PROV" = "groq" ] && [ -n "${GROQ_KEY:-}" ]; then
            sed -i "s|^LLM_API_KEY=.*|LLM_API_KEY=$GROQ_KEY|" "$DIR/.env"
            ok "Using Groq key for LLM too"
        else
            read -rp "LLM API key: " LLM_KEY
            sed -i "s|^LLM_API_KEY=.*|LLM_API_KEY=$LLM_KEY|" "$DIR/.env"
        fi
    fi

    # Translation (optional)
    echo ""
    read -rp "Enable auto-translation? [y/N] " TRANS_CHOICE
    if [[ "$TRANS_CHOICE" =~ ^[Yy]$ ]]; then
        sed -i "s|^TRANSLATE_ENABLED=.*|TRANSLATE_ENABLED=true|" "$DIR/.env"
        read -rp "Translate to (default: en): " TRANS_TO
        TRANS_TO="${TRANS_TO:-en}"
        sed -i "s|^TRANSLATE_TO=.*|TRANSLATE_TO=$TRANS_TO|" "$DIR/.env"
    fi

    ok "Configuration saved to .env"
fi

# ── Systemd service (Linux) ────────────────────────
if [ "$OS" = "Linux" ]; then
    info "Installing systemd service..."

    cat > /tmp/whisper-p2t.service <<EOF
[Unit]
Description=Push-to-Talk Dictation Daemon
After=graphical-session.target

[Service]
Type=simple
ExecStart=$DIR/venv/bin/python $DIR/desktop.py
Environment=SUDO_USER=$REAL_USER
Environment=SUDO_UID=$REAL_UID
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/$REAL_UID
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    sudo cp /tmp/whisper-p2t.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable whisper-p2t
    ok "Systemd service installed"
fi

# ── Done ───────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            Setup Complete!                ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""

if [ "$OS" = "Linux" ]; then
    echo "Start now:"
    echo "  sudo systemctl start whisper-p2t"
    echo ""
    echo "Or run manually:"
    echo "  sudo $DIR/venv/bin/python $DIR/desktop.py"
else
    echo "Run:"
    echo "  $DIR/venv/bin/python $DIR/desktop.py"
    echo ""
    echo "NOTE: macOS will ask for Accessibility permission."
    echo "      System Settings → Privacy & Security → Accessibility"
fi

echo ""
echo "Hold ${KEY_CHOICE:-Right Ctrl} to record, release to transcribe."
echo "Edit $DIR/.env to change settings."
echo ""
