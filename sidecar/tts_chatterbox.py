"""Talkye Sidecar — Chatterbox Multilingual TTS.

GPU-accelerated TTS with voice cloning (23 languages).
Runs chatterbox_worker.py in a separate Python 3.11 venv
(chatterbox-tts requires Python 3.11).

Architecture:
    tts_chatterbox.py (main venv, Python 3.12)
        → HTTP → chatterbox_worker.py (venv-chatterbox, Python 3.11, port 8180)

Usage:
    from tts_chatterbox import chatterbox_tts
    if chatterbox_tts.can_install:
        chatterbox_tts.load()       # starts worker + loads model
        chatterbox_tts.speak("Bonjour!", language_id="fr")
"""

import json
import logging
import os
import subprocess
import tempfile
import threading
import time
import urllib.request
import urllib.error
from pathlib import Path

from platform_utils import user_env

logger = logging.getLogger(__name__)

_SIDECAR_DIR = Path(__file__).resolve().parent
_WORKER_SCRIPT = _SIDECAR_DIR / "chatterbox_worker.py"
_WORKER_PYTHON = _SIDECAR_DIR / "venv-chatterbox" / "bin" / "python"
_WORKER_URL = "http://127.0.0.1:8180"
_SETTINGS_PATH = os.path.join(
    os.getenv("HOME", "/tmp"), ".config", "talkye", "settings.json"
)


def detect_gpu() -> dict:
    """Detect available GPU acceleration.

    Works without PyTorch — uses system tools (nvidia-smi, rocm-smi).

    Returns dict with:
        backend: "cuda" | "rocm" | "mps" | "cpu"
        device: torch device string
        name: human-readable GPU name
        vram_gb: approximate VRAM in GB (0 for CPU/MPS)
    """
    info = {"backend": "cpu", "device": "cpu", "name": "CPU only", "vram_gb": 0}

    # NVIDIA: use nvidia-smi
    try:
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=name,memory.total",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0 and result.stdout.strip():
            parts = result.stdout.strip().split(",")
            info["backend"] = "cuda"
            info["device"] = "cuda"
            info["name"] = parts[0].strip() if parts else "NVIDIA GPU"
            if len(parts) > 1:
                try:
                    info["vram_gb"] = round(int(parts[1].strip()) / 1024, 1)
                except ValueError:
                    pass
            return info
    except FileNotFoundError:
        pass
    except Exception:
        pass

    # AMD ROCm (Linux)
    if os.path.exists("/opt/rocm"):
        try:
            result = subprocess.run(
                ["rocm-smi", "--showproductname"],
                capture_output=True, text=True, timeout=5,
            )
            if result.returncode == 0:
                info["backend"] = "rocm"
                info["device"] = "cuda"  # ROCm uses cuda device in PyTorch
                info["name"] = "AMD GPU (ROCm)"
                return info
        except (FileNotFoundError, Exception):
            info["backend"] = "rocm"
            info["device"] = "cuda"
            info["name"] = "AMD GPU (ROCm)"
            return info

    # Apple Silicon (macOS)
    import platform
    if platform.system() == "Darwin" and platform.machine() == "arm64":
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
            path = cfg.get("activeVoicePath", "")
            if not path:
                return None
            if path.endswith(".wav") and os.path.isfile(path):
                return path
            if path.endswith(".safetensors"):
                voice_dir = os.path.dirname(path)
                for fname in os.listdir(voice_dir) if os.path.isdir(voice_dir) else []:
                    if fname.endswith(".wav"):
                        wav_path = os.path.join(voice_dir, fname)
                        if os.path.isfile(wav_path):
                            return wav_path
    except Exception:
        pass
    return None


def _worker_request(method: str, path: str, data: dict | None = None,
                    timeout: float = 120) -> dict | None:
    """Make HTTP request to the chatterbox worker."""
    url = f"{_WORKER_URL}{path}"
    last_err = None
    # Retry up to 3 times for transient connection issues
    for attempt in range(3):
        try:
            if data is not None:
                body = json.dumps(data).encode()
                req = urllib.request.Request(url, data=body, method=method,
                                            headers={"Content-Type": "application/json"})
            else:
                req = urllib.request.Request(url, method=method)
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.URLError as e:
            last_err = e
            if attempt < 2:
                time.sleep(1)
        except (ConnectionError, BrokenPipeError, OSError) as e:
            last_err = e
            if attempt < 2:
                time.sleep(2)
        except Exception as e:
            logger.warning("Worker request %s %s failed: %s", method, path, e)
            return None
    if last_err:
        logger.warning("Worker request %s %s failed after retries: %s", method, path, last_err)
    return None


