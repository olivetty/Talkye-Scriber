"""Talkye Python Sidecar — FastAPI server.

Runs desktop.py (push-to-talk dictation) as a background thread
and exposes config/status via HTTP for the Flutter app.

Usage:
    sudo sidecar/venv/bin/uvicorn server:app --host 127.0.0.1 --port 8179

    (sudo needed for evdev keyboard capture on Linux)

Endpoints:
    GET  /health              Server status
    GET  /dictate/status      PTT state + config
    POST /dictate/config      Update settings (language, cleanup, etc.)
    WS   /events              Real-time events stream
"""

import asyncio
import json
import logging
import os
import sys
import threading
from pathlib import Path
from typing import Optional

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

app = FastAPI(title="Talkye Sidecar", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── WebSocket clients for real-time events ──
_ws_clients: list[WebSocket] = []
_desktop_thread: threading.Thread | None = None
_desktop_running = False


async def _broadcast(event_type: str, data: dict = {}):
    """Send event to all connected WebSocket clients."""
    msg = json.dumps({"type": event_type, **data})
    dead = []
    for ws in _ws_clients:
        try:
            await ws.send_text(msg)
        except Exception:
            dead.append(ws)
    for ws in dead:
        _ws_clients.remove(ws)


# ── Desktop PTT thread ──

def _run_desktop():
    """Run desktop.py main() in a background thread."""
    global _desktop_running
    _desktop_running = True
    try:
        import desktop
        desktop.main()
    except Exception as e:
        logger.exception("Desktop PTT crashed: %s", e)
    finally:
        _desktop_running = False
        logger.info("Desktop PTT stopped")


@app.on_event("startup")
async def startup():
    """Start desktop PTT on server startup."""
    global _desktop_thread
    _desktop_thread = threading.Thread(target=_run_desktop, daemon=True, name="desktop-ptt")
    _desktop_thread.start()
    logger.info("Desktop PTT thread started")


# ── Health ──

@app.get("/health")
def health():
    return {
        "status": "ok",
        "version": "0.1.0",
        "services": {
            "dictate": _desktop_running,
            "tts": False,  # future: Chatterbox
        },
    }


# ── Dictate config/status ──

class DictateConfig(BaseModel):
    language: Optional[str] = None
    cleanup: Optional[bool] = None
    input_mode: Optional[str] = None  # ptt | vad
    trigger_key: Optional[str] = None
    sound_theme: Optional[str] = None  # subtle | silent | alex | luna
    stt_backend: Optional[str] = None  # groq | local
    dictate_translate: Optional[bool] = None  # translate to English via whisper
    vad_timeout: Optional[int] = None
    auto_enter: Optional[bool] = None


@app.get("/dictate/status")
def dictate_status():
    """Current PTT state and config."""
    import config as cfg
    return {
        "running": _desktop_running,
        "recording": cfg.rec_process is not None,
        "busy": cfg.busy,
        "language": cfg.LANGUAGE,
        "cleanup": cfg.LLM_CLEANUP,
        "input_mode": cfg.INPUT_MODE,
        "trigger_key": cfg.TRIGGER_KEY,
        "sound_theme": cfg.SOUND_THEME,
        "stt_backend": cfg.STT_BACKEND,
        "dictate_translate": cfg.DICTATE_TRANSLATE,
        "vad_timeout": cfg.VAD_ACTIVE_TIMEOUT,
        "auto_enter": cfg.VAD_AUTO_ENTER,
    }


@app.post("/dictate/config")
def dictate_config(cfg: DictateConfig):
    """Update dictation settings at runtime."""
    import config as _cfg
    if cfg.language is not None:
        _cfg.LANGUAGE = cfg.language
    if cfg.cleanup is not None:
        _cfg.LLM_CLEANUP = cfg.cleanup
    if cfg.trigger_key is not None:
        _cfg.TRIGGER_KEY = cfg.trigger_key
        logger.info("Trigger key changed to: %s", cfg.trigger_key)
    if cfg.input_mode is not None:
        _cfg.INPUT_MODE = cfg.input_mode
        logger.info("Input mode changed to: %s", cfg.input_mode)
    if cfg.sound_theme is not None:
        _cfg.SOUND_THEME = cfg.sound_theme
        logger.info("Sound theme changed to: %s", cfg.sound_theme)
    if cfg.stt_backend is not None and cfg.stt_backend in ("groq", "local"):
        _cfg.STT_BACKEND = cfg.stt_backend
        logger.info("STT backend changed to: %s", cfg.stt_backend)
    if cfg.dictate_translate is not None:
        _cfg.DICTATE_TRANSLATE = cfg.dictate_translate
        logger.info("Dictate translate changed to: %s", cfg.dictate_translate)
    if cfg.vad_timeout is not None:
        _cfg.VAD_ACTIVE_TIMEOUT = cfg.vad_timeout
        logger.info("VAD timeout changed to: %ds", cfg.vad_timeout)
    if cfg.auto_enter is not None:
        _cfg.VAD_AUTO_ENTER = cfg.auto_enter
        logger.info("Auto enter changed to: %s", cfg.auto_enter)
    return {
        "ok": True,
        "language": _cfg.LANGUAGE,
        "cleanup": _cfg.LLM_CLEANUP,
        "trigger_key": _cfg.TRIGGER_KEY,
        "input_mode": _cfg.INPUT_MODE,
        "sound_theme": _cfg.SOUND_THEME,
        "vad_timeout": _cfg.VAD_ACTIVE_TIMEOUT,
        "auto_enter": _cfg.VAD_AUTO_ENTER,
    }


class PreviewRequest(BaseModel):
    theme: str


@app.post("/dictate/preview-sound")
def preview_sound(req: PreviewRequest):
    """Play start + stop sounds for a theme so the user can preview it."""
    import config as _cfg
    from audio import play_sound
    import time as _time
    import threading

    def _play():
        old = _cfg.SOUND_THEME
        _cfg.SOUND_THEME = req.theme
        play_sound("start")
        _time.sleep(0.8)
        play_sound("stop")
        _cfg.SOUND_THEME = old

    threading.Thread(target=_play, daemon=True).start()
    return {"ok": True}


# ── Wake word training ──

_wakeword_dir = os.path.join(os.getenv("HOME", "/tmp"), ".config", "talkye", "wakeword-samples")
_wakeword_rpw = os.path.join(os.getenv("HOME", "/tmp"), ".config", "talkye", "wakeword.rpw")
_wakeword_bin = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "wakeword", "target", "release", "wakeword"
)


