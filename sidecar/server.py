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
    sound_theme: Optional[str] = None  # subtle | mechanical | silent
    magic_word: Optional[str] = None
    wakeword_threshold: Optional[float] = None
    vad_timeout: Optional[int] = None
    auto_enter: Optional[bool] = None


@app.get("/dictate/status")
def dictate_status():
    """Current PTT state and config."""
    import desktop
    return {
        "running": _desktop_running,
        "recording": desktop.rec_process is not None,
        "busy": desktop.busy,
        "language": desktop.LANGUAGE,
        "cleanup": desktop.LLM_CLEANUP,
        "input_mode": desktop.INPUT_MODE,
        "trigger_key": desktop.TRIGGER_KEY,
        "magic_word": desktop.MAGIC_WORD,
        "sound_theme": desktop.SOUND_THEME,
        "wakeword_threshold": desktop.WAKEWORD_THRESHOLD,
        "vad_timeout": desktop.VAD_ACTIVE_TIMEOUT,
        "auto_enter": desktop.VAD_AUTO_ENTER,
    }


@app.post("/dictate/config")
def dictate_config(cfg: DictateConfig):
    """Update dictation settings at runtime."""
    import desktop
    if cfg.language is not None:
        desktop.LANGUAGE = cfg.language
    if cfg.cleanup is not None:
        desktop.LLM_CLEANUP = cfg.cleanup
    if cfg.trigger_key is not None:
        desktop.TRIGGER_KEY = cfg.trigger_key
        logger.info("Trigger key changed to: %s", cfg.trigger_key)
    if cfg.input_mode is not None:
        desktop.INPUT_MODE = cfg.input_mode
        logger.info("Input mode changed to: %s", cfg.input_mode)
    if cfg.sound_theme is not None:
        desktop.SOUND_THEME = cfg.sound_theme
        logger.info("Sound theme changed to: %s", cfg.sound_theme)
    if cfg.magic_word is not None:
        desktop.MAGIC_WORD = cfg.magic_word.lower()
        logger.info("Magic word changed to: %s", cfg.magic_word)
    if cfg.wakeword_threshold is not None:
        desktop.WAKEWORD_THRESHOLD = cfg.wakeword_threshold
        logger.info("Wakeword threshold changed to: %.2f (requires restart)", cfg.wakeword_threshold)
    if cfg.vad_timeout is not None:
        desktop.VAD_ACTIVE_TIMEOUT = cfg.vad_timeout
        logger.info("VAD timeout changed to: %ds", cfg.vad_timeout)
    if cfg.auto_enter is not None:
        desktop.VAD_AUTO_ENTER = cfg.auto_enter
        logger.info("Auto enter changed to: %s", cfg.auto_enter)
    return {
        "ok": True,
        "language": desktop.LANGUAGE,
        "cleanup": desktop.LLM_CLEANUP,
        "trigger_key": desktop.TRIGGER_KEY,
        "input_mode": desktop.INPUT_MODE,
        "sound_theme": desktop.SOUND_THEME,
        "magic_word": desktop.MAGIC_WORD,
        "vad_timeout": desktop.VAD_ACTIVE_TIMEOUT,
        "auto_enter": desktop.VAD_AUTO_ENTER,
    }


class PreviewRequest(BaseModel):
    theme: str


@app.post("/dictate/preview-sound")
def preview_sound(req: PreviewRequest):
    """Play start + stop sounds for a theme so the user can preview it."""
    import desktop
    import time as _time
    import threading

    def _play():
        old = desktop.SOUND_THEME
        desktop.SOUND_THEME = req.theme
        desktop.play_sound("start")
        _time.sleep(0.8)
        desktop.play_sound("stop")
        desktop.SOUND_THEME = old

    threading.Thread(target=_play, daemon=True).start()
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
