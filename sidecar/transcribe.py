"""Talkye Scriber Sidecar — Transcription pipeline.

Local whisper.cpp STT, Groq fallback, hallucination filtering, dictation output.
"""

import logging
import os
import re
import struct
import time
import wave

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
            "-et", "2.4",         # entropy threshold — lower = stricter hallucination rejection
            "-lpt", "-1.0",       # logprob threshold — reject low-confidence tokens
            "--no-speech-thold", "0.6",  # higher = more aggressive silence detection
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
    # Romanian
    "să vă mulțumim pentru vizionare", "mulțumim pentru vizionare",
    "vă mulțumesc pentru vizionare", "mulțumesc pentru vizionare",
    "să vă mulțumesc pentru like", "mulțumesc pentru like",
    "să ne vedem la următoarea mea rețetă",
    "ne vedem la următoarea mea rețetă",
    "mulțumit pentru vizionare",
    "vă mulțumim pentru vizionare",
    "să vă mulțumim pentru vizionare!",
    "mulțumesc pentru vizionare!",
    # English
    "thank you for watching", "thanks for watching",
    "subtitles by", "translated by",
    "thank you for listening", "thanks for listening",
    "please subscribe", "like and subscribe",
    # German
    "danke fürs zuschauen", "vielen dank fürs zuschauen",
    # French
    "merci d'avoir regardé", "merci pour votre visionnage",
    # Spanish
    "gracias por ver", "gracias por mirar",
}


# ══════════════════════════════════════════════════════════════════════════════
# ANTI-HALLUCINATION SYSTEM — Multi-layered filter for Whisper phantom output
# ══════════════════════════════════════════════════════════════════════════════

# Layer 1: Audio energy gate — skip transcription if audio is near-silent
_RMS_SILENCE_THRESHOLD = 80    # 16-bit PCM; lowered to avoid blocking real speech
_SPEECH_FRAME_THRESHOLD = 150  # per-chunk threshold for "active speech"
_MIN_SPEECH_RATIO = 0.03       # at least 3% of chunks must have speech energy


def _audio_has_speech(wav_path: str) -> bool:
    """Check if WAV file contains real speech using energy analysis.

    Conservative gate — only filters near-total silence.
    Better to let a few hallucinations through than block real speech.
    """
    try:
        with wave.open(wav_path, "rb") as wf:
            n_frames = wf.getnframes()
            sample_rate = wf.getframerate()
            if n_frames == 0:
                return False
            raw = wf.readframes(n_frames)
            n_samples = len(raw) // 2
            if n_samples == 0:
                return False
            samples = struct.unpack(f"<{n_samples}h", raw)

            # Overall RMS
            rms = (sum(s * s for s in samples) / n_samples) ** 0.5
            peak = max(abs(s) for s in samples)

            duration = n_samples / max(sample_rate, 1)
            logger.info("Audio energy: RMS=%.0f, peak=%d, duration=%.1fs", rms, peak, duration)

            # Only filter near-total silence (very conservative)
            if rms < _RMS_SILENCE_THRESHOLD and peak < 300:
                logger.info("Audio near-silent (RMS=%.0f, peak=%d), skipping", rms, peak)
                return False

            return True
    except Exception as e:
        logger.warning("Audio energy check failed: %s, proceeding anyway", e)
        return True  # fail open


