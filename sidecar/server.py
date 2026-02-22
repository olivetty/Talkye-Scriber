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
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

app = FastAPI(title="Talkye Sidecar", version="0.1.0")

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


@app.on_event("startup")
async def auto_load_chatterbox():
    """Auto-load Chatterbox if selected in settings, then warm up."""
    def _load():
        try:
            from tts import get_backend_from_settings
            if get_backend_from_settings() != "chatterbox":
                return
            from tts_chatterbox import chatterbox_tts
            if chatterbox_tts.available:
                logger.info("Auto-loading Chatterbox (selected in settings)...")
                if chatterbox_tts.load():
                    # Warm up CUDA kernels so first real generation is fast
                    chatterbox_tts.warmup()
        except Exception as e:
            logger.info("Chatterbox auto-load skipped: %s", e)
    threading.Thread(target=_load, daemon=True, name="cbx-autoload").start()
    # Start health monitor for chatterbox worker
    asyncio.create_task(_monitor_chatterbox_worker())


async def _monitor_chatterbox_worker():
    """Periodic health check for the Chatterbox worker (port 8180)."""
    import urllib.request
    _consecutive_failures = 0
    while True:
        await asyncio.sleep(30)
        try:
            def _check():
                req = urllib.request.Request("http://127.0.0.1:8180/health")
                with urllib.request.urlopen(req, timeout=3) as resp:
                    return resp.status == 200
            ok = await asyncio.get_event_loop().run_in_executor(None, _check)
            if ok:
                _consecutive_failures = 0
            else:
                _consecutive_failures += 1
        except Exception:
            _consecutive_failures += 1
        if _consecutive_failures >= 3:
            logger.warning("[MONITOR] Chatterbox worker unreachable (%d consecutive failures)", _consecutive_failures)
            _consecutive_failures = 0  # Reset to avoid log spam


@app.on_event("shutdown")
async def shutdown():
    """Stop Chatterbox worker on server shutdown."""
    try:
        from tts_chatterbox import chatterbox_tts
        if chatterbox_tts.worker_running:
            chatterbox_tts.unload()
    except Exception:
        pass


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


# ── Local LLM ──
# LLM is loaded on-demand when user enters Chat screen,
# and unloaded when they leave. Saves ~3.4GB VRAM.


@app.get("/llm/status")
def llm_status():
    """Local LLM status."""
    try:
        from llm_local import local_llm, _MODEL_PATH
        # Check if llama-cpp-python is installed
        try:
            import llama_cpp
            lib_installed = True
        except ImportError:
            lib_installed = False
        return {
            "available": local_llm.available,
            "loaded": local_llm.loaded,
            "model_path": _MODEL_PATH,
            "lib_installed": lib_installed,
        }
    except ImportError:
        return {"available": False, "loaded": False, "model_path": "", "lib_installed": False}


@app.post("/llm/load")
def llm_load():
    """Load LLM into GPU memory (called when entering Chat screen)."""
    try:
        from llm_local import local_llm
        if local_llm.loaded:
            return {"ok": True, "message": "Already loaded"}
        if not local_llm.available:
            return {"ok": False, "error": "Model not downloaded"}
        ok = local_llm.load()
        return {"ok": ok}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.post("/llm/unload")
def llm_unload():
    """Unload LLM from GPU memory (called when leaving Chat screen)."""
    try:
        from llm_local import local_llm
        local_llm.unload()
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "error": str(e)}


class LLMDownloadRequest(BaseModel):
    pass


@app.post("/llm/download")
def llm_download():
    """Download the Qwen3-1.7B GGUF model."""
    from llm_local import download_model, local_llm
    ok = download_model()
    if ok:
        # Auto-load after download
        import threading
        threading.Thread(target=local_llm.load, daemon=True).start()
    return {"ok": ok}


