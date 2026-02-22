"""Talkye Sidecar — TTS router.

Routes TTS requests to the active backend:
  - pocket-tts: Rust binary, CPU, English only (default fallback)
  - chatterbox: Python, GPU, 23 languages, voice cloning

Usage:
    from tts import speak, set_backend
    speak("Hello world")  # uses active backend
    set_backend("chatterbox")  # switch backend
"""

import json
import logging
import os
import subprocess
import tempfile
from pathlib import Path

from platform_utils import user_env

logger = logging.getLogger(__name__)

_PROJECT_ROOT = str(Path(__file__).resolve().parent.parent)
_TTS_BIN = os.path.join(_PROJECT_ROOT, "core", "target", "release", "tts_speak")
_SETTINGS_PATH = os.path.join(
    os.getenv("HOME", "/tmp"), ".config", "talkye", "settings.json"
)

# Active TTS backend: "pocket" or "chatterbox"
_active_backend = "pocket"


def set_backend(backend: str):
    """Set the active TTS backend."""
    global _active_backend
    if backend in ("pocket", "chatterbox"):
        _active_backend = backend
        logger.info("TTS backend set to: %s", backend)


def get_backend() -> str:
    """Get the active TTS backend name."""
    return _active_backend


def get_backend_from_settings() -> str:
    """Read ttsBackend from Flutter settings."""
    try:
        if os.path.isfile(_SETTINGS_PATH):
            with open(_SETTINGS_PATH) as f:
                cfg = json.load(f)
            return cfg.get("ttsBackend", "pocket")
    except Exception:
        pass
    return "pocket"


def _get_active_voice() -> str | None:
    """Read activeVoicePath from Flutter settings."""
    try:
        if os.path.isfile(_SETTINGS_PATH):
            import json
            with open(_SETTINGS_PATH) as f:
                cfg = json.load(f)
            path = cfg.get("activeVoicePath", "")
            if path and os.path.isfile(path):
                return path
    except Exception:
        pass
    return None


def is_available() -> bool:
    """Check if any TTS backend is available."""
    if os.path.isfile(_TTS_BIN):
        return True
    try:
        from tts_chatterbox import chatterbox_tts
        if chatterbox_tts.available:
            return True
    except ImportError:
        pass
    return False


def pocket_available() -> bool:
    """Check if pocket-tts binary exists."""
    return os.path.isfile(_TTS_BIN)


def chatterbox_available() -> bool:
    """Check if Chatterbox is available (installed + GPU)."""
    try:
        from tts_chatterbox import chatterbox_tts
        return chatterbox_tts.available
    except ImportError:
        return False


def synthesize(text: str, output_path: str | None = None,
               voice: str | None = None, speed: float = 1.0) -> dict | None:
    """Generate WAV from text. Returns metadata dict or None on failure.

    Args:
        text: Text to speak (English).
        output_path: Where to write WAV. If None, uses a temp file.
        voice: Voice path override. If None, uses POCKET_VOICE from .env.
        speed: Playback speed multiplier.

    Returns:
        {"ok": True, "path": str, "duration_ms": int, ...} or None
    """
    if not is_available():
        logger.warning("TTS binary not found: %s", _TTS_BIN)
        return None

    if not text.strip():
        return None

    if output_path is None:
        fd, output_path = tempfile.mkstemp(suffix=".wav", prefix="tts_")
        os.close(fd)

    # Use Flutter's active voice if no override specified
    if voice is None:
        voice = _get_active_voice()

    cmd = [_TTS_BIN, text, output_path]
    if voice:
        cmd.append(voice)
        cmd.append(str(speed))
    elif speed != 1.0:
        cmd.append("")  # empty voice = use default from .env
        cmd.append(str(speed))

    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=30,
            cwd=_PROJECT_ROOT,
        )
        if result.returncode != 0:
            logger.error("TTS failed: %s", result.stderr.strip())
            return None

        meta = json.loads(result.stdout.strip())
        meta["path"] = output_path
        return meta
    except subprocess.TimeoutExpired:
        logger.error("TTS timed out for: %s", text[:50])
        return None
    except Exception as e:
        logger.error("TTS error: %s", e)
        return None


def speak(text: str, voice: str | None = None, speed: float = 1.0,
          language_id: str = "en") -> bool:
    """Synthesize and play text. Blocking. Returns True on success.

    Routes to the active backend (pocket-tts or Chatterbox).
    """
    backend = get_backend_from_settings()

    # Try Chatterbox if selected and available
    if backend == "chatterbox":
        try:
            from tts_chatterbox import chatterbox_tts
            if chatterbox_tts.available:
                ok = chatterbox_tts.speak(
                    text, language_id=language_id, voice_ref=voice,
                )
                if ok:
                    return True
                logger.warning("Chatterbox speak failed, falling back to pocket-tts")
        except ImportError:
            logger.warning("chatterbox-tts not installed, falling back to pocket-tts")

    # Fallback: pocket-tts (CPU, English)
    return _speak_pocket(text, voice=voice, speed=speed)


def _speak_pocket(text: str, voice: str | None = None, speed: float = 1.0) -> bool:
    """Speak via pocket-tts (CPU, English). Blocking."""
    meta = synthesize(text, voice=voice, speed=speed)
    if not meta:
        return False

    wav_path = meta["path"]
    try:
        env = user_env()
        subprocess.run(
            ["paplay", wav_path],
            timeout=30, env=env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        return True
    except Exception as e:
        logger.error("Playback failed: %s", e)
        return False
    finally:
        try:
            os.unlink(wav_path)
        except OSError:
            pass


def speak_async(text: str, voice: str | None = None, speed: float = 1.0,
                language_id: str = "en", on_done: callable = None):
    """Synthesize and play in background thread."""
    import threading

    def _run():
        ok = speak(text, voice=voice, speed=speed, language_id=language_id)
        if on_done:
            on_done(ok)

    threading.Thread(target=_run, daemon=True, name="tts-speak").start()
