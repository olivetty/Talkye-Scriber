"""Talkye Scriber Sidecar — Shared configuration and mutable state."""

import os
import platform
import tempfile
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")

# ── Platform ──

PLATFORM = platform.system()
IS_LINUX = PLATFORM == "Linux"
IS_MAC = PLATFORM == "Darwin"

# ── Env config ──

LANGUAGE = os.getenv("DICTATE_LANGUAGE", "auto")
LLM_CLEANUP = os.getenv("LLM_CLEANUP", "false").lower() == "true"
TRIGGER_KEY = os.getenv("DICTATE_KEY", "KEY_RIGHTCTRL")
SOUND_THEME = os.getenv("DICTATE_SOUND_THEME", "subtle")
STT_BACKEND = os.getenv("DICTATE_STT_BACKEND", "local")  # groq | local
DICTATE_TRANSLATE = os.getenv("DICTATE_TRANSLATE", "false").lower() == "true"
DICTATE_GRAMMAR = os.getenv("DICTATE_GRAMMAR", "false").lower() == "true"

# ── Paths ──

AUDIOFILE = os.path.join(tempfile.gettempdir(), "dictate_p2t.wav")
RAWFILE = os.path.join(tempfile.gettempdir(), "dictate_p2t.raw")
SOUNDDIR = os.path.join(tempfile.gettempdir(), "dictate_sounds")

# whisper.cpp local STT
_PROJECT_ROOT = str(Path(__file__).resolve().parent.parent)
WHISPER_BIN = os.getenv("TALKYE_WHISPER_BIN",
    os.path.join(_PROJECT_ROOT, "whisper.cpp", "build", "bin", "whisper-cli"))
WHISPER_MODEL = os.path.join(
    os.getenv("HOME", "/tmp"), ".config", "talkye", "models", "ggml-large-v3-turbo.bin"
)

# sox binary (bundled in AppImage or system)
SOX_BIN = os.getenv("TALKYE_SOX", "sox")

# ── Timing ──

MIN_DURATION_SECS = 0.5
MAX_COMMAND_WORDS = 5

# ── Linux-specific ──

KEYBOARD_NAME = os.getenv("DICTATE_KEYBOARD_NAME", "")
AUDIO_SOURCE_NAME = os.getenv("DICTATE_SOURCE_NAME", "")
REAL_USER = os.getenv("SUDO_USER", os.getenv("USER", ""))
REAL_UID = os.getenv("SUDO_UID", str(os.getuid()))
REAL_HOME = f"/home/{REAL_USER}" if IS_LINUX and os.getenv("SUDO_USER") else os.getenv("HOME", "")
DISPLAY = os.getenv("DISPLAY", ":0")
XDG_RUNTIME = os.getenv("XDG_RUNTIME_DIR", f"/run/user/{REAL_UID}" if IS_LINUX else "")

# ── Mutable runtime state ──

rec_process = None
rec_start_time = 0.0
busy = False

# ── Core engine (LLM post-processing) ──

from core import DictateCore
core = DictateCore(
    llm_provider="groq",
    llm_api_key=os.getenv("GROQ_API_KEY", ""),
    llm_model="llama-3.3-70b-versatile",
)


def load_flutter_settings():
    """Read ~/.config/talkye/settings.json to pick up Flutter-saved settings."""
    global TRIGGER_KEY, SOUND_THEME, STT_BACKEND, DICTATE_TRANSLATE, DICTATE_GRAMMAR
    import json
    import logging
    logger = logging.getLogger(__name__)
    try:
        settings_path = os.path.join(
            os.getenv("HOME", "/tmp"), ".config", "talkye", "settings.json"
        )
        if os.path.isfile(settings_path):
            with open(settings_path) as f:
                cfg = json.load(f)
            if "triggerKey" in cfg:
                TRIGGER_KEY = cfg["triggerKey"]
                logger.info("Settings: trigger_key=%s", TRIGGER_KEY)
            if "soundTheme" in cfg:
                SOUND_THEME = cfg["soundTheme"]
                logger.info("Settings: sound_theme=%s", SOUND_THEME)
            if "dictateTranslate" in cfg:
                DICTATE_TRANSLATE = bool(cfg["dictateTranslate"])
                logger.info("Settings: dictate_translate=%s", DICTATE_TRANSLATE)
            if "dictateGrammar" in cfg:
                DICTATE_GRAMMAR = bool(cfg["dictateGrammar"])
                logger.info("Settings: dictate_grammar=%s", DICTATE_GRAMMAR)
            # Load Groq API key from settings if available
            if "groqApiKey" in cfg and cfg["groqApiKey"]:
                core.llm_api_key = cfg["groqApiKey"]
                core.groq_api_key = cfg["groqApiKey"]
                os.environ["GROQ_API_KEY"] = cfg["groqApiKey"]
                logger.info("Settings: groq_api_key loaded")
    except Exception as e:
        logger.warning("Failed to load Flutter settings: %s", e)
