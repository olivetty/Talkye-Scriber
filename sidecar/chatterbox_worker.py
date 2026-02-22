"""Chatterbox TTS Worker — runs in venv-chatterbox (Python 3.11).

Minimal FastAPI server on port 8180 that manages the Chatterbox
Multilingual model. Called by the main sidecar via HTTP.

Usage (from venv-chatterbox):
    python chatterbox_worker.py
    # or: uvicorn chatterbox_worker:app --host 127.0.0.1 --port 8180
"""

import io
import json
import logging
import os
import tempfile
import threading
import time

import torch
import torchaudio as ta
from fastapi import FastAPI
from pydantic import BaseModel

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

app = FastAPI(title="Chatterbox Worker", version="0.1.0")

# ── Model state ──
_model = None
_model_lock = threading.Lock()
_loading = False
_warmed_up = False


def _gpu_info() -> dict:
    """Get GPU info from torch."""
    if torch.cuda.is_available():
        name = torch.cuda.get_device_name(0)
        vram = torch.cuda.get_device_properties(0).total_memory
        return {"backend": "cuda", "device": "cuda", "name": name,
                "vram_gb": round(vram / 1024**3, 1)}
    if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        return {"backend": "mps", "device": "mps", "name": "Apple Silicon (MPS)",
                "vram_gb": 0}
    return {"backend": "cpu", "device": "cpu", "name": "CPU only", "vram_gb": 0}


@app.get("/health")
def health():
    return {"status": "ok", "model_loaded": _model is not None}


@app.get("/status")
def status():
    return {
        "loaded": _model is not None,
        "loading": _loading,
        "warmed_up": _warmed_up,
        "gpu": _gpu_info(),
        "sample_rate": _model.sr if _model else None,
    }


@app.post("/load")
def load_model():
    """Load Chatterbox Multilingual into GPU memory."""
    global _model, _loading
    if _model is not None:
        return {"ok": True, "message": "Already loaded", "sr": _model.sr}
    if _loading:
        return {"ok": False, "message": "Already loading"}

    with _model_lock:
        if _model is not None:
            return {"ok": True, "message": "Already loaded", "sr": _model.sr}
        _loading = True
        try:
            from chatterbox.mtl_tts import ChatterboxMultilingualTTS

            gpu = _gpu_info()
            device = gpu["device"]
            t0 = time.perf_counter()
            logger.info("Loading Chatterbox Multilingual on %s (%s)...",
                        device, gpu["name"])

            _model = ChatterboxMultilingualTTS.from_pretrained(device=device)

            elapsed = time.perf_counter() - t0
            logger.info("Chatterbox loaded in %.1fs (sr=%d)", elapsed, _model.sr)
            return {"ok": True, "sr": _model.sr, "elapsed": round(elapsed, 1)}
        except Exception as e:
            logger.exception("Failed to load Chatterbox: %s", e)
            _model = None
            return {"ok": False, "error": str(e)}
        finally:
            _loading = False


@app.post("/unload")
def unload_model():
    """Free model from GPU memory."""
    global _model
    with _model_lock:
        if _model is not None:
            del _model
            _model = None
            if torch.cuda.is_available():
                torch.cuda.empty_cache()
            logger.info("Chatterbox unloaded")
            return {"ok": True}
    return {"ok": True, "message": "Not loaded"}


class GenerateRequest(BaseModel):
    text: str
    language_id: str = "en"
    voice_ref: str | None = None
    exaggeration: float = 0.5
    cfg_weight: float = 0.5
    output_path: str | None = None


@app.post("/warmup")
def warmup():
    """Run a short generation to warm up CUDA kernels. Discards output."""
    global _warmed_up
    if _model is None:
        return {"ok": False, "error": "Model not loaded"}
    if _warmed_up:
        return {"ok": True, "message": "Already warmed up"}
    try:
        t0 = time.perf_counter()
        logger.info("Warming up model...")
        wav = _model.generate("Ready.", language_id="en",
                              exaggeration=0.3, cfg_weight=0.5)
        elapsed = time.perf_counter() - t0
        _warmed_up = True
        logger.info("Warm-up done in %.1fs", elapsed)
        return {"ok": True, "elapsed": round(elapsed, 2)}
    except Exception as e:
        logger.exception("Warm-up failed: %s", e)
        # Still mark as warmed up so we don't block forever
        _warmed_up = True
        return {"ok": False, "error": str(e)}


@app.post("/generate")
def generate(req: GenerateRequest):
    """Generate speech from text. Returns WAV file path."""
    if _model is None:
        return {"ok": False, "error": "Model not loaded"}
    if not req.text.strip():
        return {"ok": False, "error": "Empty text"}

    try:
        t0 = time.perf_counter()

        kwargs = {
            "language_id": req.language_id,
            "exaggeration": req.exaggeration,
            "cfg_weight": req.cfg_weight,
        }
        if req.voice_ref and os.path.isfile(req.voice_ref):
            kwargs["audio_prompt_path"] = req.voice_ref

        wav_tensor = _model.generate(req.text, **kwargs)
        elapsed = time.perf_counter() - t0

        sr = _model.sr
        duration = wav_tensor.shape[-1] / sr

        # Save to file
        out = req.output_path
        if not out:
            fd, out = tempfile.mkstemp(suffix=".wav", prefix="cbx_")
            os.close(fd)

        ta.save(out, wav_tensor.cpu(), sr, format="wav")

        logger.info("Generated: %.1fs audio in %.1fs (lang=%s)",
                     duration, elapsed, req.language_id)
        return {
            "ok": True,
            "path": out,
            "sample_rate": sr,
            "duration": round(duration, 2),
            "elapsed": round(elapsed, 2),
        }
    except Exception as e:
        logger.exception("Generate failed: %s", e)
        return {"ok": False, "error": str(e)}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8180, log_level="info")
