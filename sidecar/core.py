"""Dictate Core — speech-to-text pipeline.

This is the brain of Dictate. It takes audio and returns text.
Platform-independent, no UI, no audio capture — just processing.

Usage:
    from core import DictateCore

    core = DictateCore()
    result = core.transcribe("recording.wav")
    # → {"text": "Hello world", "language": "en", "duration": 2.1}

    result = core.process("recording.wav", cleanup=True, translate_to="en")
    # → {"text": "Hello world", "language": "en", "duration": 2.1, "original": "Salut lume"}

    # Streaming (tokens yielded as they generate):
    for token in core.process_stream("recording.wav", cleanup=True, translate_to="en"):
        print(token, end="", flush=True)
"""

import logging
import os
import tempfile
import time
from pathlib import Path
from typing import Generator, Optional

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")

logger = logging.getLogger(__name__)

# Known Whisper hallucinations — filtered out
HALLUCINATIONS = {
    "thank you", "thank you.", "thank you!", "thanks.",
    "you", "you.", "the end.", "the end",
    "mulțumesc.", "mulțumesc", "subtitrat de",
    "subtitrare realizată de", "subtitrare și traducere",
}

PROMPTS = {
    "ro": "Aceasta este o dictare în limba română, cu punctuație corectă.",
    "en": "This is a dictation in English, with correct punctuation.",
}


