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


# ── Streaming TTS ──────────────────────────────────────────────────────

class StreamGenerateRequest(BaseModel):
    text: str
    language_id: str = "en"
    voice_ref: str | None = None
    exaggeration: float = 0.5
    cfg_weight: float = 0.5
    temperature: float = 0.8
    chunk_size: int = 25
    context_window: int = 50


def _inference_stream(
    model,
    text_tokens: torch.Tensor,
    t3_cond,
    max_new_tokens: int = 1000,
    temperature: float = 0.8,
    cfg_weight: float = 0.5,
    chunk_size: int = 25,
    repetition_penalty: float = 2.0,
    min_p: float = 0.05,
    top_p: float = 1.0,
):
    """Streaming T3 inference — yields chunks of speech tokens.

    Ported from chatterbox-streaming, adapted for Multilingual model
    (adds AlignmentStreamAnalyzer + MinPLogitsWarper).
    """
    import torch.nn.functional as F
    from transformers.generation.logits_process import (
        TopPLogitsWarper, MinPLogitsWarper, RepetitionPenaltyLogitsProcessor,
    )
    from chatterbox.models.t3.inference.alignment_stream_analyzer import (
        AlignmentStreamAnalyzer,
    )
    from chatterbox.models.t3.inference.t3_hf_backend import T3HuggingfaceBackend

    t3 = model.t3
    device = t3.device

    text_tokens = torch.atleast_2d(text_tokens).to(dtype=torch.long, device=device)
    initial_speech = t3.hp.start_speech_token * torch.ones_like(text_tokens[:, :1])

    embeds, len_cond = t3.prepare_input_embeds(
        t3_cond=t3_cond,
        text_tokens=text_tokens,
        speech_tokens=initial_speech,
        cfg_weight=cfg_weight,
    )

    # Build patched model with AlignmentStreamAnalyzer for multilingual
    alignment_analyzer = None
    if t3.hp.is_multilingual:
        alignment_analyzer = AlignmentStreamAnalyzer(
            t3.tfmr, None,
            text_tokens_slice=(len_cond, len_cond + text_tokens.size(-1)),
            alignment_layer_idx=9,
            eos_idx=t3.hp.stop_speech_token,
        )

    patched_model = T3HuggingfaceBackend(
        config=t3.cfg,
        llama=t3.tfmr,
        speech_enc=t3.speech_emb,
        speech_head=t3.speech_head,
        alignment_stream_analyzer=alignment_analyzer,
    )

    # BOS token
    bos_token = torch.tensor(
        [[t3.hp.start_speech_token]], dtype=torch.long, device=device
    )
    bos_embed = t3.speech_emb(bos_token) + t3.speech_pos_emb.get_fixed_embedding(0)
    bos_embed = torch.cat([bos_embed, bos_embed])  # CFG batch=2

    inputs_embeds = torch.cat([embeds, bos_embed], dim=1)

    generated_ids = bos_token.clone()
    chunk_buffer = []

    # Logits processors (matching multilingual inference)
    top_p_warper = TopPLogitsWarper(top_p=top_p)
    min_p_warper = MinPLogitsWarper(min_p=min_p)
    rep_penalty = RepetitionPenaltyLogitsProcessor(penalty=float(repetition_penalty))

    # Initial forward pass
    output = patched_model(
        inputs_embeds=inputs_embeds,
        past_key_values=None,
        use_cache=True,
        output_attentions=True,
        output_hidden_states=True,
        return_dict=True,
    )
    past = output.past_key_values

    for i in range(max_new_tokens):
        logits_step = output.logits[:, -1, :]

        # CFG
        cond = logits_step[0:1, :]
        uncond = logits_step[1:2, :]
        logits = cond + cfg_weight * (cond - uncond)

        # AlignmentStreamAnalyzer integrity check (multilingual)
        if alignment_analyzer is not None:
            if logits.dim() == 1:
                logits = logits.unsqueeze(0)
            last_tok = generated_ids[0, -1].item() if generated_ids.size(1) > 0 else None
            logits = alignment_analyzer.step(logits, next_token=last_tok)

        ids_for_proc = generated_ids[:1, ...]

        # Repetition penalty
        logits = rep_penalty(ids_for_proc, logits)

        # Temperature
        if temperature != 1.0:
            logits = logits / temperature

        # MinP + TopP
        logits = min_p_warper(ids_for_proc, logits)
        logits = top_p_warper(ids_for_proc, logits)

        probs = torch.softmax(logits, dim=-1)
        next_token = torch.multinomial(probs, num_samples=1)

        chunk_buffer.append(next_token)
        generated_ids = torch.cat([generated_ids, next_token], dim=1)

        # EOS
        if next_token.view(-1) == t3.hp.stop_speech_token:
            if chunk_buffer:
                yield torch.cat(chunk_buffer, dim=1)
            break

        # Yield chunk when buffer full
        if len(chunk_buffer) >= chunk_size:
            yield torch.cat(chunk_buffer, dim=1)
            chunk_buffer = []

        # Next token embedding
        next_embed = t3.speech_emb(next_token)
        next_embed = next_embed + t3.speech_pos_emb.get_fixed_embedding(i + 1)
        next_embed = torch.cat([next_embed, next_embed])  # CFG

        output = patched_model(
            inputs_embeds=next_embed,
            past_key_values=past,
            output_attentions=True,
            output_hidden_states=True,
            return_dict=True,
        )
        past = output.past_key_values


