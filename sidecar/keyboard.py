"""Talkye Sidecar — Keyboard listeners (evdev + pynput)."""

import logging
import sys
import time

import config
from audio import start_recording, stop_recording

logger = logging.getLogger(__name__)


def run_evdev_listener():
    """Push-to-talk via evdev (Linux, needs group 'input')."""
    import evdev
    from evdev import ecodes

    trigger_code = getattr(ecodes, config.TRIGGER_KEY, ecodes.KEY_RIGHTCTRL)

    MOUSE_NAMES = {"mouse", "logitech mx", "trackpad", "touchpad"}
    SKIP_NAMES = {"power button", "webcam", "hdmi", "hd-audio", "avrcp",
                  "headphone", "line out", "front mic", "rear mic"}

    def find_keyboard():
        for path in evdev.list_devices():
            try:
                dev = evdev.InputDevice(path)
                caps = dev.capabilities(verbose=False)
                keys = caps.get(ecodes.EV_KEY, [])
                if trigger_code not in keys:
                    continue
                name_lower = dev.name.lower()
                if any(s in name_lower for s in SKIP_NAMES):
                    continue
                if config.KEYBOARD_NAME and config.KEYBOARD_NAME.lower() in name_lower:
                    logger.info("Found keyboard (name match): %s (%s)", dev.name, dev.path)
                    return dev
                has_letters = sum(1 for k in keys if ecodes.KEY_A <= k <= ecodes.KEY_Z) >= 10
                is_mouse = any(s in name_lower for s in MOUSE_NAMES)
                if has_letters and not is_mouse:
                    logger.info("Found keyboard (auto): %s (%s)", dev.name, dev.path)
                    return dev
            except Exception:
                continue
        return None

    dev = None
    for attempt in range(30):
        dev = find_keyboard()
        if dev:
            break
        logger.info("Keyboard not found, retrying in 2s... (%d/30)", attempt + 1)
        time.sleep(2)

    if not dev:
        logger.error("No keyboard found after 30 attempts")
        sys.exit(1)

    logger.info("Listening on: %s (%s)", dev.path, dev.name)
    logger.info("Hold %s to talk.", config.TRIGGER_KEY)

    recording = False
    try:
        for event in dev.read_loop():
            if event.type != ecodes.EV_KEY:
                continue
            current_code = getattr(ecodes, config.TRIGGER_KEY, ecodes.KEY_RIGHTCTRL)
            if event.code != current_code:
                continue
            if event.value == 1 and not recording:
                recording = True
                start_recording()
            elif event.value == 0 and recording:
                recording = False
                stop_recording()
    except KeyboardInterrupt:
        logger.info("Shutting down")
    except OSError as e:
        logger.error("Device error: %s — restarting", e)
        sys.exit(1)
    finally:
        if config.rec_process:
            stop_recording()


def run_pynput_listener():
    """Push-to-talk via pynput (macOS / Linux fallback)."""
    from pynput import keyboard

    _pynput_map = {
        "KEY_RIGHTCTRL": keyboard.Key.ctrl_r, "KEY_LEFTCTRL": keyboard.Key.ctrl_l,
        "KEY_RIGHTALT": keyboard.Key.alt_r, "KEY_LEFTALT": keyboard.Key.alt_l,
        "KEY_RIGHTSHIFT": keyboard.Key.shift_r, "KEY_LEFTSHIFT": keyboard.Key.shift_l,
        "KEY_CAPSLOCK": keyboard.Key.caps_lock,
        "KEY_INSERT": keyboard.Key.insert,
        "KEY_SCROLLLOCK": keyboard.Key.scroll_lock,
        "KEY_PAUSE": keyboard.Key.pause,
        "KEY_NUMLOCK": keyboard.Key.num_lock,
        "ctrl_r": keyboard.Key.ctrl_r, "ctrl_l": keyboard.Key.ctrl_l,
        "alt_r": keyboard.Key.alt_r, "alt_l": keyboard.Key.alt_l,
        "shift_r": keyboard.Key.shift_r, "shift_l": keyboard.Key.shift_l,
        "cmd": keyboard.Key.cmd, "cmd_r": keyboard.Key.cmd_r,
    }
    for i in range(1, 25):
        evdev_name = f"KEY_F{i}"
        try:
            _pynput_map[evdev_name] = keyboard.KeyCode.from_vk(111 + i) if i <= 12 else keyboard.KeyCode.from_vk(182 + i)
        except Exception:
            pass

    def _resolve_trigger():
        return _pynput_map.get(config.TRIGGER_KEY)

    trigger_key = _resolve_trigger()
    if trigger_key is None:
        logger.error("Unknown trigger key: %s", config.TRIGGER_KEY)
        sys.exit(1)

    logger.info("Hold %s to talk.", config.TRIGGER_KEY)
    recording = False

    def on_press(key):
        nonlocal recording
        current = _resolve_trigger()
        if not recording and key == current:
            recording = True
            start_recording()

    def on_release(key):
        nonlocal recording
        current = _resolve_trigger()
        if key == current and recording:
            recording = False
            stop_recording()

    with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
        listener.join()