# Layer 2: Exact-match hallucination phrases (expanded)
_HALLUCINATIONS_EXACT = {
    # ── Romanian ──
    "mulțumim pentru vizionare",
    "vă mulțumim pentru vizionare",
    "să vă mulțumim pentru vizionare",
    "mulțumesc pentru vizionare",
    "vă mulțumesc pentru vizionare",
    "mulțumit pentru vizionare",
    "mulțumim pentru like",
    "să vă mulțumesc pentru like",
    "mulțumesc pentru like",
    "să ne vedem la următoarea mea rețetă",
    "ne vedem la următoarea mea rețetă",
    "ne vedem data viitoare",
    "pe data viitoare",
    "nu uitați să dați like",
    "nu uitați să dați subscribe",
    "nu uitați să vă abonați",
    "abonați-vă la canal",
    "apăsați pe clopoțel",
    "lăsați un like",
    "lăsați un comentariu",
    "subtitrare realizată de",
    "subtitrare automată",
    "subtitrat de",
    "traducere realizată de",
    # ── English ──
    "thank you for watching",
    "thanks for watching",
    "thank you for listening",
    "thanks for listening",
    "thank you for your attention",
    "thanks for your attention",
    "please subscribe",
    "like and subscribe",
    "hit the bell",
    "hit the like button",
    "smash the like button",
    "don't forget to subscribe",
    "leave a comment",
    "leave a like",
    "subtitles by",
    "translated by",
    "captions by",
    "transcribed by",
    "see you next time",
    "see you in the next video",
    "see you in the next one",
    "bye bye",
    "goodbye",
    "i'll see you later",
    "until next time",
    "stay tuned",
    "you",
    # ── German ──
    "danke fürs zuschauen",
    "vielen dank fürs zuschauen",
    "danke für eure aufmerksamkeit",
    "bis zum nächsten mal",
    "vergesst nicht zu abonnieren",
    "untertitel von",
    # ── French ──
    "merci d'avoir regardé",
    "merci pour votre visionnage",
    "merci de votre attention",
    "n'oubliez pas de vous abonner",
    "à la prochaine",
    "sous-titres par",
    # ── Spanish ──
    "gracias por ver",
    "gracias por mirar",
    "gracias por su atención",
    "no olviden suscribirse",
    "hasta la próxima",
    "subtítulos por",
    # ── Italian ──
    "grazie per aver guardato",
    "grazie per la visione",
    "iscrivetevi al canale",
    # ── Portuguese ──
    "obrigado por assistir",
    "não esqueça de se inscrever",
    # ── Polish ──
    "dziękuję za oglądanie",
    "nie zapomnijcie zasubskrybować",
    # ── Turkish ──
    "izlediğiniz için teşekkürler",
    "abone olmayı unutmayın",
    # ── Russian ──
    "спасибо за просмотр",
    "не забудьте подписаться",
    # ── Japanese ──
    "ご視聴ありがとうございました",
    # ── Korean ──
    "시청해 주셔서 감사합니다",
    # ── Chinese ──
    "感谢收看",
    "感谢观看",
    "谢谢观看",
    # ── Arabic ──
    "شكرا للمشاهدة",
    # ── Dutch ──
    "bedankt voor het kijken",
    # ── Hungarian ──
    "köszönöm a figyelmet",
    # ── Ukrainian ──
    "дякую за перегляд",
    # ── Czech ──
    "děkuji za sledování",
    # ── Swedish ──
    "tack för att ni tittade",
    # ── Single-word/noise hallucinations ──
    "you",
    "the",
    "a",
    "i",
    "so",
    "oh",
    "um",
    "uh",
    "hmm",
    "hm",
    "ah",
    "eh",
    "mhm",
    "...",
    "…",
}

# Layer 3: Substring patterns — if text CONTAINS any of these, it's hallucinated
_HALLUCINATION_SUBSTRINGS = [
    "mulțumim pentru vizionare",
    "mulțumesc pentru vizionare",
    "mulțumit pentru vizionare",
    "pentru vizionare",
    "nu uitați să dați",
    "nu uitați să vă abonați",
    "thank you for watching",
    "thanks for watching",
    "thank you for listening",
    "please subscribe",
    "like and subscribe",
    "don't forget to subscribe",
    "subtitles by",
    "translated by",
    "captions by",
    "danke fürs zuschauen",
    "merci d'avoir regardé",
    "gracias por ver",
    "gracias por mirar",
    "obrigado por assistir",
    "спасибо за просмотр",
    "ご視聴ありがとう",
    "感谢收看",
    "感谢观看",
    "شكرا للمشاهدة",
]

# Layer 4: Regex patterns for structural hallucination detection
_HALLUCINATION_PATTERNS = [
    # Romanian YouTube phrases
    re.compile(r"mul[țt]um\w*\s+pentru\s+(vizionare|like|subscribe|aten[țt]ie)", re.IGNORECASE),
    re.compile(r"nu\s+uita[țt]i\s+s[aă]\s+(da[țt]i|v[aă]\s+abona)", re.IGNORECASE),
    re.compile(r"abona[țt]i[\s-]*v[aă]", re.IGNORECASE),
    re.compile(r"ap[aă]sa[țt]i\s+pe\s+clopo[țt]el", re.IGNORECASE),
    re.compile(r"l[aă]sa[țt]i\s+un\s+(like|comentariu|subscribe)", re.IGNORECASE),
    re.compile(r"ne\s+vedem\s+(data|la)\s+(viitoare|urm[aă]toare)", re.IGNORECASE),
    re.compile(r"pe\s+data\s+viitoare", re.IGNORECASE),
    re.compile(r"subtitr\w+\s+(de|realizat)", re.IGNORECASE),
    # English YouTube phrases
    re.compile(r"thank\w*\s+for\s+(watching|listening|viewing|your\s+attention)", re.IGNORECASE),
    re.compile(r"(hit|smash|press)\s+the\s+(like|subscribe|bell|notification)", re.IGNORECASE),
    re.compile(r"(don'?t\s+)?forget\s+to\s+(like|subscribe|share|comment)", re.IGNORECASE),
    re.compile(r"see\s+you\s+(next\s+time|in\s+the\s+next|later|soon)", re.IGNORECASE),
    re.compile(r"(subtitles?|captions?|translated?|transcribed?)\s+by", re.IGNORECASE),
    re.compile(r"(please\s+)?(like|subscribe)\s+(and|&)\s+(subscribe|like|share)", re.IGNORECASE),
    # Generic YouTube/podcast outro
    re.compile(r"(bye\s*){2,}", re.IGNORECASE),
    re.compile(r"until\s+next\s+time", re.IGNORECASE),
    re.compile(r"stay\s+tuned", re.IGNORECASE),
    re.compile(r"i'?ll\s+see\s+you\s+(next|later|in)", re.IGNORECASE),
]