class DictateCore:
    """Main pipeline: audio → transcribe → cleanup → translate → text."""

    def __init__(
        self,
        mode: str = None,
        groq_api_key: str = None,
        openai_api_key: str = None,
        whisper_model: str = None,
        whisper_compute: str = None,
        llm_provider: str = None,
        llm_api_key: str = None,
        llm_model: str = None,
    ):
        """Initialize with explicit params or fall back to env vars.

        Args:
            mode: "groq", "api", or "local" (default: env DICTATE_MODE or "groq")
            groq_api_key: Groq API key (default: env GROQ_API_KEY)
            openai_api_key: OpenAI API key (default: env OPENAI_API_KEY)
            whisper_model: Whisper model name (default per backend)
            whisper_compute: Compute type for local backend (default: int8_float16)
            llm_provider: "groq", "xai", or "openai" (default: env LLM_PROVIDER)
            llm_api_key: LLM API key (default: env LLM_API_KEY)
            llm_model: LLM model name (default: env LLM_MODEL)
        """
        self.mode = (mode or os.getenv("DICTATE_MODE", "groq")).lower()
        self.groq_api_key = groq_api_key or os.getenv("GROQ_API_KEY", "")
        self.openai_api_key = openai_api_key or os.getenv("OPENAI_API_KEY", "")
        self.whisper_compute = whisper_compute or os.getenv("WHISPER_COMPUTE", "int8_float16")

        # LLM settings — prefer Groq for speed (GPT OSS 120B at 500 T/s)
        self.llm_provider = (llm_provider or os.getenv("LLM_PROVIDER", "groq")).lower()
        self.llm_api_key = llm_api_key or os.getenv("LLM_API_KEY", "") or os.getenv("GROQ_API_KEY", "")
        self.llm_model = llm_model or os.getenv("LLM_MODEL", "openai/gpt-oss-20b")

        # If using Groq provider but LLM_API_KEY is not a Groq key, fall back to GROQ_API_KEY
        if self.llm_provider == "groq" and self.llm_api_key and not self.llm_api_key.startswith("gsk_"):
            groq_key = os.getenv("GROQ_API_KEY", "")
            if groq_key:
                self.llm_api_key = groq_key

        # Backend-specific init
        self._whisper_client = None
        self._local_model = None

        if self.mode == "groq":
            self.whisper_model = whisper_model or os.getenv("WHISPER_MODEL", "whisper-large-v3")
            self._init_groq()
        elif self.mode == "api":
            self.whisper_model = whisper_model or os.getenv("WHISPER_MODEL", "whisper-1")
            self._init_openai()
        elif self.mode == "local":
            self.whisper_model = whisper_model or os.getenv("WHISPER_MODEL", "large-v3")
            self._init_local()
        elif self.mode == "server":
            # Legacy: forward to local whisper server
            self.whisper_model = whisper_model or os.getenv("WHISPER_MODEL", "whisper-large-v3")
            self.server_url = os.getenv("WHISPER_URL", "http://localhost:8178/transcribe")
            logger.info("Using server mode → %s", self.server_url)
        else:
            raise ValueError(f"Unknown mode: {self.mode}. Use 'groq', 'api', 'local', or 'server'.")

        logger.info("DictateCore initialized (mode=%s, model=%s)", self.mode, self.whisper_model)

    def _init_groq(self):
        import openai
        if not self.groq_api_key:
            raise RuntimeError("GROQ_API_KEY is required for groq mode")
        self._whisper_client = openai.OpenAI(
            api_key=self.groq_api_key,
            base_url="https://api.groq.com/openai/v1",
        )

    def _init_openai(self):
        import openai
        if not self.openai_api_key:
            raise RuntimeError("OPENAI_API_KEY is required for api mode")
        self._whisper_client = openai.OpenAI(api_key=self.openai_api_key)

    def _init_local(self):
        from faster_whisper import WhisperModel
        logger.info("Loading local model '%s' on cuda/%s ...", self.whisper_model, self.whisper_compute)
        self._local_model = WhisperModel(
            self.whisper_model, device="cuda", compute_type=self.whisper_compute,
        )
        logger.info("Local model loaded.")

    # ── Transcription ──────────────────────────────

    def _transcribe_server(self, audio_path: str, language: Optional[str]) -> dict:
        """Forward to local whisper server (legacy mode)."""
        import json
        import subprocess
        t0 = time.perf_counter()
        curl_cmd = ["curl", "-s", "-X", "POST", self.server_url,
                    "-F", f"file=@{audio_path}", "--max-time", "60"]
        if language:
            curl_cmd += ["-F", f"language={language}"]
        result = subprocess.run(curl_cmd, capture_output=True, text=True, timeout=65)
        data = json.loads(result.stdout)
        elapsed = time.perf_counter() - t0
        logger.info("Server transcribed in %.2fs — %s", elapsed, data.get("text", "")[:80])
        return data

    def transcribe(
        self,
        audio_path: str,
        language: Optional[str] = None,
    ) -> dict:
        """Transcribe audio file to text.

        Args:
            audio_path: Path to audio file (WAV, WebM, OGG, MP3, M4A, FLAC)
            language: Force language ("ro", "en") or None for auto-detect

        Returns:
            {"text": str, "language": str, "duration": float}
        """
        if self.mode == "local":
            return self._transcribe_local(audio_path, language)
        elif self.mode == "server":
            return self._transcribe_server(audio_path, language)
        else:
            return self._transcribe_api(audio_path, language)

    def transcribe_bytes(
        self,
        audio_bytes: bytes,
        format: str = "wav",
        language: Optional[str] = None,
    ) -> dict:
        """Transcribe audio from bytes.

        Args:
            audio_bytes: Raw audio data
            format: Audio format extension (wav, webm, ogg, mp3, etc.)
            language: Force language or None for auto-detect

        Returns:
            {"text": str, "language": str, "duration": float}
        """
        with tempfile.NamedTemporaryFile(suffix=f".{format}", delete=False) as tmp:
            tmp.write(audio_bytes)
            tmp.flush()
            tmp_path = tmp.name
        try:
            return self.transcribe(tmp_path, language)
        finally:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

    def _transcribe_api(self, audio_path: str, language: Optional[str]) -> dict:
        """Transcribe using Groq or OpenAI API."""
        t0 = time.perf_counter()
        prompt = PROMPTS.get(language, "") if language else ""

        with open(audio_path, "rb") as f:
            kwargs = {
                "model": self.whisper_model,
                "file": f,
                "response_format": "verbose_json",
            }
            if language:
                kwargs["language"] = language
            if prompt:
                kwargs["prompt"] = prompt
            response = self._whisper_client.audio.transcriptions.create(**kwargs)

        text = response.text.strip() if response.text else ""
        lang = getattr(response, "language", language or "?")
        duration = getattr(response, "duration", 0) or 0
        elapsed = time.perf_counter() - t0

        # Filter hallucinations
        if text.lower().strip(".!? ") in HALLUCINATIONS or text.lower() in HALLUCINATIONS:
            logger.warning("Filtered hallucination: '%s'", text)
            text = ""

        logger.info(
            "Transcribed %.1fs audio in %.2fs — lang=%s — %d chars",
            duration, elapsed, lang, len(text),
        )
        return {"text": text, "language": lang, "duration": round(duration, 2)}

    def _transcribe_local(self, audio_path: str, language: Optional[str]) -> dict:
        """Transcribe using local faster-whisper model."""
        from faster_whisper.audio import decode_audio

        audio = decode_audio(audio_path)

        if not language:
            language = self._detect_language_local(audio)

        prompt = PROMPTS.get(language, PROMPTS["ro"])
        t0 = time.perf_counter()

        segments, info = self._local_model.transcribe(
            audio,
            language=language,
            beam_size=5,
            vad_filter=True,
            vad_parameters={
                "threshold": 0.5,
                "min_speech_duration_ms": 250,
                "min_silence_duration_ms": 500,
                "speech_pad_ms": 400,
            },
            condition_on_previous_text=False,
            no_speech_threshold=0.6,
            log_prob_threshold=-1.0,
            initial_prompt=prompt,
            repetition_penalty=1.2,
            no_repeat_ngram_size=3,
            temperature=[0.0, 0.2, 0.4, 0.6, 0.8, 1.0],
            compression_ratio_threshold=2.4,
            hallucination_silence_threshold=2.0,
            suppress_blank=True,
        )

        all_text = []
        for seg in segments:
            logger.info(
                "Segment [%.1f-%.1f] lang=%s logprob=%.2f: %s",
                seg.start, seg.end, language, seg.avg_logprob, seg.text.strip(),
            )
            all_text.append(seg.text.strip())

        text = " ".join(all_text)
        elapsed = time.perf_counter() - t0
        logger.info(
            "Transcribed %.1fs audio in %.2fs — lang=%s — %d chars",
            info.duration, elapsed, language, len(text),
        )
        return {"text": text, "language": language, "duration": round(info.duration, 2)}

    def _detect_language_local(self, audio) -> str:
        """Detect language from audio, restricted to ro/en."""
        detected, prob, all_probs = self._local_model.detect_language(audio)
        probs = dict(all_probs)
        ro_prob = probs.get("ro", 0)
        en_prob = probs.get("en", 0)
        lang = "en" if en_prob > ro_prob else "ro"
        logger.info(
            "Language detection: detected=%s(%.2f) → ro=%.2f en=%.2f → using %s",
            detected, prob, ro_prob, en_prob, lang,
        )
        return lang

    # ── LLM Processing ─────────────────────────────

    def _get_llm_client(self):
        """Get or create LLM client."""
        import openai
        base_urls = {
            "xai": "https://api.x.ai/v1",
            "groq": "https://api.groq.com/openai/v1",
            "openai": None,
        }
        return openai.OpenAI(
            api_key=self.llm_api_key,
            base_url=base_urls.get(self.llm_provider),
        )

    def _build_llm_prompt(
        self, source_lang: str, cleanup: bool, translate_to: Optional[str],
    ) -> str:
        """Build system prompt for LLM post-processing."""
        lang_names = {"ro": "Romanian", "en": "English", "de": "German",
                      "fr": "French", "es": "Spanish", "it": "Italian"}

        if cleanup and translate_to:
            tgt = lang_names.get(translate_to, translate_to)
            return (
                f"Fix any speech-to-text errors and translate to {tgt}. "
                f"Output ONLY the corrected translation."
            )
        elif cleanup:
            return (
                "Fix speech-to-text errors: grammar, punctuation, typos. "
                "Same language. Output ONLY the fixed text."
            )
        else:  # translate only
            tgt = lang_names.get(translate_to, translate_to)
            return (
                f"Translate to {tgt}. Preserve meaning exactly. "
                f"Output ONLY the translation."
            )

    def llm_process(
        self,
        text: str,
        source_lang: str = "auto",
        cleanup: bool = False,
        translate_to: Optional[str] = None,
    ) -> str:
        """Process text through LLM (cleanup and/or translate). Returns final text."""
        if not cleanup and not translate_to:
            return text
        if not self.llm_api_key:
            logger.warning("LLM_API_KEY not set, skipping post-processing")
            return text

        try:
            client = self._get_llm_client()
            system_prompt = self._build_llm_prompt(source_lang, cleanup, translate_to)

            input_words = len(text.split())
            max_tok = min(max(input_words * 4, 64), 512)

            t0 = time.perf_counter()
            response = client.chat.completions.create(
                model=self.llm_model,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": text},
                ],
                temperature=0.3,
                max_tokens=max_tok,
            )
            result = response.choices[0].message.content.strip()
            elapsed = time.perf_counter() - t0
            logger.info("LLM processed in %.2fs: %s → %s", elapsed, text[:80], result[:80])
            # Guard against empty LLM responses
            if not result:
                logger.warning("LLM returned empty response, keeping original text")
                return text
            return result
        except Exception as e:
            logger.exception("LLM processing failed, returning original text")
            return text

    def llm_process_stream(
        self,
        text: str,
        source_lang: str = "auto",
        cleanup: bool = False,
        translate_to: Optional[str] = None,
    ) -> Generator[str, None, None]:
        """Process text through LLM with streaming. Yields tokens as they generate."""
        if not cleanup and not translate_to:
            yield text
            return
        if not self.llm_api_key:
            logger.warning("LLM_API_KEY not set, skipping post-processing")
            yield text
            return

        try:
            client = self._get_llm_client()
            system_prompt = self._build_llm_prompt(source_lang, cleanup, translate_to)

            # Scale max_tokens to input length (dictation is short)
            input_words = len(text.split())
            max_tok = min(max(input_words * 4, 64), 512)

            t0 = time.perf_counter()
            stream = client.chat.completions.create(
                model=self.llm_model,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": text},
                ],
                temperature=0.3,
                max_tokens=max_tok,
                stream=True,
            )

            full_text = []
            for chunk in stream:
                delta = chunk.choices[0].delta.content if chunk.choices[0].delta.content else ""
                if delta:
                    full_text.append(delta)
                    yield delta

            elapsed = time.perf_counter() - t0
            result = "".join(full_text).strip()
            logger.info("LLM streamed in %.2fs: %s → %s", elapsed, text[:80], result[:80])
        except Exception as e:
            logger.exception("LLM streaming failed, returning original text")
            yield text

    # ── Full Pipeline ──────────────────────────────

    def process(
        self,
        audio_path: str,
        language: Optional[str] = None,
        cleanup: bool = False,
        translate_to: Optional[str] = None,
    ) -> dict:
        """Full pipeline: transcribe + optional cleanup + optional translate.

        Args:
            audio_path: Path to audio file
            language: Force language or None for auto-detect
            cleanup: Clean up transcription with LLM
            translate_to: Translate to this language, or None to skip

        Returns:
            {"text": str, "original": str, "language": str, "duration": float}
        """
        result = self.transcribe(audio_path, language)
        original = result["text"]

        if not original.strip():
            return {**result, "original": original}

        if cleanup or translate_to:
            result["text"] = self.llm_process(
                original, result["language"], cleanup, translate_to,
            )
            result["original"] = original

        return result

    def process_bytes(
        self,
        audio_bytes: bytes,
        format: str = "wav",
        language: Optional[str] = None,
        cleanup: bool = False,
        translate_to: Optional[str] = None,
    ) -> dict:
        """Full pipeline from audio bytes.

        Args:
            audio_bytes: Raw audio data
            format: Audio format extension
            language: Force language or None for auto-detect
            cleanup: Clean up transcription with LLM
            translate_to: Translate to this language, or None to skip

        Returns:
            {"text": str, "original": str, "language": str, "duration": float}
        """
        with tempfile.NamedTemporaryFile(suffix=f".{format}", delete=False) as tmp:
            tmp.write(audio_bytes)
            tmp.flush()
            tmp_path = tmp.name
        try:
            return self.process(tmp_path, language, cleanup, translate_to)
        finally:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

    def process_stream(
        self,
        audio_path: str,
        language: Optional[str] = None,
        cleanup: bool = False,
        translate_to: Optional[str] = None,
    ) -> Generator[str, None, None]:
        """Full pipeline with streaming LLM output.

        Transcribes first (non-streaming), then streams LLM tokens.
        If no LLM processing needed, yields the full text at once.

        Args:
            audio_path: Path to audio file
            language: Force language or None for auto-detect
            cleanup: Clean up transcription with LLM
            translate_to: Translate to this language, or None to skip

        Yields:
            Text tokens as they are generated
        """
        result = self.transcribe(audio_path, language)
        text = result["text"]

        if not text.strip():
            return

        if cleanup or translate_to:
            yield from self.llm_process_stream(text, result["language"], cleanup, translate_to)
        else:
            yield text
