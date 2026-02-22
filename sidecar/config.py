"""Talkye Sidecar — Shared configuration and mutable state.

All globals live here so every module can import and modify them.
"""

import os
import platform
import tempfile
import time
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
TRANSLATE_ENABLED = os.getenv("TRANSLATE_ENABLED", "false").lower() == "true"
TRANSLATE_TO = os.getenv("TRANSLATE_TO", "en")
INPUT_MODE = os.getenv("DICTATE_INPUT", "ptt").lower()
TRIGGER_KEY = os.getenv("DICTATE_KEY", "KEY_RIGHTCTRL")
SOUND_THEME = os.getenv("DICTATE_SOUND_THEME", "subtle")
WAKEWORD_THRESHOLD = float(os.getenv("DICTATE_WAKEWORD_THRESHOLD", "0.55"))
STT_BACKEND = os.getenv("DICTATE_STT_BACKEND", "local")  # groq | local
DICTATE_TRANSLATE = os.getenv("DICTATE_TRANSLATE", "false").lower() == "true"

# ── Paths ──

AUDIOFILE = os.path.join(tempfile.gettempdir(), "dictate_p2t.wav")
RAWFILE = os.path.join(tempfile.gettempdir(), "dictate_p2t.raw")
SOUNDDIR = os.path.join(tempfile.gettempdir(), "dictate_sounds")

# whisper.cpp local STT
_PROJECT_ROOT = str(Path(__file__).resolve().parent.parent)
WHISPER_BIN = os.path.join(_PROJECT_ROOT, "whisper.cpp", "build", "bin", "whisper-cli")
WHISPER_MODEL = os.path.join(
    os.getenv("HOME", "/tmp"), ".config", "talkye", "models", "ggml-large-v3-turbo.bin"
)
WHISPER_MODEL_TRANSLATE = os.path.join(
    os.getenv("HOME", "/tmp"), ".config", "talkye", "models", "ggml-large-v3.bin"
)

# ── Timing ──

MIN_DURATION_SECS = 0.5
MAX_COMMAND_WORDS = 5
VAD_ACTIVE_TIMEOUT = int(os.getenv("VAD_ACTIVE_TIMEOUT", "8"))
SILENCE_ACTIVE_MS = int(os.getenv("VAD_SILENCE_ACTIVE_MS", "1000"))
SILENCE_STANDBY_MS = int(os.getenv("VAD_SILENCE_STANDBY_MS", "900"))
VAD_AUTO_ENTER = os.getenv("VAD_AUTO_ENTER", "true").lower() == "true"

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
training = False  # True during wake word training — suppresses Rustpotter detections
vad_active_until = 0.0  # timestamp — if > now, VAD is in ACTIVE state
vad_silent_end = False  # True = session should end without playing "stop" sound
vad_cooldown_until = 0.0  # timestamp — ignore wake word detections until this time

# ── Wake phrase text stripping ──
# When Rustpotter detects the wake word at audio level, the subsequent
# transcription may still contain the phrase. These variants are stripped
# from the start of transcribed text.
WAKE_PHRASE = "hey mira"  # default, overridden by settings.json
wake_phrase_words: list[str] = []  # normalized words of the wake phrase

# Common phonetic equivalents that Whisper may produce
_PHONETIC_MAP = {
    "hei": "hey", "hai": "hey", "hy": "hey",
    "ok": "okay", "okey": "okay",
    "hi": "hey",
}


def rebuild_strip_variants():
    """Rebuild wake phrase word list for stripping."""
    global wake_phrase_words
    p = WAKE_PHRASE.lower().strip()
    if not p:
        wake_phrase_words = []
        return
    wake_phrase_words = p.split()


rebuild_strip_variants()

# ── Core engine ──

from core import DictateCore
core = DictateCore()


def set_vad_active():
    """Set VAD to active state (processes speech without wake word)."""
    global vad_active_until
    vad_active_until = time.monotonic() + VAD_ACTIVE_TIMEOUT


def load_flutter_settings():
    """Read ~/.config/talkye/settings.json to pick up Flutter-saved settings."""
    global INPUT_MODE, TRIGGER_KEY, SOUND_THEME, VAD_ACTIVE_TIMEOUT, VAD_AUTO_ENTER
    global WAKEWORD_THRESHOLD, WAKE_PHRASE, STT_BACKEND, DICTATE_TRANSLATE
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
            if "inputMode" in cfg:
                INPUT_MODE = cfg["inputMode"]
                logger.info("Settings: input_mode=%s", INPUT_MODE)
            if "triggerKey" in cfg:
                TRIGGER_KEY = cfg["triggerKey"]
                logger.info("Settings: trigger_key=%s", TRIGGER_KEY)
            if "soundTheme" in cfg:
                SOUND_THEME = cfg["soundTheme"]
                logger.info("Settings: sound_theme=%s", SOUND_THEME)
            if "vadTimeout" in cfg:
                VAD_ACTIVE_TIMEOUT = int(cfg["vadTimeout"])
                logger.info("Settings: vad_timeout=%ds", VAD_ACTIVE_TIMEOUT)
            if "autoEnter" in cfg:
                VAD_AUTO_ENTER = bool(cfg["autoEnter"])
                logger.info("Settings: auto_enter=%s", VAD_AUTO_ENTER)
            if "wakePhrase" in cfg:
                WAKE_PHRASE = cfg["wakePhrase"].lower().strip()
                rebuild_strip_variants()
                logger.info("Settings: wake_phrase='%s'", WAKE_PHRASE)
            if "sttBackend" in cfg:
                val = cfg["sttBackend"]
                if val in ("groq", "local"):
                    STT_BACKEND = val
                    logger.info("Settings: stt_backend=%s", STT_BACKEND)
            if "dictateSttBackend" in cfg:
                val = cfg["dictateSttBackend"]
                if val in ("groq", "local"):
                    STT_BACKEND = val
                    logger.info("Settings: stt_backend=%s (from dictateSttBackend)", STT_BACKEND)
            if "dictateTranslate" in cfg:
                DICTATE_TRANSLATE = bool(cfg["dictateTranslate"])
                logger.info("Settings: dictate_translate=%s", DICTATE_TRANSLATE)
    except Exception as e:
        logger.warning("Failed to load Flutter settings: %s", e)
