"""Talkye Sidecar — Chatterbox Multilingual TTS.

GPU-accelerated TTS with voice cloning (23 languages).
Falls back gracefully if no GPU or chatterbox-tts not installed.

Usage:
    from tts_chatterbox import chatterbox_tts
    if chatterbox_tts.available:
        chatterbox_tts.load()
        chatterbox_tts.speak("Bonjour!", language_id="fr", voice_ref="ref.wav")
"""

import io
import json
import logging
import os
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from platform_utils import user_env

logger = logging.getLogger(__name__)

_SETTINGS_PATH = os.path.join(
    os.getenv("HOME", "/tmp"), ".config", "talkye", "settings.json"
)


def detect_gpu() -> dict:
    """Detect available GPU acceleration.

    Returns dict with:
        backend: "cuda" | "rocm" | "mps" | "cpu"
        device: torch device string
        name: human-readable GPU name
        vram_gb: approximate VRAM in GB (0 for CPU/MPS)
    """
    info = {"backend": "cpu", "device": "cpu", "name": "CPU only", "vram_gb": 0}

    try:
        import torch
    except ImportError:
        return info

    # NVIDIA CUDA
    if torch.cuda.is_available():
        info["backend"] = "cuda"
        info["device"] = "cuda"
        try:
            info["name"] = torch.cuda.get_device_name(0)
            vram = torch.cuda.get_device_properties(0).total_mem
            info["vram_gb"] = round(vram / 1024**3, 1)
        except Exception:
            info["name"] = "NVIDIA GPU"
        return info

    # AMD ROCm (Linux only, shows as cuda in PyTorch ROCm builds)
    # ROCm builds report torch.cuda.is_available() = True, so caught above.
    # If hip is available but cuda isn't, it's a partial ROCm setup.
    if hasattr(torch, "hip") or os.path.exists("/opt/rocm"):
        try:
            if torch.cuda.is_available():
                info["backend"] = "rocm"
                info["device"] = "cuda"  # ROCm uses cuda device in PyTorch
                info["name"] = "AMD GPU (ROCm)"
                return info
        except Exception:
            pass

    # Apple MPS
    if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        info["backend"] = "mps"
        info["device"] = "mps"
        info["name"] = "Apple Silicon (MPS)"
        return info

    return info


def _get_active_voice() -> str | None:
    """Read activeVoicePath from Flutter settings (WAV file for cloning)."""
    try:
        if os.path.isfile(_SETTINGS_PATH):
            with open(_SETTINGS_PATH) as f:
                cfg = json.load(f)
            # For Chatterbox, we need a .wav reference file.
            # The activeVoicePath might be a .safetensors (pocket-tts format).
            # We look for a .wav sibling or the original recording.
            path = cfg.get("activeVoicePath", "")
            if not path:
                return None
            # If it's already a .wav, use it directly
            if path.endswith(".wav") and os.path.isfile(path):
                return path
            # If it's a .safetensors, look for .wav in same directory
            if path.endswith(".safetensors"):
                voice_dir = os.path.dirname(path)
                for f in os.listdir(voice_dir) if os.path.isdir(voice_dir) else []:
                    if f.endswith(".wav"):
                        wav_path = os.path.join(voice_dir, f)
                        if os.path.isfile(wav_path):
                            return wav_path
    except Exception:
        pass
    return None


