"""Talkye Scriber Sidecar — Transcription pipeline.

Local whisper.cpp STT, Groq fallback, hallucination filtering, dictation output.
"""

import logging
import os
import time

import config
from platform_utils import paste_text, type_chunk, release_modifiers, user_env, xdotool_prefix, notify
from audio import play_sound
from commands import detect_command, execute_commands

logger = logging.getLogger(__name__)

# ── Groq STT ──

_groq_client = None


def groq_transcribe(audio_path: str, language: str = None) -> dict:
    """Transcribe via Groq Whisper API."""
    global _groq_client
    try:
        if _groq_client is None:
            import openai
            key = os.getenv("GROQ_API_KEY", "")
            if not key:
                logger.warning("GROQ_API_KEY not set, falling back to core.transcribe")
                return config.core.transcribe(audio_path, None)
            _groq_client = openai.OpenAI(api_key=key, base_url="https://api.groq.com/openai/v1")

        with open(audio_path, "rb") as audio_file:
            kwargs = {
                "model": "whisper-large-v3",
                "file": audio_file,
                "response_format": "verbose_json",
            }
            if language:
                kwargs["language"] = language
            resp = _groq_client.audio.transcriptions.create(**kwargs)

        text = (resp.text or "").strip()
        lang = getattr(resp, "language", "?")
        logger.info("Groq transcription [%s]: %s", lang, text)
        return {"text": text, "language": lang, "duration": getattr(resp, "duration", 0) or 0}
    except Exception as e:
        logger.warning("Groq transcription failed: %s, falling back", e)
        return config.core.transcribe(audio_path, None)


# ── Local whisper.cpp STT ──


def local_transcribe(audio_path: str, language: str = None) -> dict:
    """Transcribe via local whisper.cpp binary (GPU-accelerated).

    Uses turbo model for speed. Translation handled separately by LLM.
    """
    import subprocess
    try:
        model = config.WHISPER_MODEL
        cmd = [
            config.WHISPER_BIN,
            "-m", model,
            "-f", audio_path,
            "--no-timestamps",
            "-np",
            "-t", "4",
            "-bo", "5",           # best-of candidates
            "-bs", "5",           # beam size
            "-et", "2.8",         # higher entropy threshold = less aggressive filtering
            "--no-speech-thold", "0.5",  # lower = keep more speech
        ]
        if language:
            cmd += ["-l", language]
        else:
            cmd += ["-l", "auto"]

        t0 = time.monotonic()
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        elapsed = time.monotonic() - t0

        text = result.stdout.strip()
        text = " ".join(text.split())
        logger.info("Local transcribe (%.1fs) [%s]: %s",
                     elapsed, language or "auto", text)
        return {"text": text, "language": language or "auto", "duration": elapsed}
    except Exception as e:
        logger.warning("Local transcription failed: %s, falling back to Groq", e)
        return groq_transcribe(audio_path, language)


# ── STT router ──


def _transcribe(audio_path: str, language: str = None) -> dict:
    """Route to the configured STT backend."""
    if config.STT_BACKEND == "local":
        return local_transcribe(audio_path, language)
    return groq_transcribe(audio_path, language)


# ── Whisper hallucination filter ──

_HALLUCINATIONS = {
    "să vă mulțumim pentru vizionare", "mulțumim pentru vizionare",
    "thank you for watching", "thanks for watching",
    "subtitles by", "translated by",
    "să vă mulțumesc pentru like", "mulțumesc pentru like",
    "vă mulțumesc pentru vizionare", "mulțumesc pentru vizionare",
    "să ne vedem la următoarea mea rețetă",
    "ne vedem la următoarea mea rețetă",
    "mulțumit pentru vizionare",
}


def _select_and_replace(old_text: str, new_text: str):
    """Select the previously pasted text and replace it with corrected text."""
    import subprocess
    n = len(old_text)
    if n <= 0:
        return
    env = user_env()
    prefix = xdotool_prefix()
    release_modifiers()
    subprocess.run(
        prefix + ["xdotool", "key", "--clearmodifiers", "--repeat", str(n), "--delay", "0", "shift+Left"],
        timeout=10, env=env, capture_output=True,
    )
    time.sleep(0.05)
    paste_text(new_text)


def transcribe_and_paste(prefetched_result=None):
    """Transcribe audio and paste at cursor. Detects voice commands for short utterances."""
    try:
        if not os.path.isfile(config.AUDIOFILE) or os.path.getsize(config.AUDIOFILE) < 5000:
            notify("Too short, ignored")
            return

        lang = config.LANGUAGE if config.LANGUAGE != "auto" else None

        if prefetched_result:
            result = prefetched_result
            logger.info("Using prefetched speculative result")
        else:
            result = _transcribe(config.AUDIOFILE, lang)

        text = result.get("text", "").strip()
        detected_lang = result.get("language", "?")

        if not text:
            notify("No speech detected")
            return

        if text.lower().rstrip(".!?,;: ") in _HALLUCINATIONS:
            logger.info("Filtered Whisper hallucination: '%s'", text)
            return

        logger.info("Transcribed [%s]: %s", detected_lang, text)
        word_count = len(text.split())

        # Short utterance? Check if it's a voice command
        if word_count <= config.MAX_COMMAND_WORDS:
            cmd_ids = detect_command(text)
            if cmd_ids:
                execute_commands(cmd_ids)
                return

        # Normal dictation — leading space for segment separation
        text = " " + text

        use_cleanup = config.LLM_CLEANUP or config.DICTATE_GRAMMAR
        use_translate = "en" if config.DICTATE_TRANSLATE else None

        if use_cleanup or use_translate:
            # Show raw STT text immediately so user doesn't wait
            paste_text(text)
            # Process through LLM (Groq — fast)
            corrected = config.core.llm_process(text.strip(), detected_lang, use_cleanup, use_translate)
            if corrected and corrected.strip() != text.strip():
                corrected = " " + corrected.strip()
                _select_and_replace(text, corrected)
            logger.info("Final output: %s", corrected)
        else:
            notify(f"[{detected_lang}] {text}")
            time.sleep(0.3)
            paste_text(text)

    except Exception as e:
        logger.exception("Transcription failed")
        notify(f"Error: {e}")
        play_sound("error")
    finally:
        for f in [config.AUDIOFILE, config.RAWFILE]:
            try:
                os.unlink(f)
            except OSError:
                pass
        config.busy = False
