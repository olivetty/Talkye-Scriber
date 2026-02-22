"""Talkye Sidecar — Local LLM via llama-cpp-python (Qwen3-1.7B).

Provides a singleton local LLM for:
  1. Voice command classification (commands.py)
  2. Chat / assistant (server.py /chat endpoint)

Usage:
    from llm_local import local_llm

    # Simple completion
    response = local_llm.chat("What is 2+2?")

    # Streaming
    for token in local_llm.chat_stream("Tell me a joke"):
        print(token, end="", flush=True)

    # Command detection (fast, non-thinking mode)
    result = local_llm.classify(system_prompt, user_text, max_tokens=30)
"""

import logging
import os
import time
from pathlib import Path
from typing import Generator, Optional

logger = logging.getLogger(__name__)

_MODEL_DIR = os.path.join(
    os.getenv("HOME", "/tmp"), ".config", "talkye", "models"
)
_MODEL_FILENAME = "Qwen_Qwen3-1.7B-Q4_K_M.gguf"
_MODEL_PATH = os.path.join(_MODEL_DIR, _MODEL_FILENAME)

# HuggingFace download — bartowski has all standard quants including Q4_K_M
_MODEL_REPO = "bartowski/Qwen_Qwen3-1.7B-GGUF"
_MODEL_HF_FILE = "Qwen_Qwen3-1.7B-Q4_K_M.gguf"


class LocalLLM:
    """Singleton wrapper around llama-cpp-python for local inference."""

    def __init__(self):
        self._llm = None
        self._loading = False
        self._available = False

    @property
    def available(self) -> bool:
        """Check if model file exists on disk."""
        return os.path.isfile(_MODEL_PATH)

    @property
    def loaded(self) -> bool:
        return self._llm is not None

    @property
    def model_path(self) -> str:
        return _MODEL_PATH

    def load(self, n_gpu_layers: int = -1, n_ctx: int = 4096) -> bool:
        """Load the model into memory. Returns True on success.

        Args:
            n_gpu_layers: -1 = offload all layers to GPU, 0 = CPU only
            n_ctx: context window size (4096 is enough for our use cases)
        """
        if self._llm is not None:
            return True
        if not self.available:
            logger.warning("Model not found at %s", _MODEL_PATH)
            return False
        if self._loading:
            return False

        self._loading = True
        try:
            from llama_cpp import Llama

            t0 = time.perf_counter()
            logger.info("Loading local LLM from %s (gpu_layers=%d, ctx=%d)...",
                        _MODEL_PATH, n_gpu_layers, n_ctx)

            self._llm = Llama(
                model_path=_MODEL_PATH,
                n_gpu_layers=n_gpu_layers,
                n_ctx=n_ctx,
                n_threads=4,
                verbose=False,
            )

            elapsed = time.perf_counter() - t0
            logger.info("Local LLM loaded in %.1fs", elapsed)
            self._available = True
            return True
        except Exception as e:
            logger.exception("Failed to load local LLM: %s", e)
            self._llm = None
            return False
        finally:
            self._loading = False

    def unload(self):
        """Free model from memory."""
        if self._llm is not None:
            del self._llm
            self._llm = None
            self._available = False
            logger.info("Local LLM unloaded")

    def classify(
        self,
        system_prompt: str,
        user_text: str,
        max_tokens: int = 30,
    ) -> str:
        """Fast classification — non-thinking mode, greedy decoding.

        Used for voice command detection. Returns raw text response.
        """
        if not self.loaded and not self.load():
            raise RuntimeError("Local LLM not available")

        # Qwen3 non-thinking: use /no_think in system prompt
        messages = [
            {"role": "system", "content": system_prompt + "\n/no_think"},
            {"role": "user", "content": user_text},
        ]

        t0 = time.perf_counter()
        resp = self._llm.create_chat_completion(
            messages=messages,
            max_tokens=max_tokens,
            temperature=0.0,
            top_p=1.0,
        )
        elapsed = time.perf_counter() - t0

        text = resp["choices"][0]["message"]["content"].strip()
        # Strip any <think></think> blocks that might leak through
        text = _strip_think_tags(text)
        logger.info("LLM classify (%.0fms): '%s' → %s",
                     elapsed * 1000, user_text, text)
        return text

    def chat(
        self,
        user_message: str,
        system_prompt: Optional[str] = None,
        history: Optional[list] = None,
        max_tokens: int = 2048,
        temperature: float = 0.7,
        enable_thinking: bool = False,
    ) -> str:
        """Full chat completion. Returns response text."""
        if not self.loaded and not self.load():
            raise RuntimeError("Local LLM not available")

        messages = self._build_messages(
            user_message, system_prompt, history, enable_thinking
        )

        # Qwen3 best practices: presence_penalty=1.5 for quantized models
        # Non-thinking: temp=0.7, top_p=0.8 | Thinking: temp=0.6, top_p=0.95
        t = 0.6 if enable_thinking else temperature
        tp = 0.95 if enable_thinking else 0.8

        resp = self._llm.create_chat_completion(
            messages=messages,
            max_tokens=max_tokens,
            temperature=t,
            top_p=tp,
            top_k=20,
            presence_penalty=1.5,
        )

        text = resp["choices"][0]["message"]["content"].strip()
        text = _strip_think_tags(text)
        return text

    def chat_stream(
        self,
        user_message: str,
        system_prompt: Optional[str] = None,
        history: Optional[list] = None,
        max_tokens: int = 2048,
        temperature: float = 0.7,
        enable_thinking: bool = False,
    ) -> Generator[str, None, None]:
        """Streaming chat completion. Yields tokens as they generate."""
        if not self.loaded and not self.load():
            raise RuntimeError("Local LLM not available")

        messages = self._build_messages(
            user_message, system_prompt, history, enable_thinking
        )

        t = 0.6 if enable_thinking else temperature
        tp = 0.95 if enable_thinking else 0.8

        stream = self._llm.create_chat_completion(
            messages=messages,
            max_tokens=max_tokens,
            temperature=t,
            top_p=tp,
            top_k=20,
            presence_penalty=1.5,
            stream=True,
        )

        in_think_block = False
        for chunk in stream:
            delta = chunk["choices"][0]["delta"]
            token = delta.get("content", "")
            if not token:
                continue

            # Filter out <think>...</think> blocks from stream
            if "<think>" in token:
                in_think_block = True
                continue
            if "</think>" in token:
                in_think_block = False
                continue
            if in_think_block:
                continue

            yield token

    def _build_messages(
        self,
        user_message: str,
        system_prompt: Optional[str],
        history: Optional[list],
        enable_thinking: bool,
    ) -> list:
        """Build message list for chat completion."""
        messages = []

        think_flag = "/think" if enable_thinking else "/no_think"

        if system_prompt:
            messages.append({
                "role": "system",
                "content": f"{system_prompt}\n{think_flag}",
            })
        else:
            messages.append({
                "role": "system",
                "content": f"You are a helpful assistant.\n{think_flag}",
            })

        if history:
            messages.extend(history)

        messages.append({"role": "user", "content": user_message})
        return messages


