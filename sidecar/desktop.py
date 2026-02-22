"""Talkye Sidecar — Desktop dictation entry point.

Hold a trigger key to record, release to transcribe and paste at cursor.
Say a wake word to activate hands-free dictation via VAD.

Modules:
    config.py        — Shared configuration and mutable state
    platform_utils.py — OS helpers (paste, notify, xdotool)
    audio.py         — Sound generation, playback, recording
    commands.py      — Voice command detection and execution
    transcribe.py    — Groq STT, transcription pipeline
    keyboard.py      — evdev + pynput PTT listeners
    vad.py           — VAD listener with Rustpotter wake word

Usage:
    python desktop.py
"""

import logging
import sys

import config
from audio import generate_sounds, play_sound

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)


def main():
    config.load_flutter_settings()

    logger.info("Dictate desktop client starting (%s)", config.PLATFORM)
    logger.info("Input: %s | Mode: %s | Language: %s | Wake phrase: '%s' | Threshold: %.2f | STT: %s | Translate: %s",
                config.INPUT_MODE, config.core.mode, config.LANGUAGE, config.WAKE_PHRASE,
                config.WAKEWORD_THRESHOLD, config.STT_BACKEND, config.DICTATE_TRANSLATE)

    if config.LLM_CLEANUP or config.TRANSLATE_ENABLED:
        features = []
        if config.LLM_CLEANUP:
            features.append("cleanup")
        if config.TRANSLATE_ENABLED:
            features.append(f"translate→{config.TRANSLATE_TO}")
        logger.info("LLM streaming: %s (provider=%s, model=%s)",
                     "+".join(features), config.core.llm_provider, config.core.llm_model)

    generate_sounds()

    if config.INPUT_MODE == "vad":
        from vad import run_vad_listener
        run_vad_listener()
    elif config.IS_LINUX:
        try:
            import evdev  # noqa: F401
            devices = evdev.list_devices()
            if not devices:
                raise PermissionError("No input devices accessible")
            logger.info("Using evdev key capture")
            from keyboard import run_evdev_listener
            run_evdev_listener()
        except (ImportError, PermissionError, OSError) as e:
            logger.info("evdev not usable (%s), using pynput", e)
            from keyboard import run_pynput_listener
            run_pynput_listener()
    else:
        from keyboard import run_pynput_listener
        run_pynput_listener()


if __name__ == "__main__":
    main()
