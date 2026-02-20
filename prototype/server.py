"""Dictate API Server — REST + WebSocket speech-to-text.

Endpoints:
    POST /v1/transcribe     Upload audio, get text back
    WS   /v1/stream         WebSocket: send audio, receive streaming text
    GET  /v1/health         Server status
    GET  /                  Web widget demo page

Usage:
    uvicorn server:app --host 0.0.0.0 --port 8178

    # Or with auto-reload for development:
    uvicorn server:app --host 0.0.0.0 --port 8178 --reload
"""

import logging
import os
import tempfile
from typing import Optional

from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, UploadFile, HTTPException, WebSocket
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from pathlib import Path

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

from core import DictateCore

# Initialize core with server-specific defaults
SERVER_MODE = os.getenv("WHISPER_BACKEND", os.getenv("DICTATE_MODE", "groq")).lower()
core = DictateCore(mode=SERVER_MODE)

ALLOWED_EXTENSIONS = {"wav", "webm", "ogg", "mp3", "m4a", "flac"}

app = FastAPI(
    title="Dictate API",
    description="Speech-to-text API with optional LLM cleanup and translation.",
    version="1.0.0",
)

# Serve static files (widget)
static_dir = Path(__file__).parent / "static"
if static_dir.exists():
    app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")


# ── REST Endpoints ─────────────────────────────────

@app.get("/v1/health")
@app.get("/health")
def health():
    return {
        "status": "ok",
        "mode": core.mode,
        "model": core.whisper_model,
    }


@app.post("/v1/transcribe")
@app.post("/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    language: Optional[str] = Form(None),
    cleanup: Optional[bool] = Form(False),
    translate_to: Optional[str] = Form(None),
):
    """Transcribe audio file to text.

    - **file**: Audio file (WAV, WebM, OGG, MP3, M4A, FLAC)
    - **language**: Force language (ro, en) or omit for auto-detect
    - **cleanup**: Clean up transcription with LLM (default: false)
    - **translate_to**: Translate to language code (en, ro, etc.) or omit
    """
    ext = file.filename.rsplit(".", 1)[-1].lower() if file.filename else "wav"
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(400, f"Unsupported format: .{ext}")

    try:
        audio_bytes = await file.read()
        result = core.process_bytes(
            audio_bytes,
            format=ext,
            language=language,
            cleanup=cleanup or False,
            translate_to=translate_to,
        )
        return result
    except Exception as e:
        logger.exception("Transcription failed")
        raise HTTPException(500, f"Transcription error: {e}")


# ── WebSocket Streaming ───────────────────────────

@app.websocket("/v1/stream")
async def websocket_stream(ws: WebSocket):
    """WebSocket endpoint for streaming speech-to-text.

    Protocol:
        1. Client sends JSON config: {"language": "auto", "cleanup": true, "translate_to": "en"}
        2. Client sends binary audio data (complete file)
        3. Server sends JSON messages:
           - {"type": "transcription", "text": "...", "language": "ro", "duration": 2.1}
           - {"type": "token", "text": "..."} (if cleanup/translate enabled, streamed)
           - {"type": "done", "text": "full final text"}
           - {"type": "error", "message": "..."}
    """
    await ws.accept()
    logger.info("WebSocket client connected")

    try:
        # Step 1: receive config
        config = await ws.receive_json()
        language = config.get("language")
        cleanup = config.get("cleanup", False)
        translate_to = config.get("translate_to")
        audio_format = config.get("format", "wav")

        if language == "auto":
            language = None

        # Step 2: receive audio data
        audio_bytes = await ws.receive_bytes()
        logger.info("Received %d bytes of audio (%s)", len(audio_bytes), audio_format)

        # Step 3: transcribe
        with tempfile.NamedTemporaryFile(suffix=f".{audio_format}", delete=False) as tmp:
            tmp.write(audio_bytes)
            tmp.flush()
            tmp_path = tmp.name

        try:
            result = core.transcribe(tmp_path, language)
            await ws.send_json({
                "type": "transcription",
                "text": result["text"],
                "language": result["language"],
                "duration": result["duration"],
            })

            if not result["text"].strip():
                await ws.send_json({"type": "done", "text": ""})
                return

            # Step 4: LLM streaming (if requested)
            if cleanup or translate_to:
                full_text = []
                for token in core.llm_process_stream(
                    result["text"], result["language"], cleanup, translate_to,
                ):
                    full_text.append(token)
                    await ws.send_json({"type": "token", "text": token})

                final = "".join(full_text).strip()
                await ws.send_json({"type": "done", "text": final})
            else:
                await ws.send_json({"type": "done", "text": result["text"]})
        finally:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

    except Exception as e:
        logger.exception("WebSocket error")
        try:
            await ws.send_json({"type": "error", "message": str(e)})
        except Exception:
            pass
    finally:
        logger.info("WebSocket client disconnected")


# ── Widget Page ────────────────────────────────────

@app.get("/", response_class=HTMLResponse)
async def widget_page():
    """Serve the demo page with the voice input widget."""
    widget_path = static_dir / "widget.html"
    if widget_path.exists():
        return HTMLResponse(widget_path.read_text())
    return HTMLResponse("<h1>Dictate API</h1><p>Widget not found. Create static/widget.html</p>")