class WakewordRecordRequest(BaseModel):
    sample_index: int
    duration: int = 3


@app.post("/wakeword/record-sample")
def wakeword_record_sample(req: WakewordRecordRequest):
    """Record a single wake word sample."""
    import subprocess
    import config as _cfg
    os.makedirs(_wakeword_dir, exist_ok=True)
    output_path = os.path.join(_wakeword_dir, f"sample_{req.sample_index}.wav")
    _cfg.training = True
    try:
        result = subprocess.run(
            [_wakeword_bin, "record-sample", output_path, str(req.duration)],
            capture_output=True, timeout=req.duration + 5, text=True,
        )
        if result.returncode != 0:
            return {"ok": False, "error": result.stderr.strip()}
        return {"ok": True, "path": output_path}
    except Exception as e:
        return {"ok": False, "error": str(e)}
    finally:
        _cfg.training = False


class WakewordBuildRequest(BaseModel):
    name: str = "hey_mira"


@app.post("/wakeword/build")
def wakeword_build(req: WakewordBuildRequest):
    """Build .rpw wakeword from recorded samples."""
    import subprocess
    if not os.path.isdir(_wakeword_dir):
        return {"ok": False, "error": "No samples recorded yet"}
    samples = [f for f in os.listdir(_wakeword_dir) if f.endswith(".wav")]
    if len(samples) < 3:
        return {"ok": False, "error": f"Need at least 3 samples, have {len(samples)}"}
    try:
        result = subprocess.run(
            [_wakeword_bin, "build", req.name, _wakeword_dir, _wakeword_rpw],
            capture_output=True, timeout=30, text=True,
        )
        if result.returncode != 0:
            return {"ok": False, "error": result.stderr.strip()}
        return {"ok": True, "rpw_path": _wakeword_rpw, "samples": len(samples)}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.get("/wakeword/status")
def wakeword_status():
    """Check wake word training status."""
    samples = []
    if os.path.isdir(_wakeword_dir):
        samples = sorted([f for f in os.listdir(_wakeword_dir) if f.endswith(".wav")])
    return {
        "trained": os.path.isfile(_wakeword_rpw),
        "rpw_path": _wakeword_rpw,
        "samples": samples,
        "sample_count": len(samples),
        "binary_available": os.path.isfile(_wakeword_bin),
    }


@app.delete("/wakeword/samples")
def wakeword_clear_samples():
    """Clear all recorded wake word samples."""
    import shutil
    if os.path.isdir(_wakeword_dir):
        shutil.rmtree(_wakeword_dir)
    return {"ok": True}


# ── WebSocket events ──

@app.websocket("/events")
async def websocket_events(ws: WebSocket):
    await ws.accept()
    _ws_clients.append(ws)
    logger.info("WebSocket client connected (%d total)", len(_ws_clients))
    try:
        while True:
            await ws.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        if ws in _ws_clients:
            _ws_clients.remove(ws)
        logger.info("WebSocket client disconnected (%d remaining)", len(_ws_clients))