def _process_token_chunk(
    model,
    new_tokens: torch.Tensor,
    all_tokens_so_far: torch.Tensor | None,
    context_window: int = 50,
    fade_duration: float = 0.02,
):
    """Run S3Gen on a token chunk with context overlap. Returns (audio_np, duration)."""
    import numpy as np
    from chatterbox.models.s3tokenizer import drop_invalid_tokens

    device = model.device

    # Build tokens with context overlap for smooth boundaries
    if all_tokens_so_far is not None and len(all_tokens_so_far) > 0:
        ctx = (
            all_tokens_so_far[-context_window:]
            if len(all_tokens_so_far) > context_window
            else all_tokens_so_far
        )
        tokens = torch.cat([ctx, new_tokens], dim=-1)
        ctx_len = len(ctx)
    else:
        tokens = new_tokens
        ctx_len = 0

    clean = drop_invalid_tokens(tokens).to(device)
    if len(clean) == 0:
        return None, 0.0

    wav, _ = model.s3gen.inference(
        speech_tokens=clean,
        ref_dict=model.conds.gen,
    )
    wav = wav.squeeze(0).detach().cpu().numpy()

    # Crop context portion
    if ctx_len > 0:
        samples_per_token = len(wav) / len(clean)
        skip = int(ctx_len * samples_per_token)
        chunk = wav[skip:]
    else:
        chunk = wav

    if len(chunk) == 0:
        return None, 0.0

    # Fade-in for smooth boundaries
    fade_samples = min(int(fade_duration * model.sr), len(chunk))
    if fade_samples > 0:
        fade_in = np.linspace(0.0, 1.0, fade_samples, dtype=chunk.dtype)
        chunk[:fade_samples] *= fade_in

    # Watermark
    chunk = model.watermarker.apply_watermark(chunk, sample_rate=model.sr)
    duration = len(chunk) / model.sr
    return chunk, duration


@app.post("/generate-stream")
def generate_stream(req: StreamGenerateRequest):
    """Streaming TTS — yields PCM audio chunks as SSE events."""
    import base64
    import numpy as np
    from starlette.responses import StreamingResponse
    from chatterbox.mtl_tts import punc_norm

    if _model is None:
        return {"ok": False, "error": "Model not loaded"}
    if not req.text.strip():
        return {"ok": False, "error": "Empty text"}

    def _stream():
        t0 = time.perf_counter()
        chunk_count = 0
        total_audio = 0.0

        # Prepare conditionals
        if req.voice_ref and os.path.isfile(req.voice_ref):
            _model.prepare_conditionals(req.voice_ref, exaggeration=req.exaggeration)
        elif _model.conds is None:
            yield f"data: {json.dumps({'error': 'No voice reference'})}\n\n"
            return

        # Update exaggeration
        if float(req.exaggeration) != float(_model.conds.t3.emotion_adv[0, 0, 0].item()):
            from chatterbox.models.t3.modules.cond_enc import T3Cond
            _cond = _model.conds.t3
            _model.conds.t3 = T3Cond(
                speaker_emb=_cond.speaker_emb,
                cond_prompt_speech_tokens=_cond.cond_prompt_speech_tokens,
                emotion_adv=req.exaggeration * torch.ones(1, 1, 1),
            ).to(device=_model.device)

        # Tokenize
        text = punc_norm(req.text)
        text_tokens = _model.tokenizer.text_to_tokens(
            text, language_id=req.language_id.lower()
        ).to(_model.device)
        text_tokens = torch.cat([text_tokens, text_tokens], dim=0)  # CFG

        import torch.nn.functional as F
        sot = _model.t3.hp.start_text_token
        eot = _model.t3.hp.stop_text_token
        text_tokens = F.pad(text_tokens, (1, 0), value=sot)
        text_tokens = F.pad(text_tokens, (0, 1), value=eot)

        all_tokens = None

        with torch.inference_mode():
            for token_chunk in _inference_stream(
                _model,
                text_tokens=text_tokens,
                t3_cond=_model.conds.t3,
                max_new_tokens=1000,
                temperature=req.temperature,
                cfg_weight=req.cfg_weight,
                chunk_size=req.chunk_size,
            ):
                # Extract conditional batch (index 0)
                token_chunk = token_chunk[0]

                audio, duration = _process_token_chunk(
                    _model, token_chunk, all_tokens, req.context_window,
                )

                if audio is not None and duration > 0:
                    chunk_count += 1
                    total_audio += duration
                    latency = time.perf_counter() - t0 if chunk_count == 1 else None

                    # Encode PCM float32 as base64
                    pcm_b64 = base64.b64encode(
                        audio.astype(np.float32).tobytes()
                    ).decode("ascii")

                    evt = {
                        "chunk": pcm_b64,
                        "sample_rate": _model.sr,
                        "duration": round(duration, 3),
                        "chunk_index": chunk_count - 1,
                    }
                    if latency is not None:
                        evt["first_chunk_latency"] = round(latency, 3)
                        logger.info("Stream: first chunk in %.3fs", latency)

                    yield f"data: {json.dumps(evt)}\n\n"

                # Accumulate tokens
                if all_tokens is None:
                    all_tokens = token_chunk
                else:
                    all_tokens = torch.cat([all_tokens, token_chunk], dim=-1)

        elapsed = time.perf_counter() - t0
        rtf = elapsed / total_audio if total_audio > 0 else 0
        logger.info(
            "Stream done: %d chunks, %.1fs audio in %.1fs (RTF=%.2f, lang=%s)",
            chunk_count, total_audio, elapsed, rtf, req.language_id,
        )
        yield f"data: {json.dumps({'done': True, 'chunks': chunk_count, 'total_audio': round(total_audio, 2), 'elapsed': round(elapsed, 2), 'rtf': round(rtf, 3)})}\n\n"

    return StreamingResponse(_stream(), media_type="text/event-stream")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8180, log_level="info")
