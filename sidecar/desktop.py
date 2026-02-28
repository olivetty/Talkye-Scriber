"""Talkye Scriber Sidecar — Desktop dictation entry point.

Hold a trigger key to record, release to transcribe and paste at cursor.

Modules:
    config.py        — Shared configuration and mutable state
    platform_utils.py — OS helpers (paste, notify, xdotool)
    audio.py         — Sound generation, playback, recording
    commands.py      — Voice command detection and execution
    transcribe.py    — STT pipeline (local whisper.cpp + Groq fallback)
    keyboard.py      — evdev + pynput PTT listeners

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
    logger.info("Trigger: %s | STT: %s | Translate: %s | Grammar: %s",
                config.TRIGGER_KEY, config.STT_BACKEND,
                config.DICTATE_TRANSLATE, config.DICTATE_GRAMMAR)

    if config.LLM_CLEANUP or config.DICTATE_GRAMMAR or config.DICTATE_TRANSLATE:
        features = []
        if config.LLM_CLEANUP or config.DICTATE_GRAMMAR:
            features.append("grammar")
        if config.DICTATE_TRANSLATE:
            features.append("translate→en")
        logger.info("LLM post-processing: %s (provider=%s, model=%s)",
                     "+".join(features), config.core.llm_provider, config.core.llm_model)

    generate_sounds()

    if config.IS_LINUX:
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
