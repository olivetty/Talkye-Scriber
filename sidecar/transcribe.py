"""Talkye Sidecar — Transcription pipeline.

Groq STT, hallucination filtering, wake-phrase stripping, dictation output.
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

        # Prompt hint helps Whisper correctly transcribe the wake phrase
        prompt_hint = f'{config.WAKE_PHRASE.title()}. '

        with open(audio_path, "rb") as audio_file:
            kwargs = {
                "model": "whisper-large-v3",
                "file": audio_file,
                "response_format": "verbose_json",
                "prompt": prompt_hint,
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


def _strip_wake_phrase(text: str) -> str | None:
    """Strip wake phrase from start of transcribed text.

    Uses word-based matching with phonetic normalization to handle
    Whisper transcription variants (e.g. "hei" for "hey").
    Returns cleaned text (preserving original case), or None if only
    the wake phrase was said.
    """
    if not config.wake_phrase_words:
        return text

    import re
    # Split text into words, preserving positions for reconstruction
    # word_spans: list of (word_lowercase, start_idx, end_idx)
    word_spans = [(m.group().lower(), m.start(), m.end())
                  for m in re.finditer(r"[a-zA-ZÀ-ÿ']+", text)]

    if len(word_spans) < len(config.wake_phrase_words):
        return text

    # Normalize a word using phonetic map
    def normalize(w: str) -> str:
        return config._PHONETIC_MAP.get(w, w)

    # Check if first N words match the wake phrase (with phonetic normalization)
    n = len(config.wake_phrase_words)
    match = True
    for i in range(n):
        if normalize(word_spans[i][0]) != normalize(config.wake_phrase_words[i]):
            match = False
            break

    if not match:
        return text

    # Wake phrase matched — find where the rest starts
    if len(word_spans) <= n:
        return None  # Only the wake phrase, nothing else

    # Start from after the last matched word, skip punctuation/spaces
    rest_start = word_spans[n - 1][2]
    while rest_start < len(text) and text[rest_start] in ' ,.!?;:-\n\t':
        rest_start += 1

    if rest_start >= len(text):
        return None

    return text[rest_start:]


def transcribe_and_paste(prefetched_result=None):
    """Transcribe audio, auto-detect commands vs dictation.

    Args:
        prefetched_result: If provided, skip Groq call and use this result directly
                          (from speculative transcription).
    """
    import subprocess
    _cmd_executed = False

    try:
        if not os.path.isfile(config.AUDIOFILE) or os.path.getsize(config.AUDIOFILE) < 5000:
            notify("Too short, ignored")
            return

        lang = config.LANGUAGE if config.LANGUAGE != "auto" else None
        is_vad = config.INPUT_MODE == "vad"

        if prefetched_result:
            result = prefetched_result
            logger.info("Using prefetched speculative result")
        elif is_vad:
            is_active = time.monotonic() < config.vad_active_until
            vad_lang = (config.LANGUAGE if config.LANGUAGE != "auto" else None) if is_active else None
            result = groq_transcribe(config.AUDIOFILE, vad_lang)
        else:
            result = config.core.transcribe(config.AUDIOFILE, lang)

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

        # In VAD mode, strip wake phrase from transcription
        # (Rustpotter detects at audio level, but Whisper still transcribes it)
        if is_vad:
            stripped = _strip_wake_phrase(text)
            if stripped is None:
                return  # Only the wake phrase, nothing else
            text = stripped
            word_count = len(text.split())

        # Short utterance? Check if it's a voice command
        if word_count <= config.MAX_COMMAND_WORDS:
            cmd_ids = detect_command(text)
            if cmd_ids:
                _cmd_executed = execute_commands(cmd_ids)  # True if terminal command
                return

        # Normal dictation — leading space in VAD mode for segment separation
        if is_vad:
            text = " " + text

        use_cleanup = config.LLM_CLEANUP
        use_translate = config.TRANSLATE_TO if config.TRANSLATE_ENABLED else None

        if use_cleanup or use_translate:
            full_output = []
            for token in config.core.llm_process_stream(text, detected_lang, use_cleanup, use_translate):
                full_output.append(token)
                type_chunk(token)
            final = "".join(full_output).strip()
            logger.info("Final output: %s", final)
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
        # In VAD mode, keep session active after every segment (text, command, or skip).
        # Session ends only when VAD timeout expires with no speech.
        if config.INPUT_MODE == "vad":
            if _cmd_executed:
                # Command = final action. Kill session silently (no "done" sound).
                config.vad_active_until = 0.0
                config.vad_silent_end = True
            else:
                config.set_vad_active()
        config.busy = False
