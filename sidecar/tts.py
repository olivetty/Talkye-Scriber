"""Talkye Sidecar — TTS via persistent tts_server process.

Pocket-TTS model stays loaded in memory. Voice state loaded once.
Synthesis is ~1-2s per sentence (vs ~6.5s with fork-per-call).

Usage:
    from tts import speak, synthesize, load_voice, ensure_server
"""

import json
import logging
import os
import subprocess
import tempfile
import threading
from pathlib import Path

from platform_utils import user_env

logger = logging.getLogger(__name__)

_PROJECT_ROOT = str(Path(__file__).resolve().parent.parent)
_TTS_SERVER_BIN = os.path.join(_PROJECT_ROOT, "core", "target", "release", "tts_server")
_TTS_BIN = os.path.join(_PROJECT_ROOT, "core", "target", "release", "tts_speak")
_SETTINGS_PATH = os.path.join(
    os.getenv("HOME", "/tmp"), ".config", "talkye", "settings.json"
)

# Persistent server process
_server_proc: subprocess.Popen | None = None
_server_lock = threading.Lock()
_server_ready = False
_server_sample_rate = 24000
_current_voice: str = ""


def _kill_orphan_tts_servers():
    """Kill any orphaned tts_server processes not owned by us."""
    try:
        result = subprocess.run(
            ["pgrep", "-f", "tts_server"],
            capture_output=True, text=True, timeout=3,
        )
        if result.returncode == 0:
            for line in result.stdout.strip().split("\n"):
                pid = int(line.strip())
                # Don't kill our own process
                if _server_proc and pid == _server_proc.pid:
                    continue
                logger.warning("Killing orphaned tts_server (PID %d)", pid)
                try:
                    os.kill(pid, 9)
                except ProcessLookupError:
                    pass
                except PermissionError:
                    pass
    except Exception as e:
        logger.debug("Orphan check failed: %s", e)


def _get_active_voice() -> str:
    """Read activeVoicePath from Flutter settings."""
    try:
        if os.path.isfile(_SETTINGS_PATH):
            with open(_SETTINGS_PATH) as f:
                cfg = json.load(f)
            return cfg.get("activeVoicePath", "")
    except Exception:
        pass
    return ""


def is_available() -> bool:
    """Check if TTS server binary exists."""
    return os.path.isfile(_TTS_SERVER_BIN) or os.path.isfile(_TTS_BIN)


def pocket_available() -> bool:
    """Check if TTS binary exists."""
    return os.path.isfile(_TTS_SERVER_BIN) or os.path.isfile(_TTS_BIN)


def ensure_server() -> bool:
    """Start the persistent TTS server if not running. Returns True if ready."""
    global _server_proc, _server_ready, _server_sample_rate

    with _server_lock:
        # Check if already running
        if _server_proc is not None and _server_proc.poll() is None and _server_ready:
            return True

        # Clean up dead process
        if _server_proc is not None:
            try:
                _server_proc.kill()
                _server_proc.wait(timeout=2)
            except Exception:
                pass
            _server_proc = None
            _server_ready = False

        if not os.path.isfile(_TTS_SERVER_BIN):
            logger.warning("TTS server binary not found: %s", _TTS_SERVER_BIN)
            return False

        # Kill any orphaned tts_server processes before starting a new one
        _kill_orphan_tts_servers()

        try:
            _server_proc = subprocess.Popen(
                [_TTS_SERVER_BIN],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
                cwd=_PROJECT_ROOT,
            )
            # Wait for ready signal
            line = _server_proc.stdout.readline().strip()
            if not line:
                logger.error("TTS server failed to start (no output)")
                _server_proc.kill()
                _server_proc = None
                return False

            ready = json.loads(line)
            if ready.get("ready"):
                _server_sample_rate = ready.get("sample_rate", 24000)
                _server_ready = True
                logger.info("TTS server started (sr=%d)", _server_sample_rate)

                # Auto-load voice from settings
                voice = _get_active_voice()
                if voice:
                    _load_voice_unlocked(voice)

                return True
            else:
                logger.error("TTS server unexpected response: %s", ready)
                _server_proc.kill()
                _server_proc = None
                return False

        except Exception as e:
            logger.error("TTS server start failed: %s", e)
            if _server_proc:
                try:
                    _server_proc.kill()
                except Exception:
                    pass
            _server_proc = None
            return False


def _send_cmd(cmd: dict) -> dict | None:
    """Send a command to the TTS server and return the response."""
    global _server_proc, _server_ready

    with _server_lock:
        if _server_proc is None or _server_proc.poll() is not None:
            _server_ready = False
            return None

        try:
            _server_proc.stdin.write(json.dumps(cmd) + "\n")
            _server_proc.stdin.flush()
            line = _server_proc.stdout.readline().strip()
            if not line:
                logger.warning("TTS server returned empty response")
                _server_ready = False
                return None
            return json.loads(line)
        except Exception as e:
            logger.error("TTS server communication error: %s", e)
            _server_ready = False
            try:
                _server_proc.kill()
            except Exception:
                pass
            _server_proc = None
            return None