class ChatterboxTTS:
    """Singleton wrapper for Chatterbox Multilingual TTS."""

    def __init__(self):
        self._model = None
        self._loading = False
        self._gpu_info: dict | None = None
        self._lock = threading.Lock()

    @property
    def gpu_info(self) -> dict:
        """Cached GPU detection result."""
        if self._gpu_info is None:
            self._gpu_info = detect_gpu()
        return self._gpu_info

    @property
    def has_gpu(self) -> bool:
        """True if a compatible GPU is available."""
        return self.gpu_info["backend"] != "cpu"

    @property
    def installed(self) -> bool:
        """True if chatterbox-tts package is installed."""
        try:
            import chatterbox  # noqa: F401
            return True
        except ImportError:
            return False

    @property
    def available(self) -> bool:
        """True if Chatterbox can be used (installed + GPU)."""
        return self.installed and self.has_gpu

    @property
    def loaded(self) -> bool:
        return self._model is not None

    def load(self) -> bool:
        """Load the Chatterbox Multilingual model. Returns True on success.

        Model downloads automatically on first use (~1GB).
        """
        if self._model is not None:
            return True
        if not self.available:
            logger.warning("Chatterbox not available (installed=%s, gpu=%s)",
                           self.installed, self.gpu_info["backend"])
            return False
        if self._loading:
            return False

        with self._lock:
            if self._model is not None:
                return True
            self._loading = True
            try:
                from chatterbox.mtl_tts import ChatterboxMultilingualTTS

                device = self.gpu_info["device"]
                t0 = time.perf_counter()
                logger.info("Loading Chatterbox Multilingual on %s (%s)...",
                            device, self.gpu_info["name"])

                self._model = ChatterboxMultilingualTTS.from_pretrained(device=device)

                elapsed = time.perf_counter() - t0
                logger.info("Chatterbox loaded in %.1fs (sr=%d)", elapsed, self._model.sr)
                return True
            except Exception as e:
                logger.exception("Failed to load Chatterbox: %s", e)
                self._model = None
                return False
            finally:
                self._loading = False

    def unload(self):
        """Free model from GPU memory."""
        with self._lock:
            if self._model is not None:
                del self._model
                self._model = None
                # Free GPU cache
                try:
                    import torch
                    if torch.cuda.is_available():
                        torch.cuda.empty_cache()
                except Exception:
                    pass
                logger.info("Chatterbox unloaded")

    def generate(
        self,
        text: str,
        language_id: str = "en",
        voice_ref: str | None = None,
        exaggeration: float = 0.5,
        cfg_weight: float = 0.5,
    ) -> tuple[bytes, int] | None:
        """Generate speech audio from text.

        Args:
            text: Text to speak.
            language_id: ISO 639-1 language code (en, fr, de, etc.)
            voice_ref: Path to .wav reference for voice cloning. None = default.
            exaggeration: Emotion intensity 0.0-1.0 (0.5 = natural).
            cfg_weight: Voice similarity 0.0-1.0 (0.5 = default, 0 = neutral accent).

        Returns:
            (wav_bytes, sample_rate) or None on failure.
        """
        if not self.loaded and not self.load():
            return None
        if not text.strip():
            return None

        # Use active voice from settings if no override
        if voice_ref is None:
            voice_ref = _get_active_voice()

        try:
            import torch
            import torchaudio as ta

            t0 = time.perf_counter()

            kwargs = {
                "language_id": language_id,
                "exaggeration": exaggeration,
                "cfg_weight": cfg_weight,
            }
            if voice_ref and os.path.isfile(voice_ref):
                kwargs["audio_prompt_path"] = voice_ref

            wav_tensor = self._model.generate(text, **kwargs)
            elapsed = time.perf_counter() - t0

            sr = self._model.sr
            duration = wav_tensor.shape[-1] / sr
            logger.info("Chatterbox generate: %.1fs for %.1fs audio (lang=%s)",
                        elapsed, duration, language_id)

            # Convert tensor to WAV bytes
            buf = io.BytesIO()
            ta.save(buf, wav_tensor.cpu(), sr, format="wav")
            return buf.getvalue(), sr

        except Exception as e:
            logger.exception("Chatterbox generate failed: %s", e)
            return None

    def generate_to_file(
        self,
        text: str,
        output_path: str | None = None,
        language_id: str = "en",
        voice_ref: str | None = None,
        exaggeration: float = 0.5,
        cfg_weight: float = 0.5,
    ) -> str | None:
        """Generate speech and save to WAV file.

        Returns output file path or None on failure.
        """
        result = self.generate(
            text, language_id=language_id, voice_ref=voice_ref,
            exaggeration=exaggeration, cfg_weight=cfg_weight,
        )
        if result is None:
            return None

        wav_bytes, sr = result

        if output_path is None:
            fd, output_path = tempfile.mkstemp(suffix=".wav", prefix="cbx_")
            os.close(fd)

        with open(output_path, "wb") as f:
            f.write(wav_bytes)

        return output_path

    def speak(
        self,
        text: str,
        language_id: str = "en",
        voice_ref: str | None = None,
        exaggeration: float = 0.5,
        cfg_weight: float = 0.5,
    ) -> bool:
        """Generate and play speech. Blocking. Returns True on success."""
        path = self.generate_to_file(
            text, language_id=language_id, voice_ref=voice_ref,
            exaggeration=exaggeration, cfg_weight=cfg_weight,
        )
        if not path:
            return False

        try:
            env = user_env()
            subprocess.run(
                ["paplay", path],
                timeout=30, env=env,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            return True
        except Exception as e:
            logger.error("Chatterbox playback failed: %s", e)
            return False
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass

    def status(self) -> dict:
        """Return status info for API."""
        return {
            "installed": self.installed,
            "loaded": self.loaded,
            "gpu": self.gpu_info,
            "available": self.available,
        }


# ── Singleton ──
chatterbox_tts = ChatterboxTTS()