def _strip_think_tags(text: str) -> str:
    """Remove <think>...</think> blocks from response text."""
    import re
    return re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL).strip()


def download_model(progress_callback=None) -> bool:
    """Download the Qwen3-1.7B GGUF model from HuggingFace.

    Args:
        progress_callback: Optional callable(downloaded_bytes, total_bytes)

    Returns:
        True if download succeeded.
    """
    if os.path.isfile(_MODEL_PATH):
        logger.info("Model already exists at %s", _MODEL_PATH)
        return True

    os.makedirs(_MODEL_DIR, exist_ok=True)
    url = f"https://huggingface.co/{_MODEL_REPO}/resolve/main/{_MODEL_HF_FILE}"
    tmp_path = _MODEL_PATH + ".tmp"

    logger.info("Downloading model from %s ...", url)
    try:
        import urllib.request

        _last_log = [0]
        def _reporthook(block_num, block_size, total_size):
            downloaded = block_num * block_size
            if progress_callback:
                progress_callback(downloaded, total_size)
            # Log every ~50 MB to avoid spam
            mb = downloaded / 1024 / 1024
            if mb - _last_log[0] >= 50:
                _last_log[0] = mb
                total_mb = total_size / 1024 / 1024 if total_size > 0 else 0
                logger.info("Download: %.0f / %.0f MB", mb, total_mb)

        urllib.request.urlretrieve(url, tmp_path, reporthook=_reporthook)
        os.rename(tmp_path, _MODEL_PATH)
        logger.info("Model downloaded to %s", _MODEL_PATH)
        return True
    except Exception as e:
        logger.exception("Model download failed: %s", e)
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        return False


# ── Singleton ──
local_llm = LocalLLM()