# Layer 5: Repetition detector thresholds
_MAX_WORD_REPEAT_RATIO = 0.6  # if >60% of words are the same word, it's hallucinated
_MAX_BIGRAM_REPEAT_RATIO = 0.5  # if >50% of bigrams are the same, hallucinated


def _is_repetitive(text: str) -> bool:
    """Detect repetitive hallucinations (e.g. same word/phrase looped)."""
    words = text.lower().split()
    if len(words) < 4:
        return False
    # Single word repetition
    from collections import Counter
    counts = Counter(words)
    most_common_count = counts.most_common(1)[0][1]
    if most_common_count / len(words) > _MAX_WORD_REPEAT_RATIO:
        logger.info("Repetitive hallucination detected (word repeat %.0f%%): '%s'",
                     100 * most_common_count / len(words), text)
        return True
    # Bigram repetition
    if len(words) >= 6:
        bigrams = [f"{words[i]} {words[i+1]}" for i in range(len(words) - 1)]
        bg_counts = Counter(bigrams)
        most_common_bg = bg_counts.most_common(1)[0][1]
        if most_common_bg / len(bigrams) > _MAX_BIGRAM_REPEAT_RATIO:
            logger.info("Repetitive hallucination detected (bigram repeat %.0f%%): '%s'",
                         100 * most_common_bg / len(bigrams), text)
            return True
    return False


def _is_hallucination(text: str, audio_duration: float = 0) -> bool:
    """Multi-layered hallucination check. Returns True if text should be filtered."""
    if not text:
        return True

    cleaned = text.strip()
    normalized = cleaned.lower().rstrip(".!?,;:… ")

    # Layer 2: Exact match
    if normalized in _HALLUCINATIONS_EXACT:
        logger.info("Hallucination filtered (exact match): '%s'", text)
        return True

    # Layer 3: Substring match
    lower = cleaned.lower()
    for phrase in _HALLUCINATION_SUBSTRINGS:
        if phrase in lower:
            logger.info("Hallucination filtered (substring '%s'): '%s'", phrase, text)
            return True

    # Layer 4: Regex pattern match
    for pattern in _HALLUCINATION_PATTERNS:
        if pattern.search(cleaned):
            logger.info("Hallucination filtered (pattern '%s'): '%s'", pattern.pattern[:40], text)
            return True

    # Layer 5: Repetition detection
    if _is_repetitive(cleaned):
        return True

    # Layer 6: (removed — whisper.cpp returns processing time, not audio
    # duration, so speech-rate heuristic caused false positives on fast GPUs)

    # Layer 7: Only punctuation/symbols
    alpha_chars = sum(1 for c in cleaned if c.isalpha())
    if len(cleaned) > 0 and alpha_chars / len(cleaned) < 0.3:
        logger.info("Hallucination filtered (low alpha ratio %.0f%%): '%s'",
                     100 * alpha_chars / len(cleaned), text)
        return True

    return False


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

        # Layer 1: Audio energy gate — skip if near-silent
        if not _audio_has_speech(config.AUDIOFILE):
            return

        lang = config.LANGUAGE if config.LANGUAGE != "auto" else None

        if prefetched_result:
            result = prefetched_result
            logger.info("Using prefetched speculative result")
        else:
            result = _transcribe(config.AUDIOFILE, lang)

        text = result.get("text", "").strip()
        detected_lang = result.get("language", "?")
        audio_duration = result.get("duration", 0)

        if not text:
            notify("No speech detected")
            return

        # Layers 2-7: Multi-layered hallucination filter
        if _is_hallucination(text, audio_duration):
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
