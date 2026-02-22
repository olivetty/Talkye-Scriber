"""Talkye Sidecar — Groq Cloud LLM.

Provides streaming chat via Groq's OpenAI-compatible API.
Models: Qwen3-32B, GPT OSS 120B, GPT OSS 20B, Llama 3.3 70B.

Usage:
    from llm_groq import groq_chat_stream, groq_available, GROQ_MODELS

    for token in groq_chat_stream("Hello", model="qwen/qwen3-32b"):
        print(token, end="", flush=True)
"""

import json
import logging
import os
import re
import urllib.request
import urllib.error

logger = logging.getLogger(__name__)

_API_KEY = os.getenv("GROQ_API_KEY", "")
_API_URL = "https://api.groq.com/openai/v1/chat/completions"

# Available Groq models for chat
GROQ_MODELS = {
    "qwen/qwen3-32b": {
        "label": "Qwen3 32B",
        "description": "Thinking · 400 T/s · $0.29/1M",
        "context": 131072,
        "max_completion": 40960,
        "supports_thinking": True,
    },
    "openai/gpt-oss-120b": {
        "label": "GPT OSS 120B",
        "description": "Smartest · 500 T/s · $0.15/1M",
        "context": 131072,
        "max_completion": 65536,
        "supports_thinking": False,
    },
    "openai/gpt-oss-20b": {
        "label": "GPT OSS 20B",
        "description": "Fastest · 1000 T/s · $0.075/1M",
        "context": 131072,
        "max_completion": 65536,
        "supports_thinking": False,
    },
    "llama-3.3-70b-versatile": {
        "label": "Llama 3.3 70B",
        "description": "Versatile · 280 T/s · $0.59/1M",
        "context": 131072,
        "max_completion": 32768,
        "supports_thinking": False,
    },
}


def groq_available() -> bool:
    """True if GROQ_API_KEY is set."""
    return bool(_API_KEY)


def _strip_think_tags(text: str) -> str:
    """Remove <think>...</think> blocks from response text."""
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL)
    text = re.sub(r"<think>\s*", "", text)
    text = text.replace("</think>", "")
    return text.strip()


def groq_chat_stream(
    user_message: str,
    model: str = "qwen/qwen3-32b",
    system_prompt: str | None = None,
    history: list | None = None,
    enable_thinking: bool = False,
    max_tokens: int = 4096,
    temperature: float = 0.7,
):
    """Streaming chat via Groq API. Yields tokens.

    Uses urllib (no extra deps) with chunked transfer for SSE.
    """
    if not _API_KEY:
        raise RuntimeError("GROQ_API_KEY not set")

    model_info = GROQ_MODELS.get(model)
    if not model_info:
        raise ValueError(f"Unknown model: {model}")

    messages = []
    think_flag = ""
    if model_info["supports_thinking"] and enable_thinking:
        think_flag = "\n/think"
    elif model_info["supports_thinking"]:
        think_flag = "\n/no_think"

    sys_content = (system_prompt or "You are a helpful assistant.") + think_flag
    messages.append({"role": "system", "content": sys_content})

    if history:
        messages.extend(history)
    messages.append({"role": "user", "content": user_message})

    # Qwen3 thinking params vs normal
    if model_info["supports_thinking"] and enable_thinking:
        t, tp = 0.6, 0.95
    else:
        t, tp = temperature, 0.8

    body = json.dumps({
        "model": model,
        "messages": messages,
        "max_tokens": min(max_tokens, model_info["max_completion"]),
        "temperature": t,
        "top_p": tp,
        "stream": True,
    }).encode()

    req = urllib.request.Request(
        _API_URL,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {_API_KEY}",
            "Content-Type": "application/json",
        },
    )

    in_think = False
    buf = ""

    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            leftover = ""
            while True:
                chunk = resp.read(4096)
                if not chunk:
                    break
                text = leftover + chunk.decode("utf-8", errors="replace")
                lines = text.split("\n")
                leftover = lines[-1]  # may be incomplete

                for line in lines[:-1]:
                    line = line.strip()
                    if not line.startswith("data: "):
                        continue
                    payload = line[6:]
                    if payload == "[DONE]":
                        break
                    try:
                        data = json.loads(payload)
                        delta = data["choices"][0]["delta"]
                        token = delta.get("content", "")
                        if not token:
                            continue

                        # Filter <think> blocks for Qwen3
                        buf += token
                        if not in_think and "<think>" in buf:
                            idx = buf.index("<think>")
                            before = buf[:idx]
                            if before:
                                yield before
                            buf = buf[idx + 7:]
                            in_think = True
                            continue
                        if in_think:
                            if "</think>" in buf:
                                idx = buf.index("</think>")
                                buf = buf[idx + 8:]
                                in_think = False
                                if buf:
                                    yield buf
                                    buf = ""
                            else:
                                if len(buf) > 200:
                                    buf = buf[-20:]
                            continue
                        yield buf
                        buf = ""
                    except (json.JSONDecodeError, KeyError, IndexError):
                        continue

            # Process any remaining leftover
            if leftover.strip().startswith("data: "):
                payload = leftover.strip()[6:]
                if payload != "[DONE]":
                    try:
                        data = json.loads(payload)
                        token = data["choices"][0]["delta"].get("content", "")
                        if token and not in_think:
                            yield token
                    except Exception:
                        pass

        if buf and not in_think:
            yield buf

    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        logger.error("Groq API error %d: %s", e.code, body[:300])
        raise RuntimeError(f"Groq API error {e.code}: {body[:200]}")
    except Exception as e:
        logger.exception("Groq stream error: %s", e)
        raise