class ChatterboxTTS:
    """Singleton wrapper for Chatterbox Multilingual TTS.

    Manages a worker subprocess (chatterbox_worker.py) running in
    venv-chatterbox (Python 3.11) on port 8180.
    """

    def __init__(self):
        self._worker_proc: subprocess.Popen | None = None
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
        """True if venv-chatterbox exists with chatterbox-tts installed."""
        if not _WORKER_PYTHON.is_file():
            return False
        try:
            result = subprocess.run(
                [str(_WORKER_PYTHON), "-c", "import chatterbox; print('ok')"],
                capture_output=True, text=True, timeout=10,
            )
            return result.returncode == 0 and "ok" in result.stdout
        except Exception:
            return False

    @property
    def available(self) -> bool:
        """True if Chatterbox can be used (installed + GPU)."""
        return self.installed and self.has_gpu

    @property
    def can_install(self) -> bool:
        """True if GPU exists — user can install and use Chatterbox."""
        return self.has_gpu

    @property
    def worker_running(self) -> bool:
        """True if the worker subprocess is alive."""
        if self._worker_proc is None:
            return False
        return self._worker_proc.poll() is None

    @property
    def loaded(self) -> bool:
        """True if worker is running and model is loaded."""
        if not self.worker_running:
            return False
        resp = _worker_request("GET", "/status", timeout=3)
        return resp is not None and resp.get("loaded", False)

    def _start_worker(self) -> bool:
        """Start the chatterbox_worker.py subprocess."""
        if self.worker_running:
            return True
        if not _WORKER_PYTHON.is_file() or not _WORKER_SCRIPT.is_file():
            logger.error("Worker python or script not found")
            return False

        with self._lock:
            if self.worker_running:
                return True
            try:
                # Kill any stale process on port 8180
                try:
                    subprocess.run(["fuser", "-k", "8180/tcp"],
                                   capture_output=True, timeout=3)
                    time.sleep(0.5)
                except Exception:
                    pass

                logger.info("Starting Chatterbox worker (port 8180)...")
                self._worker_proc = subprocess.Popen(
                    [str(_WORKER_PYTHON), str(_WORKER_SCRIPT)],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    cwd=str(_SIDECAR_DIR),
                )
                # Wait for worker to be ready
                for _ in range(40):  # up to 20 seconds
                    time.sleep(0.5)
                    if self._worker_proc.poll() is not None:
                        stderr = self._worker_proc.stderr.read().decode() if self._worker_proc.stderr else ""
                        logger.error("Worker exited early: %s", stderr[-500:])
                        self._worker_proc = None
                        return False
                    resp = _worker_request("GET", "/health", timeout=2)
                    if resp and resp.get("status") == "ok":
                        logger.info("Chatterbox worker started (PID %d)",
                                    self._worker_proc.pid)
                        return True
                logger.error("Worker did not become ready in time")
                self._stop_worker()
                return False
            except Exception as e:
                logger.exception("Failed to start worker: %s", e)
                self._worker_proc = None
                return False

    def _stop_worker(self):
        """Stop the worker subprocess."""
        if self._worker_proc is not None:
            try:
                self._worker_proc.terminate()
                self._worker_proc.wait(timeout=5)
            except Exception:
                try:
                    self._worker_proc.kill()
                except Exception:
                    pass
            logger.info("Chatterbox worker stopped")
            self._worker_proc = None

    def load(self) -> bool:
        """Start worker and load model into GPU. Returns True on success."""
        if not self.available:
            logger.warning("Chatterbox not available (installed=%s, gpu=%s)",
                           self.installed, self.gpu_info["backend"])
            return False

        if not self._start_worker():
            return False

        # Small delay to let worker fully initialize
        time.sleep(1)

        # Ask worker to load model (may download ~1GB on first use)
        logger.info("Requesting model load...")
        resp = _worker_request("POST", "/load", data={}, timeout=300)
        if resp and resp.get("ok"):
            logger.info("Chatterbox model loaded (%.1fs)", resp.get("elapsed", 0))
            return True
        error = resp.get("error", "unknown") if resp else "worker unreachable"
        logger.error("Model load failed: %s", error)
        return False

    def unload(self):
        """Unload model and stop worker."""
        if self.worker_running:
            _worker_request("POST", "/unload", data={}, timeout=10)
        self._stop_worker()
        logger.info("Chatterbox unloaded")

    def generate(
        self,
        text: str,
        language_id: str = "en",
        voice_ref: str | None = None,
        exaggeration: float = 0.5,
        cfg_weight: float = 0.5,
    ) -> tuple[str, int] | None:
        """Generate speech audio from text.

        Returns (wav_path, sample_rate) or None on failure.
        """
        if not self.worker_running:
            if not self.load():
                return None
        if not text.strip():
            return None

        if voice_ref is None:
            voice_ref = _get_active_voice()

        resp = _worker_request("POST", "/generate", data={
            "text": text,
            "language_id": language_id,
            "voice_ref": voice_ref,
            "exaggeration": exaggeration,
            "cfg_weight": cfg_weight,
        }, timeout=120)

        if resp and resp.get("ok"):
            return resp["path"], resp.get("sample_rate", 22050)
        error = resp.get("error", "unknown") if resp else "worker unreachable"
        logger.error("Chatterbox generate failed: %s", error)
        return None

    def speak(
        self,
        text: str,
        language_id: str = "en",
        voice_ref: str | None = None,
        exaggeration: float = 0.5,
        cfg_weight: float = 0.5,
    ) -> bool:
        """Generate and play speech. Blocking. Returns True on success."""
        result = self.generate(
            text, language_id=language_id, voice_ref=voice_ref,
            exaggeration=exaggeration, cfg_weight=cfg_weight,
        )
        if not result:
            return False

        wav_path, _ = result
        try:
            env = user_env()
            subprocess.run(
                ["paplay", wav_path],
                timeout=30, env=env,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            return True
        except Exception as e:
            logger.error("Chatterbox playback failed: %s", e)
            return False
        finally:
            try:
                os.unlink(wav_path)
            except OSError:
                pass

    def status(self) -> dict:
        """Return status info for API."""
        worker_status = None
        if self.worker_running:
            worker_status = _worker_request("GET", "/status", timeout=3)
        return {
            "installed": self.installed,
            "loaded": worker_status.get("loaded", False) if worker_status else False,
            "gpu": self.gpu_info,
            "available": self.available,
            "can_install": self.can_install,
            "worker_running": self.worker_running,
        }


# ── Singleton ──
chatterbox_tts = ChatterboxTTS()