def _load_voice_unlocked(path: str) -> bool:
    """Load voice into server (must hold _server_lock or be called from ensure_server)."""
    global _current_voice
    if not _server_proc or _server_proc.poll() is not None:
        return False
    try:
        _server_proc.stdin.write(json.dumps({"cmd": "load_voice", "path": path}) + "\n")
        _server_proc.stdin.flush()
        line = _server_proc.stdout.readline().strip()
        if line:
            resp = json.loads(line)
            if resp.get("ok"):
                _current_voice = resp.get("voice", path)
                logger.info("TTS voice loaded: %s", _current_voice)
                return True
            else:
                logger.warning("TTS voice load failed: %s", resp.get("error"))
        return False
    except Exception as e:
        logger.error("TTS voice load error: %s", e)
        return False


def load_voice(path: str) -> bool:
    """Load a voice into the persistent TTS server."""
    global _current_voice
    if not ensure_server():
        return False
    with _server_lock:
        return _load_voice_unlocked(path)


def reload_voice_from_settings():
    """Reload voice from Flutter settings (call when settings change)."""
    voice = _get_active_voice()
    if voice and voice != _current_voice:
        load_voice(voice)


def synthesize(text: str, output_path: str | None = None,
               voice: str | None = None, speed: float = 1.0) -> dict | None:
    """Synthesize text to WAV via persistent TTS server.

    Returns {"ok": True, "path": str, "duration_ms": int, ...} or None.
    """
    if not text.strip():
        return None

    # Ensure server is running
    if not ensure_server():
        # Fallback to tts_speak binary
        return _synthesize_fallback(text, output_path, voice, speed)

    # Load voice if different from current
    if voice and voice != _current_voice:
        load_voice(voice)
    elif not voice:
        # Always re-check settings (user may have changed voice in Flutter)
        settings_voice = _get_active_voice()
        if settings_voice and settings_voice != _current_voice:
            load_voice(settings_voice)

    if output_path is None:
        fd, output_path = tempfile.mkstemp(suffix=".wav", prefix="tts_")
        os.close(fd)

    resp = _send_cmd({
        "cmd": "synthesize",
        "text": text,
        "output": output_path,
        "speed": speed,
    })

    if resp and resp.get("ok"):
        resp["path"] = output_path
        return resp

    # Server failed, try fallback
    logger.warning("TTS server synthesize failed, trying fallback")
    return _synthesize_fallback(text, output_path, voice, speed)


def _synthesize_fallback(text: str, output_path: str | None = None,
                         voice: str | None = None, speed: float = 1.0) -> dict | None:
    """Fallback: fork tts_speak binary (slow but reliable)."""
    if not os.path.isfile(_TTS_BIN):
        logger.warning("TTS binary not found: %s", _TTS_BIN)
        return None

    if output_path is None:
        fd, output_path = tempfile.mkstemp(suffix=".wav", prefix="tts_")
        os.close(fd)

    if voice is None:
        voice = _get_active_voice()

    cmd = [_TTS_BIN, text, output_path]
    if voice:
        cmd.append(voice)
        cmd.append(str(speed))
    elif speed != 1.0:
        cmd.append("")
        cmd.append(str(speed))

    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=30,
            cwd=_PROJECT_ROOT,
        )
        if result.returncode != 0:
            logger.error("TTS fallback failed: %s", result.stderr.strip())
            return None
        meta = json.loads(result.stdout.strip())
        meta["path"] = output_path
        return meta
    except Exception as e:
        logger.error("TTS fallback error: %s", e)
        return None


def speak(text: str, voice: str | None = None, speed: float = 1.0,
          language_id: str = "en") -> bool:
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
                language_id: str = "en", on_done: callable = None):
    """Synthesize and play in background thread."""
    import threading

    def _run():
        ok = speak(text, voice=voice, speed=speed, language_id=language_id)
        if on_done:
            on_done(ok)

    threading.Thread(target=_run, daemon=True, name="tts-speak").start()


def shutdown():
    """Stop the persistent TTS server."""
    global _server_proc, _server_ready
    with _server_lock:
        if _server_proc and _server_proc.poll() is None:
            try:
                _server_proc.stdin.write('{"cmd":"quit"}\n')
                _server_proc.stdin.flush()
                _server_proc.wait(timeout=5)
            except Exception:
                try:
                    _server_proc.kill()
                except Exception:
                    pass
            _server_proc = None
            _server_ready = False
            logger.info("TTS server stopped")
