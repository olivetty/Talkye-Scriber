"""Talkye Sidecar — Voice Chat pipeline.

Full voice-to-voice loop:
  Mic → VAD → whisper.cpp STT → Groq LLM → pocket-tts TTS → Speaker

Runs as a background thread, communicates via callback events.
"""

import json
import logging
import os
import signal
import subprocess
import tempfile
import threading
import time
from typing import Callable, Optional

import webrtcvad

import config
from platform_utils import user_env
from audio import find_audio_source
from transcribe import local_transcribe
from tts import speak, is_available as tts_available

logger = logging.getLogger(__name__)

# VAD parameters for voice chat (tuned for conversation)
SAMPLE_RATE = 16000
FRAME_MS = 30
FRAME_BYTES = int(SAMPLE_RATE * FRAME_MS / 1000) * 2
SPEECH_FRAMES_START = 3       # ~90ms of speech to trigger
SILENCE_FRAMES_STOP = 33      # ~1s silence = end of utterance
MIN_SPEECH_FRAMES = 15        # ~450ms minimum speech
PRE_BUFFER_FRAMES = 10        # ~300ms pre-buffer
MAX_SEGMENT_FRAMES = 500      # ~15s max single utterance


class VoiceChat:
    """Voice chat session — manages the full voice-to-voice loop."""

    def __init__(self, on_event: Callable[[dict], None], model: str = "llama-3.3-70b-versatile"):
        """
        Args:
            on_event: Callback for events.
            model: Groq model ID.
        """
        self._on_event = on_event
        self._model = model
        self._language = "en"
        self._running = False
        self._thread: Optional[threading.Thread] = None
        self._mic_proc: Optional[subprocess.Popen] = None
        self._speaking = False  # True while TTS is playing
        self._history: list[dict] = []  # Chat history for LLM context

    @property
    def running(self) -> bool:
        return self._running

    def start(self):
        """Start the voice chat loop."""
        if self._running:
            return
        self._running = True
        self._history = []
        self._thread = threading.Thread(target=self._loop, daemon=True, name="voice-chat")
        self._thread.start()

    def stop(self):
        """Stop the voice chat loop."""
        self._running = False
        if self._mic_proc:
            try:
                self._mic_proc.kill()
            except Exception:
                pass
        self._emit({"type": "state", "state": "stopped"})

    def _emit(self, event: dict):
        try:
            self._on_event(event)
        except Exception as e:
            logger.warning("Event callback error: %s", e)

    def _loop(self):
        """Main voice chat loop."""
        vad = webrtcvad.Vad(2)  # Medium aggressiveness for conversation

        # Start mic
        source = find_audio_source()
        env = user_env()
        rec_args = ["parecord", "--format=s16le", "--rate=16000", "--channels=1",
                     "--raw", "--latency-msec=30", "/dev/stdout"]
        if source:
            rec_args.insert(1, f"--device={source}")

        try:
            self._mic_proc = subprocess.Popen(
                rec_args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env,
            )
        except Exception as e:
            self._emit({"type": "error", "message": f"Mic failed: {e}"})
            self._running = False
            return

        logger.info("Voice chat started (source=%s)", source or "default")
        self._emit({"type": "state", "state": "listening"})

        state = "SILENCE"
        speech_buf = bytearray()
        ring_buf = []
        speech_frames = 0
        silence_frames = 0
        consec_speech = 0

        try:
            while self._running:
                frame = self._mic_proc.stdout.read(FRAME_BYTES)
                if not frame or len(frame) < FRAME_BYTES:
                    break

                # Skip VAD while TTS is playing (avoid feedback loop)
                if self._speaking:
                    if state == "SPEECH":
                        state = "SILENCE"
                        speech_buf = bytearray()
                        consec_speech = 0
                        silence_frames = 0
                        ring_buf.clear()
                    continue

                is_speech = vad.is_speech(frame, SAMPLE_RATE)

                if state == "SILENCE":
                    ring_buf.append(frame)
                    if len(ring_buf) > PRE_BUFFER_FRAMES:
                        ring_buf.pop(0)
                    if is_speech:
                        consec_speech += 1
                        if consec_speech >= SPEECH_FRAMES_START:
                            state = "SPEECH"
                            speech_buf = bytearray()
                            for f in ring_buf:
                                speech_buf.extend(f)
                            speech_buf.extend(frame)
                            speech_frames = len(ring_buf) + 1
                            silence_frames = 0
                    else:
                        consec_speech = 0

                elif state == "SPEECH":
                    speech_buf.extend(frame)
                    speech_frames += 1

                    if speech_frames >= MAX_SEGMENT_FRAMES:
                        # Too long, process what we have
                        self._process_speech(bytes(speech_buf), speech_frames)
                        state = "SILENCE"
                        speech_buf = bytearray()
                        consec_speech = 0
                        silence_frames = 0
                        ring_buf.clear()
                        continue

                    if is_speech:
                        silence_frames = 0
                    else:
                        silence_frames += 1
                        if silence_frames >= SILENCE_FRAMES_STOP:
                            state = "SILENCE"
                            consec_speech = 0
                            ring_buf.clear()

                            if speech_frames >= MIN_SPEECH_FRAMES:
                                self._process_speech(bytes(speech_buf), speech_frames)
                            speech_buf = bytearray()

        except Exception as e:
            if self._running:
                logger.exception("Voice chat loop error: %s", e)
                self._emit({"type": "error", "message": str(e)})
        finally:
            if self._mic_proc:
                try:
                    self._mic_proc.kill()
                except Exception:
                    pass
            self._running = False
            self._emit({"type": "state", "state": "stopped"})
            logger.info("Voice chat stopped")

    def _process_speech(self, raw_audio: bytes, frame_count: int):
        """Process captured speech: STT → LLM → TTS."""
        duration = frame_count * FRAME_MS / 1000
        logger.info("Voice chat: processing speech (%.1fs)", duration)
        self._emit({"type": "state", "state": "processing"})

        # 1. Save raw audio to WAV
        raw_path = tempfile.mktemp(suffix=".raw")
        wav_path = tempfile.mktemp(suffix=".wav")
        try:
            with open(raw_path, "wb") as f:
                f.write(raw_audio)
            subprocess.run(
                ["sox", "-r", "16000", "-e", "signed", "-b", "16", "-c", "1",
                 raw_path, wav_path],
                capture_output=True, timeout=5,
            )
            os.unlink(raw_path)
        except Exception as e:
            logger.error("Audio conversion failed: %s", e)
            self._emit({"type": "state", "state": "listening"})
            return

        # 2. STT — transcribe with whisper.cpp
        try:
            result = local_transcribe(wav_path)
            text = result.get("text", "").strip()
        except Exception as e:
            logger.error("STT failed: %s", e)
            text = ""
        finally:
            try:
                os.unlink(wav_path)
            except OSError:
                pass

        if not text:
            logger.info("Voice chat: no speech detected")
            self._emit({"type": "state", "state": "listening"})
            return

        logger.info("Voice chat user: %s", text)
        self._emit({"type": "user_text", "text": text})

        # Add to history
        self._history.append({"role": "user", "content": text})

        # 3. LLM — generate response via Groq cloud
        try:
            system = (
                "You are a voice assistant. You MUST always reply in English, "
                "regardless of what language the user speaks. "
                "Keep it short: 1-3 sentences. No markdown. Plain text only."
            )
            hist = [m for m in self._history[-10:] if m is not self._history[-1]]

            response_text = ""
            token_count = 0

            # Pipelined sentence-streaming TTS:
            # - Sentences are synthesized in parallel (up to 2 concurrent)
            # - Playback uses a single persistent paplay process for zero-gap audio
            # - First sentence starts playing as soon as it's synthesized
            import queue as _queue
            import wave
            from concurrent.futures import ThreadPoolExecutor, Future

            play_queue = _queue.Queue()    # WAV paths ready to play, in order
            tts_done = threading.Event()
            sentence_buf = ""
            first_sentence_queued = False
            pending_futures: list[Future] = []  # ordered synthesis futures

            synth_pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="vc-synth")

            def _synth_one(text_to_synth: str) -> str | None:
                """Synthesize a single sentence, return WAV path or None."""
                from tts import synthesize
                meta = synthesize(text_to_synth)
                return meta["path"] if meta else None

            def _play_worker():
                """Play WAV files through a single persistent paplay process."""
                env = user_env()
                paplay = None
                try:
                    while True:
                        item = play_queue.get()
                        if item is None:
                            break
                        wav_path = item
                        try:
                            with wave.open(wav_path, 'rb') as wf:
                                sr = wf.getframerate()
                                ch = wf.getnchannels()
                                sw = wf.getsampwidth()
                                pcm = wf.readframes(wf.getnframes())
                            if paplay is None or paplay.poll() is not None:
                                fmt = "s16le" if sw == 2 else "s32le"
                                paplay = subprocess.Popen(
                                    ["paplay", f"--format={fmt}",
                                     f"--rate={sr}", f"--channels={ch}", "--raw"],
                                    stdin=subprocess.PIPE,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                    env=env,
                                )
                            paplay.stdin.write(pcm)
                            paplay.stdin.flush()
                        except Exception as e:
                            logger.error("TTS play failed: %s", e)
                            paplay = None
                        finally:
                            try:
                                os.unlink(wav_path)
                            except OSError:
                                pass
                finally:
                    if paplay and paplay.stdin:
                        try:
                            paplay.stdin.close()
                            paplay.wait(timeout=30)
                        except Exception:
                            pass
                    tts_done.set()

            play_t = threading.Thread(target=_play_worker, daemon=True, name="vc-play")
            play_t.start()

            def _flush_sentence():
                nonlocal sentence_buf, first_sentence_queued
                s = sentence_buf.strip()
                if s:
                    if not first_sentence_queued:
                        first_sentence_queued = True
                        self._speaking = True
                        self._emit({"type": "state", "state": "speaking"})
                    logger.info("Voice chat TTS queue: '%s'", s[:60])
                    # Submit for parallel synthesis
                    fut = synth_pool.submit(_synth_one, s)
                    pending_futures.append(fut)
                    sentence_buf = ""

            def _drain_ready_futures():
                """Feed completed futures to play queue in order."""
                while pending_futures and pending_futures[0].done():
                    fut = pending_futures.pop(0)
                    try:
                        path = fut.result()
                        if path:
                            play_queue.put(path)
                    except Exception as e:
                        logger.error("TTS synth error: %s", e)

            # Groq cloud model
            from llm_groq import groq_chat_stream
            for token in groq_chat_stream(
                user_message=text,
                model=self._model,
                system_prompt=system,
                history=hist,
                max_tokens=256,
                temperature=0.7,
                enable_thinking=False,
            ):
                response_text += token
                token_count += 1
                self._emit({"type": "assistant_text", "text": response_text, "done": False})

                # Accumulate and split on sentence boundaries
                sentence_buf += token
                if any(sentence_buf.rstrip().endswith(p) for p in ('.', '!', '?', '。', '！', '？')):
                    _flush_sentence()

                # Feed any ready WAVs to player while LLM streams
                _drain_ready_futures()

            response_text = response_text.strip()
            logger.info("Voice chat LLM (%s): %d tokens, response='%s'",
                        self._model, token_count, response_text[:100])
            if not response_text:
                response_text = "I didn't catch that."

        except Exception as e:
            logger.error("LLM failed: %s", e)
            response_text = "Sorry, I had an error."

        # Strip any leaked <think> tags before TTS
        import re
        response_text = re.sub(r"<think>.*?</think>", "", response_text, flags=re.DOTALL)
        response_text = re.sub(r"</?think>", "", response_text).strip()
        if not response_text:
            response_text = "I didn't catch that."

        logger.info("Voice chat assistant: %s", response_text)
        self._emit({"type": "assistant_text", "text": response_text, "done": True})
        self._history.append({"role": "assistant", "content": response_text})

        # Flush any remaining text in sentence buffer
        _flush_sentence()
        # If nothing was queued at all (empty response), speak fallback
        if not first_sentence_queued:
            self._speaking = True
            self._emit({"type": "state", "state": "speaking"})
            fut = synth_pool.submit(_synth_one, response_text)
            pending_futures.append(fut)

        # Wait for all synthesis to complete and feed to player in order
        for fut in pending_futures:
            try:
                path = fut.result(timeout=30)
                if path:
                    play_queue.put(path)
            except Exception as e:
                logger.error("TTS synth error: %s", e)
        pending_futures.clear()
        synth_pool.shutdown(wait=False)

        # Signal player to finish and wait for playback to drain
        play_queue.put(None)
        tts_done.wait(timeout=60)

        # Trim history to last 20 messages
        if len(self._history) > 20:
            self._history = self._history[-20:]

        # TTS already handled by sentence streamer above
        self._speaking = False
        if self._running:
            self._emit({"type": "state", "state": "listening"})