class ChatRequest(BaseModel):
    message: str
    history: list = []
    system_prompt: str | None = None
    enable_thinking: bool = False
    stream: bool = True
    model: str = "local"  # "local" or a Groq model ID


@app.get("/chat/models")
def chat_models():
    """List available chat models."""
    from llm_groq import GROQ_MODELS, groq_available
    from llm_local import local_llm

    models = []
    # Local model (free, offline)
    models.append({
        "id": "local",
        "label": "Qwen3 1.7B",
        "description": "Local · Free · Offline",
        "available": local_llm.available,
        "loaded": local_llm.loaded,
        "supports_thinking": True,
        "cloud": False,
    })
    # Groq cloud models
    has_key = groq_available()
    for model_id, info in GROQ_MODELS.items():
        models.append({
            "id": model_id,
            "label": info["label"],
            "description": info["description"],
            "available": has_key,
            "loaded": True,  # cloud models are always "loaded"
            "supports_thinking": info["supports_thinking"],
            "cloud": True,
        })
    return {"models": models, "groq_available": has_key}


@app.post("/chat")
async def chat_endpoint(req: ChatRequest):
    """Chat with local or cloud LLM. Supports streaming via SSE."""

    # Route to Groq cloud if not local
    if req.model != "local":
        return await _chat_groq(req)

    # Local LLM
    from llm_local import local_llm

    if not local_llm.loaded:
        if not local_llm.load():
            return {"error": "Local LLM not available. Download the model first."}

    if req.stream:
        def generate():
            try:
                for token in local_llm.chat_stream(
                    user_message=req.message,
                    system_prompt=req.system_prompt,
                    history=req.history,
                    enable_thinking=req.enable_thinking,
                ):
                    yield f"data: {json.dumps({'token': token})}\n\n"
                yield "data: [DONE]\n\n"
            except Exception as e:
                logger.exception("Chat stream error: %s", e)
                yield f"data: {json.dumps({'error': str(e)})}\n\n"

        return StreamingResponse(generate(), media_type="text/event-stream")
    else:
        try:
            response = local_llm.chat(
                user_message=req.message,
                system_prompt=req.system_prompt,
                history=req.history,
                enable_thinking=req.enable_thinking,
            )
            return {"response": response}
        except Exception as e:
            return {"error": str(e)}


async def _chat_groq(req: ChatRequest):
    """Handle chat via Groq cloud API."""
    from llm_groq import groq_chat_stream, groq_available

    if not groq_available():
        return {"error": "GROQ_API_KEY not set. Add it to .env file."}

    if req.stream:
        def generate():
            try:
                for token in groq_chat_stream(
                    user_message=req.message,
                    model=req.model,
                    system_prompt=req.system_prompt,
                    history=req.history,
                    enable_thinking=req.enable_thinking,
                ):
                    yield f"data: {json.dumps({'token': token})}\n\n"
                yield "data: [DONE]\n\n"
            except Exception as e:
                logger.exception("Groq chat error: %s", e)
                yield f"data: {json.dumps({'error': str(e)})}\n\n"

        return StreamingResponse(generate(), media_type="text/event-stream")
    else:
        # Non-streaming not implemented for Groq (not needed)
        return {"error": "Streaming required for cloud models"}


# ── Voice Chat ──

_voice_chat = None  # VoiceChat instance (singleton)


@app.get("/voice-chat/status")
def voice_chat_status():
    """Voice chat status."""
    from tts import is_available as tts_ok, pocket_available, chatterbox_available, \
        get_backend_from_settings
    return {
        "running": _voice_chat is not None and _voice_chat.running,
        "tts_available": tts_ok(),
        "tts_backend": get_backend_from_settings(),
        "pocket_available": pocket_available(),
        "chatterbox_available": chatterbox_available(),
    }


