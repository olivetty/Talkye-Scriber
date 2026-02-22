"""Talkye Sidecar — Audio: sounds, source detection, recording."""

import logging
import os
import signal
import subprocess
import threading
import time
from pathlib import Path

import config
from platform_utils import user_env, notify

logger = logging.getLogger(__name__)

# Voice sound themes live in sidecar/sounds/<theme>/start.wav, stop.wav
_VOICE_THEMES = {"alex", "luna"}
_SIDECAR_DIR = Path(__file__).resolve().parent


def generate_sounds():
    """Generate beep sounds for synthetic themes. Voice themes use pre-recorded files."""
    os.makedirs(config.SOUNDDIR, exist_ok=True)
    themes = {
        "subtle": {
            "start":    "synth 0.12 sine 880 vol 0.8",
            "stop":     "synth 0.12 sine 440 vol 0.8",
            "done":     "synth 0.08 sine 660 vol 0.6",
            "error":    "synth 0.25 sine 260 vol 0.6",
            "activate": "synth 0.15 sine 660 synth 0.15 sine 990 vol 0.8",
        },
    }
    for theme_name, sounds in themes.items():
        for name, effect in sounds.items():
            path = os.path.join(config.SOUNDDIR, f"{theme_name}_{name}.wav")
            if not os.path.isfile(path):
                try:
                    subprocess.run(
                        ["sox", "-n", "-r", "44100", path] + effect.split(),
                        capture_output=True, timeout=5,
                    )
                except Exception as e:
                    logger.warning("Failed to generate sound '%s/%s': %s", theme_name, name, e)


def play_sound(name: str):
    """Play a feedback sound in background (non-blocking). Respects SOUND_THEME."""
    if config.SOUND_THEME == "silent":
        return

    path = None
    if config.SOUND_THEME in _VOICE_THEMES:
        voice_map = {
            "start": "start", "activate": "start",
            "stop": "stop", "done": "stop", "command": "stop", "error": "stop",
        }
        mapped = voice_map.get(name, name)
        voice_file = _SIDECAR_DIR / "sounds" / config.SOUND_THEME / f"{mapped}.wav"
        if voice_file.is_file():
            path = str(voice_file)
        else:
            path = os.path.join(config.SOUNDDIR, f"subtle_{name}.wav")
    else:
        path = os.path.join(config.SOUNDDIR, f"{config.SOUND_THEME}_{name}.wav")
        if not os.path.isfile(path):
            path = os.path.join(config.SOUNDDIR, f"subtle_{name}.wav")

    if not path or not os.path.isfile(path):
        return
    try:
        env = user_env()
        if config.IS_MAC:
            subprocess.Popen(["afplay", path],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            subprocess.Popen(["paplay", path],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
    except Exception:
        pass


def find_audio_source():
    """Find best audio source. Priority: RNNoise filter > USB mic > any non-monitor source."""
    try:
        result = subprocess.run(
            ["pactl", "list", "sources", "short"],
            capture_output=True, text=True, timeout=5, env=user_env(),
        )
        candidates = []
        for line in result.stdout.strip().split("\n"):
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            name = parts[1]
            if ".monitor" in name:
                continue
            state = parts[-1].strip().upper() if len(parts) >= 5 else "UNKNOWN"
            candidates.append((name, state))

        if not candidates:
            return None

        if config.AUDIO_SOURCE_NAME:
            for name, state in candidates:
                if config.AUDIO_SOURCE_NAME.lower() in name.lower():
                    logger.info("Found audio source (filter match): %s (%s)", name, state)
                    return name
            logger.warning("No source matching '%s', falling back", config.AUDIO_SOURCE_NAME)

        priority = ["effect_output", "alsa_input", "bluez_input"]
        for prefix in priority:
            for name, state in candidates:
                if name.startswith(prefix):
                    logger.info("Found audio source (auto): %s (%s)", name, state)
                    return name

        name, state = candidates[0]
        logger.info("Found audio source (fallback): %s (%s)", name, state)
        return name
    except Exception as e:
        logger.warning("Failed to find audio source: %s", e)
    return None


def start_recording():
    """Start recording audio from microphone."""
    if config.busy:
        logger.info("Busy, ignoring")
        return

    for f in [config.AUDIOFILE, config.RAWFILE]:
        try:
            os.unlink(f)
        except OSError:
            pass

    env = user_env()

    if config.IS_MAC:
        config.rec_process = subprocess.Popen(
            ["rec", "-q", "-r", "16000", "-c", "1", "-b", "16", config.AUDIOFILE],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env,
        )
    else:
        source = find_audio_source()
        rec_args = ["parecord", "--format=s16le", "--rate=16000", "--channels=1",
                     "--raw", config.RAWFILE]
        if source:
            rec_args.insert(1, f"--device={source}")
        config.rec_process = subprocess.Popen(
            rec_args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env,
        )

    config.rec_start_time = time.monotonic()
    play_sound("start")
    logger.info("Recording started (PID %d)", config.rec_process.pid)


def stop_recording():
    """Stop recording and trigger transcription."""
    if config.rec_process is None:
        return

    elapsed = time.monotonic() - config.rec_start_time
    time.sleep(0.2)  # Brief pause to capture trailing speech

    config.rec_process.send_signal(signal.SIGINT)
    try:
        config.rec_process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        config.rec_process.kill()
    config.rec_process = None
    logger.info("Recording stopped (%.1fs)", elapsed)
    play_sound("stop")

    if elapsed < config.MIN_DURATION_SECS:
        notify("Too short, ignored")
        for f in [config.RAWFILE, config.AUDIOFILE]:
            try:
                os.unlink(f)
            except OSError:
                pass
        return

    if config.IS_LINUX and os.path.isfile(config.RAWFILE):
        try:
            subprocess.run(
                ["sox", "-r", "16000", "-e", "signed", "-b", "16", "-c", "1",
                 config.RAWFILE, config.AUDIOFILE],
                capture_output=True, timeout=5,
            )
            os.unlink(config.RAWFILE)
        except Exception as e:
            logger.error("Raw to WAV conversion failed: %s", e)
            return

    config.busy = True
    from transcribe import transcribe_and_paste
    threading.Thread(target=transcribe_and_paste, daemon=True).start()
