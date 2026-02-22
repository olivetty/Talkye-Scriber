"""Talkye Sidecar — TTS via pocket-tts Rust binary.

Calls core/target/release/tts_speak to generate WAV from text,
then plays it via paplay. English-only (pocket-tts limitation).

Usage:
    from tts import speak
    speak("Hello world")  # blocking, plays audio
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
    """Check if the TTS binary exists."""
    return os.path.isfile(_TTS_BIN)


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


def speak(text: str, voice: str | None = None, speed: float = 1.0) -> bool:
    """Synthesize and play text. Blocking. Returns True on success."""
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
                on_done: callable = None):
    """Synthesize and play in background thread."""
    import threading

    def _run():
        ok = speak(text, voice=voice, speed=speed)
        if on_done:
            on_done(ok)

    threading.Thread(target=_run, daemon=True, name="tts-speak").start()
