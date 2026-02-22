"""Talkye Sidecar — VAD listener with Rustpotter wake word detection.

Always-on voice detection: Rustpotter detects wake phrase at audio level,
then webrtcvad captures speech segments for transcription.
"""

import json as _json
import logging
import os
import subprocess
import threading
import time

import config
from platform_utils import user_env, release_modifiers, xdotool_prefix
from audio import find_audio_source, play_sound
from transcribe import groq_transcribe, local_transcribe, transcribe_and_paste

logger = logging.getLogger(__name__)


def run_vad_listener():
    """Main VAD loop: Rustpotter wake word + webrtcvad speech detection."""
    import webrtcvad

    vad = webrtcvad.Vad(3)

    # ── Rustpotter wake word subprocess ──
    wakeword_rpw = os.path.join(
        os.getenv("HOME", "/tmp"), ".config", "talkye", "wakeword.rpw"
    )
    wakeword_bin = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "wakeword", "target", "release", "wakeword"
    )
    wakeword_threshold = str(config.WAKEWORD_THRESHOLD)
    wakeword_proc = None

    if os.path.isfile(wakeword_rpw) and os.path.isfile(wakeword_bin):
        env = user_env()
        wakeword_proc = subprocess.Popen(
            [wakeword_bin, "spot", wakeword_rpw, wakeword_threshold],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env,
        )
        logger.info("Rustpotter started (rpw=%s, threshold=%s)", wakeword_rpw, wakeword_threshold)
        try:
            ready_line = wakeword_proc.stdout.readline().decode().strip()
            if ready_line:
                ready = _json.loads(ready_line)
                logger.info("Rustpotter ready: frame=%dB, threshold=%s",
                           ready.get("frame_bytes", 0), ready.get("threshold", "?"))
        except Exception as e:
            logger.warning("Rustpotter ready read failed: %s", e)
    else:
        if not os.path.isfile(wakeword_rpw):
            logger.warning("No wake word trained (%s). Train one in the app.", wakeword_rpw)
        if not os.path.isfile(wakeword_bin):
            logger.warning("Wakeword binary not found: %s", wakeword_bin)

    def _rustpotter_reader():
        if wakeword_proc is None:
            return
        try:
            for line in wakeword_proc.stdout:
                text = line.decode().strip()
                if not text:
                    continue
                try:
                    evt = _json.loads(text)
                    if evt.get("event") == "detected":
                        score = evt.get("score", 0)
                        name = evt.get("name", "?")
                        if config.training:
                            logger.debug("Wake word ignored (training mode): score=%.3f", score)
                            continue
                        if time.monotonic() < config.vad_cooldown_until:
                            logger.debug("Wake word ignored (cooldown): score=%.3f", score)
                            continue
                        already_active = time.monotonic() < config.vad_active_until
                        logger.info("🎤 Wake word '%s' detected (score=%.3f)%s",
                                    name, score, " [refresh]" if already_active else "")
                        if not already_active:
                            play_sound("activate")
                        config.set_vad_active()
                except _json.JSONDecodeError:
                    pass
        except Exception as e:
            logger.warning("Rustpotter reader stopped: %s", e)

    if wakeword_proc is not None:
        threading.Thread(target=_rustpotter_reader, daemon=True, name="rustpotter").start()

    # ── VAD speech detection (separate mic stream) ──
    SAMPLE_RATE = 16000
    FRAME_MS = 30
    FRAME_BYTES = int(SAMPLE_RATE * FRAME_MS / 1000) * 2

    SPEECH_FRAMES_START = 3
    SILENCE_FRAMES_STOP = max(1, config.SILENCE_STANDBY_MS // FRAME_MS)
    SILENCE_FRAMES_ACTIVE = max(1, config.SILENCE_ACTIVE_MS // FRAME_MS)
    MIN_SPEECH_FRAMES = 15
    PRE_BUFFER_FRAMES = 10
    MAX_SEGMENT_FRAMES = 1000

    source = find_audio_source()
    env = user_env()

    rec_args = ["parecord", "--format=s16le", "--rate=16000", "--channels=1",
                "--raw", "--latency-msec=30", "/dev/stdout"]
    if source:
        rec_args.insert(1, f"--device={source}")

    mic = subprocess.Popen(rec_args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
    logger.info("VAD listener started (source=%s). Wake word: %s",
                source or "default",
                "Rustpotter active" if wakeword_proc else "disabled (not trained)")

    state = "SILENCE"
    speech_buf = bytearray()
    ring_buf = []
    speech_frames = 0
    silence_frames = 0
    consec_speech = 0
    was_active = False

    from concurrent.futures import ThreadPoolExecutor, Future
    spec_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="spec")
    spec_future: Future | None = None
    spec_buf_len = 0

    def _spec_transcribe(raw_audio: bytes) -> dict | None:
        import tempfile as _tf
        raw_path = _tf.mktemp(suffix=".raw")
        wav_path = _tf.mktemp(suffix=".wav")
        try:
            with open(raw_path, "wb") as f:
                f.write(raw_audio)
            subprocess.run(
                ["sox", "-r", "16000", "-e", "signed", "-b", "16", "-c", "1", raw_path, wav_path],
                capture_output=True, timeout=5,
            )
            os.unlink(raw_path)
            is_active = time.monotonic() < config.vad_active_until
            vad_lang = (config.LANGUAGE if config.LANGUAGE != "auto" else None) if is_active else None
            if config.STT_BACKEND == "local":
                result = local_transcribe(wav_path, vad_lang)
            else:
                result = groq_transcribe(wav_path, vad_lang)
            os.unlink(wav_path)
            return result
        except Exception as e:
            logger.warning("Speculative transcription failed: %s", e)
            for p in [raw_path, wav_path]:
                try: os.unlink(p)
                except OSError: pass
            return None

    try:
        while True:
            frame = mic.stdout.read(FRAME_BYTES)
            if not frame or len(frame) < FRAME_BYTES:
                logger.error("VAD: mic stream ended unexpectedly")
                break

            is_active_now = time.monotonic() < config.vad_active_until
            if was_active and not is_active_now:
                if config.vad_silent_end:
                    logger.info("VAD: session ended silently (command)")
                    config.vad_silent_end = False
                else:
                    logger.info("VAD: session ended → STANDBY")
                    play_sound("stop")
                if config.VAD_AUTO_ENTER:
                    release_modifiers()
                    env = user_env()
                    prefix = xdotool_prefix()
                    subprocess.run(
                        prefix + ["xdotool", "key", "--clearmodifiers", "Return"],
                        timeout=5, env=env, capture_output=True,
                    )
            was_active = is_active_now

            if config.busy:
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
                        logger.info("VAD: speech detected")
                else:
                    consec_speech = 0

            elif state == "SPEECH":
                speech_buf.extend(frame)
                speech_frames += 1

                if speech_frames >= MAX_SEGMENT_FRAMES:
                    duration = speech_frames * FRAME_MS / 1000
                    is_active_now = time.monotonic() < config.vad_active_until
                    if is_active_now:
                        # Flush: transcribe what we have and keep listening
                        logger.info("VAD: segment flush (%.1fs) — auto-split", duration)
                        if spec_future is not None:
                            spec_future.cancel()
                            spec_future = None
                            spec_buf_len = 0
                        with open(config.RAWFILE, "wb") as f:
                            f.write(speech_buf)
                        try:
                            subprocess.run(
                                ["sox", "-r", "16000", "-e", "signed", "-b", "16",
                                 "-c", "1", config.RAWFILE, config.AUDIOFILE],
                                capture_output=True, timeout=5,
                            )
                            os.unlink(config.RAWFILE)
                        except Exception as e:
                            logger.error("Raw→WAV failed: %s", e)
                        config.busy = True
                        threading.Thread(target=transcribe_and_paste, daemon=True).start()
                        config.set_vad_active()
                    else:
                        logger.warning("VAD: segment too long (%.1fs), discarding (standby)", duration)
                    state = "SILENCE"
                    speech_buf = bytearray()
                    consec_speech = 0
                    silence_frames = 0
                    ring_buf.clear()
                    continue

                if is_speech:
                    silence_frames = 0
                    if spec_future is not None:
                        spec_future.cancel()
                        spec_future = None
                        spec_buf_len = 0
                    if time.monotonic() < config.vad_active_until:
                        config.set_vad_active()
                else:
                    silence_frames += 1
                    is_active_now = time.monotonic() < config.vad_active_until
                    threshold = SILENCE_FRAMES_ACTIVE if is_active_now else SILENCE_FRAMES_STOP

                    spec_trigger = threshold // 2
                    if (silence_frames == spec_trigger and spec_future is None
                            and speech_frames >= MIN_SPEECH_FRAMES and is_active_now):
                        spec_buf_len = len(speech_buf)
                        spec_future = spec_executor.submit(_spec_transcribe, bytes(speech_buf))

                    if silence_frames >= threshold:
                        state = "SILENCE"
                        consec_speech = 0
                        ring_buf.clear()
                        duration = speech_frames * FRAME_MS / 1000
                        is_active_now = time.monotonic() < config.vad_active_until

                        if speech_frames >= MIN_SPEECH_FRAMES and is_active_now:
                            config.set_vad_active()
                            if spec_future is not None and not spec_future.cancelled():
                                try:
                                    result = spec_future.result(timeout=5)
                                    spec_future = None
                                    spec_buf_len = 0
                                    if result:
                                        logger.info("VAD: speech ended (%.1fs) — speculative", duration)
                                        text = result.get("text", "").strip()
                                        if text:
                                            with open(config.RAWFILE, "wb") as f:
                                                f.write(speech_buf)
                                            subprocess.run(
                                                ["sox", "-r", "16000", "-e", "signed", "-b", "16",
                                                 "-c", "1", config.RAWFILE, config.AUDIOFILE],
                                                capture_output=True, timeout=5,
                                            )
                                            try: os.unlink(config.RAWFILE)
                                            except OSError: pass
                                            config.busy = True
                                            threading.Thread(
                                                target=transcribe_and_paste,
                                                args=(result,), daemon=True,
                                            ).start()
                                            speech_buf = bytearray()
                                            continue
                                except Exception:
                                    pass

                            spec_future = None
                            spec_buf_len = 0
                            logger.info("VAD: speech ended (%.1fs) — processing", duration)
                            with open(config.RAWFILE, "wb") as f:
                                f.write(speech_buf)
                            try:
                                subprocess.run(
                                    ["sox", "-r", "16000", "-e", "signed", "-b", "16",
                                     "-c", "1", config.RAWFILE, config.AUDIOFILE],
                                    capture_output=True, timeout=5,
                                )
                                os.unlink(config.RAWFILE)
                            except Exception as e:
                                logger.error("Raw→WAV failed: %s", e)
                                speech_buf = bytearray()
                                continue
                            config.busy = True
                            threading.Thread(target=transcribe_and_paste, daemon=True).start()
                        elif speech_frames >= MIN_SPEECH_FRAMES:
                            logger.debug("VAD: standby, speech ignored (%.1fs)", duration)
                        else:
                            logger.debug("VAD: too short (%.1fs), ignored", duration)

                        spec_future = None
                        spec_buf_len = 0
                        speech_buf = bytearray()

    except KeyboardInterrupt:
        logger.info("Shutting down")
    finally:
        mic.kill()
        if wakeword_proc is not None:
            wakeword_proc.kill()