@app.get("/tts/status")
def tts_status():
    """TTS backends status and GPU info."""
    from tts import pocket_available, chatterbox_available, get_backend_from_settings
    result = {
        "active_backend": get_backend_from_settings(),
        "pocket": {"available": pocket_available()},
        "chatterbox": {"installed": False, "available": False, "loaded": False, "gpu": None},
    }
    try:
        from tts_chatterbox import chatterbox_tts
        result["chatterbox"] = chatterbox_tts.status()
    except ImportError:
        pass
    return result


@app.get("/tts/memory")
def tts_memory():
    """Proxy to Chatterbox worker /memory endpoint for VRAM/RAM stats."""
    import urllib.request
    try:
        req = urllib.request.Request("http://127.0.0.1:8180/memory")
        with urllib.request.urlopen(req, timeout=3) as resp:
            return json.loads(resp.read())
    except Exception as e:
        return {"error": str(e), "gpu": None, "ram": None}


@app.post("/tts/install-chatterbox")
def install_chatterbox():
    """Install Chatterbox TTS in a separate Python 3.11 venv via uv."""
    import subprocess as sp
    import shutil
    sidecar_dir = os.path.dirname(os.path.abspath(__file__))
    cbx_venv = os.path.join(sidecar_dir, "venv-chatterbox")
    cbx_python = os.path.join(cbx_venv, "bin", "python")

    # Already installed?
    if os.path.isfile(cbx_python):
        try:
            r = sp.run([cbx_python, "-c", "import chatterbox; print('ok')"],
                       capture_output=True, text=True, timeout=10)
            if r.returncode == 0 and "ok" in r.stdout:
                return {"ok": True, "output": "chatterbox-tts already installed"}
        except Exception:
            pass

    # Find uv
    uv = shutil.which("uv")
    if not uv:
        for p in [os.path.expanduser("~/.local/bin/uv"),
                   os.path.expanduser("~/.cargo/bin/uv")]:
            if os.path.isfile(p):
                uv = p
                break
    if not uv:
        return {"ok": False, "error": "uv not found. Install: curl -LsSf https://astral.sh/uv/install.sh | sh"}

    output_lines = []

    def run(cmd, timeout=300):
        r = sp.run(cmd, capture_output=True, text=True, timeout=timeout)
        output_lines.append(f"$ {' '.join(cmd)}")
        if r.stdout.strip():
            output_lines.append(r.stdout.strip()[-200:])
        if r.stderr.strip():
            output_lines.append(r.stderr.strip()[-200:])
        return r.returncode == 0

    try:
        # Create venv with Python 3.11
        if not os.path.isfile(cbx_python):
            if not run([uv, "venv", cbx_venv, "--python", "3.11"]):
                return {"ok": False, "error": "Failed to create Python 3.11 venv",
                        "output": "\n".join(output_lines)}

        # Detect GPU for PyTorch variant
        from tts_chatterbox import detect_gpu
        gpu = detect_gpu()

        if gpu["backend"] == "cuda":
            run([uv, "pip", "install", "--python", cbx_python,
                 "torch", "torchaudio",
                 "--index-url", "https://download.pytorch.org/whl/cu124"], timeout=600)
        elif gpu["backend"] == "rocm":
            run([uv, "pip", "install", "--python", cbx_python,
                 "torch", "torchaudio",
                 "--index-url", "https://download.pytorch.org/whl/rocm6.2"], timeout=600)
        elif gpu["backend"] == "mps":
            run([uv, "pip", "install", "--python", cbx_python,
                 "torch", "torchaudio"], timeout=600)
        else:
            return {"ok": False, "error": "No GPU detected",
                    "output": "\n".join(output_lines)}

        # Install chatterbox-tts + server deps
        run([uv, "pip", "install", "--python", cbx_python,
             "chatterbox-tts", "fastapi", "uvicorn[standard]", "setuptools<81"], timeout=600)

        # Verify
        r = sp.run([cbx_python, "-c", "import chatterbox; print('ok')"],
                   capture_output=True, text=True, timeout=10)
        ok = r.returncode == 0 and "ok" in r.stdout
        output_lines.append("chatterbox-tts installed OK" if ok else "verification failed")
        # Invalidate installed cache so status reflects the change
        if ok:
            try:
                from tts_chatterbox import chatterbox_tts
                chatterbox_tts.invalidate_cache()
            except Exception:
                pass
        return {"ok": ok, "output": "\n".join(output_lines)[-500:]}

    except Exception as e:
        return {"ok": False, "error": str(e),
                "output": "\n".join(output_lines)[-500:]}


