"""Talkye Scriber — Python Sidecar (FastAPI).

Runs desktop.py (push-to-talk dictation) as a background thread
and exposes config/status via HTTP for the Flutter app.

Endpoints:
    GET  /health              Server status
    GET  /dictate/status      PTT state + config
    POST /dictate/config      Update settings
    POST /dictate/preview-sound  Preview sound theme
    WS   /events              Real-time events stream
"""

import asyncio
import json
import logging
import os
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

app = FastAPI(title="Talkye Scriber Sidecar", version="0.2.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://127.0.0.1:*", "http://localhost:*"],
    allow_origin_regex=r"^https?://(127\.0\.0\.1|localhost)(:\d+)?$",
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── WebSocket clients for real-time events ──
_ws_clients: list[WebSocket] = []
_desktop_thread: threading.Thread | None = None
_desktop_running = False


async def _broadcast(event_type: str, data: dict | None = None):
    """Send event to all connected WebSocket clients."""
    msg = json.dumps({"type": event_type, **(data or {})})
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
    global _desktop_thread
    _desktop_thread = threading.Thread(target=_run_desktop, daemon=True, name="desktop-ptt")
    _desktop_thread.start()
    logger.info("Desktop PTT thread started")


# ── Health ──

@app.get("/health")
def health():
    return {
        "status": "ok",
        "version": "0.2.0",
        "services": {"dictate": _desktop_running},
    }


# ── Dictate config/status ──

class DictateConfig(BaseModel):
    language: Optional[str] = None
    cleanup: Optional[bool] = None
    trigger_key: Optional[str] = None
    sound_theme: Optional[str] = None
    stt_backend: Optional[str] = None  # groq | local
    dictate_translate: Optional[bool] = None
    dictate_grammar: Optional[bool] = None
    groq_api_key: Optional[str] = None


@app.get("/dictate/status")
def dictate_status():
    import config as cfg
    return {
        "running": _desktop_running,
        "recording": cfg.rec_process is not None,
        "busy": cfg.busy,
        "language": cfg.LANGUAGE,
        "trigger_key": cfg.TRIGGER_KEY,
        "sound_theme": cfg.SOUND_THEME,
        "stt_backend": cfg.STT_BACKEND,
        "dictate_translate": cfg.DICTATE_TRANSLATE,
        "dictate_grammar": cfg.DICTATE_GRAMMAR,
    }


@app.post("/dictate/config")
def dictate_config(cfg: DictateConfig):
    import config as _cfg
    if cfg.language is not None:
        _cfg.LANGUAGE = cfg.language
    if cfg.cleanup is not None:
        _cfg.LLM_CLEANUP = cfg.cleanup
    if cfg.trigger_key is not None:
        _cfg.TRIGGER_KEY = cfg.trigger_key
        logger.info("Trigger key changed to: %s", cfg.trigger_key)
    if cfg.sound_theme is not None:
        _cfg.SOUND_THEME = cfg.sound_theme
        logger.info("Sound theme changed to: %s", cfg.sound_theme)
    if cfg.stt_backend is not None and cfg.stt_backend in ("groq", "local"):
        _cfg.STT_BACKEND = cfg.stt_backend
        logger.info("STT backend changed to: %s", cfg.stt_backend)
    if cfg.dictate_translate is not None:
        _cfg.DICTATE_TRANSLATE = cfg.dictate_translate
        logger.info("Dictate translate: %s", cfg.dictate_translate)
    if cfg.dictate_grammar is not None:
        _cfg.DICTATE_GRAMMAR = cfg.dictate_grammar
        logger.info("Dictate grammar: %s", cfg.dictate_grammar)
    if cfg.groq_api_key is not None:
        # Update Groq key at runtime for LLM post-processing
        _cfg.core.llm_api_key = cfg.groq_api_key
        _cfg.core.groq_api_key = cfg.groq_api_key
        os.environ["GROQ_API_KEY"] = cfg.groq_api_key
        logger.info("Groq API key updated")
    return {"ok": True}


class PreviewRequest(BaseModel):
    theme: str


@app.post("/dictate/preview-sound")
def preview_sound(req: PreviewRequest):
    import config as _cfg
    from audio import play_sound
    import time as _time

    def _play():
        old = _cfg.SOUND_THEME
        _cfg.SOUND_THEME = req.theme
        play_sound("start")
        _time.sleep(0.8)
        play_sound("stop")
        _cfg.SOUND_THEME = old

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