@app.post("/tts/load-chatterbox")
def load_chatterbox():
    """Start Chatterbox worker and load model into GPU memory."""
    try:
        from tts_chatterbox import chatterbox_tts
        if not chatterbox_tts.available:
            return {"ok": False, "error": "Chatterbox not available (no GPU or not installed)"}
        ok = chatterbox_tts.load()
        return {"ok": ok, "status": chatterbox_tts.status()}
    except Exception as e:
        return {"ok": False, "error": str(e)}


@app.post("/tts/unload-chatterbox")
def unload_chatterbox():
    """Unload Chatterbox model and stop worker — frees VRAM + RAM."""
    try:
        from tts_chatterbox import chatterbox_tts
        chatterbox_tts.unload()
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "error": str(e)}


class TtsTestRequest(BaseModel):
    text: str = "Hello, this is a test of the text to speech system."
    language_id: str = "en"


@app.post("/tts/test")
def tts_test(req: TtsTestRequest):
    """Test TTS — generate and play a short phrase."""
    from tts import speak, get_backend_from_settings
    import threading

    backend = get_backend_from_settings()

    def _play():
        speak(req.text, language_id=req.language_id)

    threading.Thread(target=_play, daemon=True, name="tts-test").start()
    return {"ok": True, "backend": backend, "text": req.text, "language_id": req.language_id}


@app.websocket("/voice-chat")
async def voice_chat_ws(ws: WebSocket):
    """WebSocket for voice chat — full duplex voice conversation.

    Client sends: {"action": "start"} or {"action": "stop"}
    Server sends: {"type": "state", "state": "listening|processing|speaking|stopped"}
                  {"type": "user_text", "text": "..."}
                  {"type": "assistant_text", "text": "...", "done": bool}
                  {"type": "error", "message": "..."}
    """
    global _voice_chat
    await ws.accept()
    logger.info("Voice chat WebSocket connected")

    event_queue = asyncio.Queue()

    def _on_event(event: dict):
        """Thread-safe callback — push event to async queue."""
        try:
            event_queue.put_nowait(event)
        except Exception:
            pass

    async def _sender():
        """Forward events from queue to WebSocket."""
        try:
            while True:
                event = await event_queue.get()
                await ws.send_json(event)
        except Exception:
            pass

    sender_task = asyncio.create_task(_sender())

    try:
        while True:
            data = await ws.receive_json()
            action = data.get("action", "")

            if action == "start":
                if _voice_chat and _voice_chat.running:
                    _voice_chat.stop()
                from voice_chat import VoiceChat
                model = data.get("model", "local")
                language = data.get("language", "en")
                _voice_chat = VoiceChat(on_event=_on_event, model=model, language=language)
                _voice_chat.start()
                logger.info("Voice chat started via WebSocket (model=%s, lang=%s)", model, language)

            elif action == "stop":
                if _voice_chat and _voice_chat.running:
                    _voice_chat.stop()
                    _voice_chat = None
                    logger.info("Voice chat stopped via WebSocket")

    except WebSocketDisconnect:
        pass
    except Exception as e:
        logger.warning("Voice chat WS error: %s", e)
    finally:
        sender_task.cancel()
        if _voice_chat and _voice_chat.running:
            _voice_chat.stop()
            _voice_chat = None
        logger.info("Voice chat WebSocket disconnected")


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
