"""Push-to-talk desktop client — Linux & macOS.

Hold a trigger key to record, release to transcribe and paste at cursor.
Short utterances matching voice commands are executed as keyboard actions.
Uses DictateCore for transcription and LLM processing.

Linux:  evdev for key capture, parecord for audio, xclip+xdotool for paste
macOS:  pynput for key capture, sox for audio, pbcopy+osascript for paste

Usage:
    # Linux (needs root for evdev)
    sudo ./venv/bin/python desktop.py

    # macOS (needs Accessibility permission)
    ./venv/bin/python desktop.py
"""

import logging
import os
import platform
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).parent / ".env")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger(__name__)

from core import DictateCore

PLATFORM = platform.system()
IS_LINUX = PLATFORM == "Linux"
IS_MAC = PLATFORM == "Darwin"

# Config from env
LANGUAGE = os.getenv("DICTATE_LANGUAGE", "auto")
LLM_CLEANUP = os.getenv("LLM_CLEANUP", "false").lower() == "true"
TRANSLATE_ENABLED = os.getenv("TRANSLATE_ENABLED", "false").lower() == "true"
TRANSLATE_TO = os.getenv("TRANSLATE_TO", "en")
MAGIC_WORD = os.getenv("DICTATE_MAGIC_WORD", "comandă").lower()
INPUT_MODE = os.getenv("DICTATE_INPUT", "ptt").lower()  # ptt | vad

AUDIOFILE = os.path.join(tempfile.gettempdir(), "dictate_p2t.wav")
RAWFILE = os.path.join(tempfile.gettempdir(), "dictate_p2t.raw")
SOUNDDIR = os.path.join(tempfile.gettempdir(), "dictate_sounds")
MIN_DURATION_SECS = 0.5
MAX_COMMAND_WORDS = 5  # utterances with <= this many words are checked as commands

# Linux-specific
KEYBOARD_NAME = os.getenv("DICTATE_KEYBOARD_NAME", "")
AUDIO_SOURCE_NAME = os.getenv("DICTATE_SOURCE_NAME", "")

# User env (for Linux sudo context)
REAL_USER = os.getenv("SUDO_USER", os.getenv("USER", ""))
REAL_UID = os.getenv("SUDO_UID", str(os.getuid()))
REAL_HOME = f"/home/{REAL_USER}" if IS_LINUX and os.getenv("SUDO_USER") else os.getenv("HOME", "")
DISPLAY = os.getenv("DISPLAY", ":0")
XDG_RUNTIME = os.getenv("XDG_RUNTIME_DIR", f"/run/user/{REAL_UID}" if IS_LINUX else "")

rec_process = None
rec_start_time = 0.0
busy = False
vad_active_until = 0.0  # timestamp — if > now, VAD is in ACTIVE state
VAD_ACTIVE_TIMEOUT = int(os.getenv("VAD_ACTIVE_TIMEOUT", "8"))
SILENCE_ACTIVE_MS = int(os.getenv("VAD_SILENCE_ACTIVE_MS", "1000"))
SILENCE_STANDBY_MS = int(os.getenv("VAD_SILENCE_STANDBY_MS", "900"))
VAD_AUTO_ENTER = os.getenv("VAD_AUTO_ENTER", "true").lower() == "true"


def _set_vad_active():
    """Set VAD to active state (processes speech without wake word)."""
    global vad_active_until
    vad_active_until = time.monotonic() + VAD_ACTIVE_TIMEOUT

# Initialize core
core = DictateCore()


# ── Sound feedback ─────────────────────────────────

def _generate_sounds():
    """Generate feedback sounds using sox. Called once at startup."""
    os.makedirs(SOUNDDIR, exist_ok=True)
    sounds = {
        "start":    "synth 0.12 sine 880 vol 0.4",
        "stop":     "synth 0.12 sine 440 vol 0.4",
        "done":     "synth 0.08 sine 660 vol 0.3",
        "command":  "synth 0.08 sine 1100 pad 0 0.04 synth 0.08 sine 1100 vol 0.4",
        "error":    "synth 0.25 sine 260 vol 0.3",
        "activate": "synth 0.15 sine 660 synth 0.15 sine 990 vol 0.5",
    }
    for name, effect in sounds.items():
        path = os.path.join(SOUNDDIR, f"{name}.wav")
        if not os.path.isfile(path):
            try:
                subprocess.run(
                    ["sox", "-n", "-r", "44100", path] + effect.split(),
                    capture_output=True, timeout=5,
                )
            except Exception as e:
                logger.warning("Failed to generate sound '%s': %s", name, e)


def play_sound(name: str):
    """Play a feedback sound in background (non-blocking)."""
    path = os.path.join(SOUNDDIR, f"{name}.wav")
    if not os.path.isfile(path):
        return
    try:
        env = _user_env()
        if IS_MAC:
            subprocess.Popen(["afplay", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            subprocess.Popen(
                ["paplay", path],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env,
            )
    except Exception:
        pass


# ── Magic word variants ────────────────────────────

_magic_variants = [MAGIC_WORD]  # populated at startup

# Groq client for wake word detection (auto-detect language)
_groq_client = None

def _groq_transcribe(audio_path: str, language: str = None) -> dict:
    """Transcribe via Groq API with prompt hint for wake word."""
    global _groq_client
    try:
        if _groq_client is None:
            import openai
            key = os.getenv("GROQ_API_KEY", "")
            if not key:
                logger.warning("GROQ_API_KEY not set, falling back to core.transcribe")
                return core.transcribe(audio_path, None)
            _groq_client = openai.OpenAI(api_key=key, base_url="https://api.groq.com/openai/v1")

        # Prompt hint guides Whisper to recognize the wake phrase correctly
        prompt_hint = f'"{MAGIC_WORD.title()}." '

        kwargs = {
            "model": "whisper-large-v3",
            "file": open(audio_path, "rb"),
            "response_format": "verbose_json",
            "prompt": prompt_hint,
        }
        if language:
            kwargs["language"] = language

        resp = _groq_client.audio.transcriptions.create(**kwargs)
        kwargs["file"].close()
        text = (resp.text or "").strip()
        lang = getattr(resp, "language", "?")
        logger.info("Groq transcription [%s]: %s", lang, text)
        return {"text": text, "language": lang, "duration": getattr(resp, "duration", 0) or 0}
    except Exception as e:
        logger.warning("Groq transcription failed: %s, falling back", e)
        return core.transcribe(audio_path, None)


def _generate_magic_variants():
    """Use LLM to generate phonetic variants of the magic phrase at startup."""
    global _magic_variants
    _magic_variants = [MAGIC_WORD]

    # Always include common Whisper mishearings of the wake phrase
    _hardcoded_fallbacks = ["hey kiddo", "hey kido", "hei kiddo", "hey jarvis", "hei jarvis"]
    if MAGIC_WORD not in ("comanda", "comandă", "command"):
        _magic_variants.extend(["comanda", "command"])
    for fb in _hardcoded_fallbacks:
        if fb != MAGIC_WORD and fb not in _magic_variants:
            _magic_variants.append(fb)

    try:
        client = core._get_llm_client()
        resp = client.chat.completions.create(
            model=core.llm_model,
            messages=[{"role": "user", "content": (
                f'The wake phrase is "{MAGIC_WORD}". '
                f"A speech-to-text system often mishears it. "
                f"Generate 15 phonetic misspellings/mishearings in various languages "
                f"(e.g. homophones, accent variations, transliterations). "
                f"Return ONLY a comma-separated list, lowercase, nothing else."
            )}],
            max_tokens=150,
            temperature=0.7,
        )
        raw = resp.choices[0].message.content.strip()
        variants = [v.strip().strip('"').lower() for v in raw.split(",") if v.strip()]
        _magic_variants.extend(variants)
        # Sort longest first so "hey kiro" matches before "hey"
        _magic_variants.sort(key=len, reverse=True)
        # Deduplicate preserving order
        seen = set()
        deduped = []
        for v in _magic_variants:
            if v not in seen:
                seen.add(v)
                deduped.append(v)
        _magic_variants = deduped
        logger.info("Magic variants (%d): %s", len(_magic_variants), _magic_variants[:10])
    except Exception as e:
        logger.warning("Failed to generate magic variants: %s", e)


# ── Platform helpers ───────────────────────────────

def _user_env():
    env = os.environ.copy()
    if IS_LINUX and os.getenv("SUDO_USER"):
        env["HOME"] = REAL_HOME
        env["DISPLAY"] = DISPLAY
        if XDG_RUNTIME:
            env["XDG_RUNTIME_DIR"] = XDG_RUNTIME
            env["PULSE_SERVER"] = f"unix:{XDG_RUNTIME}/pulse/native"
    return env


def notify(msg: str):
    try:
        if IS_MAC:
            subprocess.Popen(
                ["osascript", "-e", f'display notification "{msg}" with title "Dictate"'],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        elif IS_LINUX and os.getenv("SUDO_USER"):
            subprocess.Popen(
                ["sudo", "-u", REAL_USER, "notify-send", "-t", "2000", "Dictate", msg],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=_user_env(),
            )
        else:
            subprocess.Popen(
                ["notify-send", "-t", "2000", "Dictate", msg],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=_user_env(),
            )
    except FileNotFoundError:
        pass


def _xdotool_prefix():
    """Return sudo prefix for xdotool/xclip commands."""
    if os.getenv("SUDO_USER"):
        return ["sudo", "-u", REAL_USER, "env",
                f"DISPLAY={DISPLAY}", f"XAUTHORITY={REAL_HOME}/.Xauthority"]
    return []


def _release_modifiers():
    """Force-release all modifier keys to prevent ghost state."""
    if IS_MAC:
        return
    env = _user_env()
    subprocess.run(
        _xdotool_prefix() + ["xdotool", "keyup", "alt", "Alt_L", "Alt_R",
                              "ctrl", "Control_L", "Control_R",
                              "shift", "Shift_L", "Shift_R",
                              "super", "Super_L", "Super_R"],
        timeout=5, env=env, capture_output=True,
    )


def paste_text(text: str):
    env = _user_env()
    if IS_MAC:
        proc = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE, env=env)
        proc.communicate(input=text.encode("utf-8"), timeout=5)
        time.sleep(0.1)
        subprocess.run(
            ["osascript", "-e", 'tell application "System Events" to keystroke "v" using command down'],
            timeout=5, env=env,
        )
    else:
        prefix = _xdotool_prefix()
        proc = subprocess.Popen(
            prefix + ["xclip", "-selection", "clipboard"],
            stdin=subprocess.PIPE, env=env,
        )
        proc.communicate(input=text.encode("utf-8"), timeout=5)
        time.sleep(0.1)
        _release_modifiers()
        subprocess.run(
            prefix + ["xdotool", "key", "--clearmodifiers", "ctrl+v"],
            timeout=5, env=env,
        )


def _type_chunk(text: str):
    env = _user_env()
    if IS_MAC:
        escaped = text.replace("\\", "\\\\").replace('"', '\\"')
        subprocess.run(
            ["osascript", "-e", f'tell application "System Events" to keystroke "{escaped}"'],
            timeout=5, env=env,
        )
    else:
        subprocess.run(
            _xdotool_prefix() + ["xdotool", "type", "--clearmodifiers", "--delay", "0", "--", text],
            timeout=10, env=env,
        )


# ── Audio source detection ─────────────────────────

def find_audio_source():
    """Find best audio source. Priority: RNNoise filter > USB mic > any non-monitor source."""
    try:
        result = subprocess.run(
            ["pactl", "list", "sources", "short"],
            capture_output=True, text=True, timeout=5, env=_user_env(),
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

        if AUDIO_SOURCE_NAME:
            for name, state in candidates:
                if AUDIO_SOURCE_NAME.lower() in name.lower():
                    logger.info("Found audio source (filter match): %s (%s)", name, state)
                    return name
            logger.warning("No source matching '%s', falling back to auto-detect", AUDIO_SOURCE_NAME)

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


# ── Recording ──────────────────────────────────────

def start_recording():
    global rec_process, rec_start_time, busy
    if busy:
        logger.info("Busy, ignoring")
        return

    for f in [AUDIOFILE, RAWFILE]:
        try:
            os.unlink(f)
        except OSError:
            pass

    env = _user_env()

    if IS_MAC:
        rec_process = subprocess.Popen(
            ["rec", "-q", "-r", "16000", "-c", "1", "-b", "16", AUDIOFILE],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env,
        )
    else:
        source = find_audio_source()
        rec_args = ["parecord", "--format=s16le", "--rate=16000", "--channels=1", "--raw", RAWFILE]
        if source:
            rec_args.insert(1, f"--device={source}")
        rec_process = subprocess.Popen(
            rec_args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env,
        )

    rec_start_time = time.monotonic()
    logger.info("Recording started (PID %d)", rec_process.pid)
    play_sound("start")
    # Give PipeWire time to wake up suspended source
    time.sleep(0.3)


def stop_recording():
    global rec_process, busy
    if rec_process is None:
        return

    elapsed = time.monotonic() - rec_start_time

    # Extra buffer to capture trailing words
    time.sleep(1.0)

    rec_process.send_signal(signal.SIGINT)
    try:
        rec_process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        rec_process.kill()
    rec_process = None
    logger.info("Recording stopped (%.1fs)", elapsed)
    play_sound("stop")

    if elapsed < MIN_DURATION_SECS:
        notify("Too short, ignored")
        for f in [RAWFILE, AUDIOFILE]:
            try:
                os.unlink(f)
            except OSError:
                pass
        return

    if IS_LINUX and os.path.isfile(RAWFILE):
        try:
            subprocess.run(
                ["sox", "-r", "16000", "-e", "signed", "-b", "16", "-c", "1", RAWFILE, AUDIOFILE],
                capture_output=True, timeout=5,
            )
            os.unlink(RAWFILE)
        except Exception as e:
            logger.error("Raw to WAV conversion failed: %s", e)
            return

    busy = True
    threading.Thread(target=transcribe_and_paste, daemon=True).start()


# ── Voice Commands ──────────────────────────────────

def _exec_keys(*keys):
    """Execute keyboard shortcut via xdotool/osascript."""
    env = _user_env()
    if IS_MAC:
        key_str = " + ".join(keys)
        subprocess.run(
            ["osascript", "-e", f'tell application "System Events" to key code {key_str}'],
            timeout=5, env=env,
        )
    else:
        _release_modifiers()
        combo = "+".join(keys)
        subprocess.run(
            _xdotool_prefix() + ["xdotool", "key", "--clearmodifiers", combo],
            timeout=5, env=env,
        )


# Command actions: command_id → keyboard action or callable
# Language-independent — the LLM maps spoken words to these IDs
COMMAND_ACTIONS = {
    # Editing
    "delete": "BackSpace",
    "delete_word": "ctrl+BackSpace",
    "delete_line": "ctrl+shift+k",
    "delete_all": "ctrl+a BackSpace",
    "undo": "ctrl+z",
    "redo": "ctrl+shift+z",
    # Navigation
    "enter": "Return",
    "new_line": "Return",
    "space": "space",
    "tab": "Tab",
    "escape": "Escape",
    "home": "Home",
    "end": "End",
    "page_up": "Prior",
    "page_down": "Next",
    "arrow_up": "Up",
    "arrow_down": "Down",
    "arrow_left": "Left",
    "arrow_right": "Right",
    # Punctuation
    "period": lambda: paste_text("."),
    "comma": lambda: paste_text(","),
    "question_mark": lambda: paste_text("?"),
    "exclamation": lambda: paste_text("!"),
    "colon": lambda: paste_text(":"),
    "semicolon": lambda: paste_text(";"),
    "dash": lambda: paste_text("-"),
    "open_parenthesis": lambda: paste_text("("),
    "close_parenthesis": lambda: paste_text(")"),
    "open_quote": lambda: paste_text('"'),
    "close_quote": lambda: paste_text('"'),
    # Clipboard
    "copy": "ctrl+c",
    "paste": "ctrl+v",
    "cut": "ctrl+x",
    "select_all": "ctrl+a",
    # System
    "save": "ctrl+s",
    "find": "ctrl+f",
    "cancel": "CANCEL",
}

COMMAND_LIST = ", ".join(COMMAND_ACTIONS.keys())

_CMD_PROMPT = f"""You are a voice command classifier. The user speaks commands in various languages.
Available commands: {COMMAND_LIST}
Rules:
- If the input is a command in ANY language (English, Romanian, French, German, etc.), reply: CMD:command_name
- Examples: "undo"→CMD:undo, "șterge"→CMD:delete, "selectează tot"→CMD:select_all, "enter"→CMD:enter, "virgulă"→CMD:comma, "Andu"→CMD:undo, "Selectază tot"→CMD:select_all
- For compound commands: "selectează tot și șterge"→CMD:select_all CMD:delete_all
- If the input is regular speech/text to be typed out, reply: TEXT
Reply ONLY with CMD:name(s) or TEXT. Nothing else."""


def detect_command(text: str) -> list[str] | None:
    """Ask LLM if text is a voice command. Returns list of command IDs or None."""
    try:
        client = core._get_llm_client()
        resp = client.chat.completions.create(
            model=core.llm_model,
            messages=[
                {"role": "system", "content": _CMD_PROMPT},
                {"role": "user", "content": text},
            ],
            max_tokens=30,
            temperature=0,
        )
        answer = resp.choices[0].message.content.strip()
        logger.info("LLM command detection: '%s' → %s", text, answer)

        if answer == "TEXT":
            return None

        # Parse CMD:name or multiple CMD:name CMD:name2
        cmds = []
        for part in answer.split():
            if part.startswith("CMD:"):
                cmd_id = part[4:].strip().lower()
                if cmd_id in COMMAND_ACTIONS:
                    cmds.append(cmd_id)
        return cmds if cmds else None
    except Exception as e:
        logger.warning("LLM command detection failed: %s", e)
        return None


def execute_commands(cmd_ids: list[str]) -> bool:
    """Execute a list of command IDs. Returns True if any executed."""
    for cmd_id in cmd_ids:
        action = COMMAND_ACTIONS.get(cmd_id)
        if not action:
            continue
        if action == "CANCEL":
            notify("⛔ Cancelled")
            play_sound("command")
            logger.info("Command: cancel")
            return True
        if callable(action):
            action()
        else:
            for combo in action.split():
                _exec_keys(combo)
        logger.info("Command executed: %s → %s", cmd_id,
                     "callable" if callable(action) else action)
        play_sound("command")
        notify(f"⚡ {cmd_id}")
    return bool(cmd_ids)


# ── Transcription ──────────────────────────────────

def transcribe_and_paste(prefetched_result=None):
    """Transcribe audio, auto-detect commands vs dictation.
    
    Args:
        prefetched_result: If provided, skip Groq call and use this result directly
                          (from speculative transcription).
    """
    global busy
    try:
        if not os.path.isfile(AUDIOFILE) or os.path.getsize(AUDIOFILE) < 5000:
            notify("Too short, ignored")
            return

        lang = LANGUAGE if LANGUAGE != "auto" else None
        is_vad = INPUT_MODE == "vad"

        if prefetched_result:
            result = prefetched_result
            logger.info("Using prefetched speculative result")
        elif is_vad:
            # Force language in active state for better dictation quality
            is_active = time.monotonic() < vad_active_until
            vad_lang = (LANGUAGE if LANGUAGE != "auto" else None) if is_active else None
            result = _groq_transcribe(AUDIOFILE, vad_lang)
        else:
            result = core.transcribe(AUDIOFILE, lang)

        text = result.get("text", "").strip()
        detected_lang = result.get("language", "?")

        if not text:
            notify("No speech detected")
            return

        # Filter Whisper hallucinations (repeated phantom phrases on noise)
        _hallucinations = {"să vă mulțumim pentru vizionare", "mulțumim pentru vizionare",
                           "thank you for watching", "thanks for watching",
                           "subtitles by", "translated by",
                           "să vă mulțumesc pentru like", "mulțumesc pentru like",
                           "vă mulțumesc pentru vizionare", "mulțumesc pentru vizionare",
                           "să ne vedem la următoarea mea rețetă",
                           "ne vedem la următoarea mea rețetă",
                           "mulțumit pentru vizionare"}
        if text.lower().rstrip(".!?,;: ") in _hallucinations:
            logger.info("Filtered Whisper hallucination: '%s'", text)
            return

        logger.info("Transcribed [%s]: %s", detected_lang, text)
        word_count = len(text.split())

        # ── VAD: wake word is handled by OpenWakeWord in the listener ──
        # In VAD mode, speech only reaches here if already in ACTIVE state
        # In PTT mode, all speech is processed (no wake word needed)

        # Strip wake word from text if Whisper transcribed it
        # (e.g., user says "hey jarvis, delete" → Whisper outputs "Hey Jarvis, delete")
        if is_vad:
            lower_clean = text.lower().replace(",", "").replace("!", "").replace(".", "").replace('"', "").replace("-", " ")
            lower_clean = " ".join(lower_clean.split())
            for mw in _magic_variants:
                if lower_clean.startswith(mw):
                    rest = lower_clean[len(mw):].strip()
                    if rest:
                        text = rest
                        word_count = len(text.split())
                    else:
                        # Just the wake word, nothing else — ignore
                        return
                    break

        # Short utterance? Ask LLM if it's a command
        if word_count <= MAX_COMMAND_WORDS:
            cmd_ids = detect_command(text)
            if cmd_ids:
                execute_commands(cmd_ids)
                return

        # Normal dictation flow
        # In VAD mode, add a leading space between consecutive segments
        if is_vad:
            text = " " + text

        use_cleanup = LLM_CLEANUP
        use_translate = TRANSLATE_TO if TRANSLATE_ENABLED else None

        if use_cleanup or use_translate:
            full_output = []
            for token in core.llm_process_stream(text, detected_lang, use_cleanup, use_translate):
                full_output.append(token)
                _type_chunk(token)
            final = "".join(full_output).strip()
            logger.info("Final output: %s", final)
        else:
            notify(f"[{detected_lang}] {text}")
            time.sleep(0.3)
            paste_text(text)

        # Segment done — audio feedback
        if is_vad:
            play_sound("done")

    except Exception as e:
        logger.exception("Transcription failed")
        notify(f"Error: {e}")
        play_sound("error")
    finally:
        for f in [AUDIOFILE, RAWFILE]:
            try:
                os.unlink(f)
            except OSError:
                pass
        busy = False


# ── Keyboard listeners ─────────────────────────────

def run_evdev_listener():
    import evdev
    from evdev import ecodes

    TRIGGER_KEY_NAME = os.getenv("DICTATE_KEY", "KEY_RIGHTCTRL")
    trigger_code = getattr(ecodes, TRIGGER_KEY_NAME, ecodes.KEY_RIGHTCTRL)

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
                if KEYBOARD_NAME and KEYBOARD_NAME.lower() in name_lower:
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
    logger.info("Hold %s to talk. Short = command, long = dictation.", TRIGGER_KEY_NAME)

    recording = False
    try:
        for event in dev.read_loop():
            if event.type != ecodes.EV_KEY or event.code != trigger_code:
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
        if rec_process:
            stop_recording()


def run_pynput_listener():
    from pynput import keyboard

    TRIGGER_KEY_NAME = os.getenv("DICTATE_KEY", "ctrl_r")

    key_map = {
        "ctrl_r": keyboard.Key.ctrl_r, "ctrl_l": keyboard.Key.ctrl_l,
        "alt_r": keyboard.Key.alt_r, "alt_l": keyboard.Key.alt_l,
        "shift_r": keyboard.Key.shift_r, "shift_l": keyboard.Key.shift_l,
        "cmd": keyboard.Key.cmd, "cmd_r": keyboard.Key.cmd_r,
        "f13": keyboard.KeyCode.from_vk(105), "f14": keyboard.KeyCode.from_vk(107),
        "f15": keyboard.KeyCode.from_vk(113),
        "KEY_RIGHTCTRL": keyboard.Key.ctrl_r, "KEY_LEFTCTRL": keyboard.Key.ctrl_l,
        "KEY_RIGHTALT": keyboard.Key.alt_r, "KEY_LEFTALT": keyboard.Key.alt_l,
    }
    trigger_key = key_map.get(TRIGGER_KEY_NAME)

    if trigger_key is None:
        logger.error("Unknown trigger key: %s", TRIGGER_KEY_NAME)
        sys.exit(1)

    logger.info("Hold %s to talk. Short = command, long = dictation.", TRIGGER_KEY_NAME)
    recording = False

    def on_press(key):
        nonlocal recording
        if not recording and key == trigger_key:
            recording = True
            start_recording()

    def on_release(key):
        nonlocal recording
        if key == trigger_key and recording:
            recording = False
            stop_recording()

    with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
        listener.join()


# ── VAD listener (always-on) ──────────────────────

def run_vad_listener():
    """Always-on voice detection with OpenWakeWord for instant wake word detection."""
    import webrtcvad
    import numpy as np
    from openwakeword.model import Model as OWWModel

    global busy

    vad = webrtcvad.Vad(3)  # aggressiveness 0-3 (3 = strictest)

    # Load OpenWakeWord model(s)
    oww_target_raw = os.getenv("DICTATE_WAKEWORD_MODEL", "hey_jarvis")
    oww_threshold = float(os.getenv("DICTATE_WAKEWORD_THRESHOLD", "0.5"))

    # Support comma-separated model paths or single path/name
    model_paths = [p.strip() for p in oww_target_raw.split(",") if p.strip()]
    resolved_paths = []
    for mp in model_paths:
        if mp.endswith(".onnx") or os.path.sep in mp:
            path = os.path.expanduser(mp)
            if not os.path.isfile(path):
                path = os.path.join(os.path.dirname(__file__), mp)
            if os.path.isfile(path):
                resolved_paths.append(path)
            else:
                logger.warning("Wake word model not found: %s", mp)

    if resolved_paths:
        oww = OWWModel(wakeword_model_paths=resolved_paths)
        oww_targets = list(oww.models.keys())
        logger.info("OpenWakeWord loaded %d model(s): %s (threshold=%.2f)",
                     len(oww_targets), oww_targets, oww_threshold)
    else:
        # Built-in model name
        oww = OWWModel()
        oww_targets = list(oww.models.keys())
        logger.info("OpenWakeWord loaded built-in models: %s (threshold=%.2f)", oww_targets, oww_threshold)

    SAMPLE_RATE = 16000
    FRAME_MS = 30
    FRAME_BYTES = int(SAMPLE_RATE * FRAME_MS / 1000) * 2  # 16-bit mono
    OWW_CHUNK = 1280 * 2  # 80ms at 16kHz, 16-bit = 2560 bytes

    # Tuning
    SPEECH_FRAMES_START = 3     # consecutive speech frames to trigger recording
    SILENCE_FRAMES_STOP = max(1, SILENCE_STANDBY_MS // FRAME_MS)    # standby silence
    SILENCE_FRAMES_ACTIVE = max(1, SILENCE_ACTIVE_MS // FRAME_MS)  # active silence
    MIN_SPEECH_FRAMES = 15      # ~450ms minimum to process
    PRE_BUFFER_FRAMES = 10      # ~300ms kept before speech detected
    MAX_SEGMENT_FRAMES = 1000   # ~30s max — longer = ambient/speaker noise, discard

    source = find_audio_source()
    env = _user_env()

    rec_args = ["parecord", "--format=s16le", "--rate=16000", "--channels=1",
                "--raw", "--latency-msec=30", "/dev/stdout"]
    if source:
        rec_args.insert(1, f"--device={source}")

    mic = subprocess.Popen(rec_args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
    wake_words_str = " / ".join(t.replace("_", " ") for t in oww_targets)
    logger.info("VAD listener started (source=%s). Say '%s' to activate.", source or "default", wake_words_str)

    state = "SILENCE"
    speech_buf = bytearray()
    ring_buf = []
    speech_frames = 0
    silence_frames = 0
    consec_speech = 0
    oww_buf = bytearray()  # accumulate frames for OpenWakeWord (needs 80ms chunks)
    was_active = False  # track active state for deactivation sound

    # Speculative transcription: fire Groq request early during silence wait
    from concurrent.futures import ThreadPoolExecutor, Future
    spec_executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="spec")
    spec_future: Future | None = None
    spec_buf_len = 0  # speech_buf length when speculative was fired

    def _spec_transcribe(raw_audio: bytes) -> dict | None:
        """Convert raw PCM to WAV and transcribe via Groq (runs in background)."""
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
            is_active = time.monotonic() < vad_active_until
            vad_lang = (LANGUAGE if LANGUAGE != "auto" else None) if is_active else None
            result = _groq_transcribe(wav_path, vad_lang)
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

            # ── OpenWakeWord: feed every 80ms ──
            oww_buf.extend(frame)
            if len(oww_buf) >= OWW_CHUNK:
                chunk = bytes(oww_buf[:OWW_CHUNK])
                oww_buf = oww_buf[OWW_CHUNK:]
                audio_np = np.frombuffer(chunk, dtype=np.int16)
                prediction = oww.predict(audio_np)
                # Check all loaded wake word models
                for oww_name in oww_targets:
                    score = prediction.get(oww_name, 0)
                    if score > 0.05:
                        logger.debug("OWW '%s' score: %.4f (threshold=%.2f)", oww_name, score, oww_threshold)
                    if score > oww_threshold:
                        if time.monotonic() >= vad_active_until:
                            logger.info("🎤 Wake word '%s' detected (score=%.3f)", oww_name, score)
                            play_sound("activate")
                        _set_vad_active()
                        oww.reset()
                        break

            # Detect active state timeout → play deactivation sound
            is_active_now = time.monotonic() < vad_active_until
            if was_active and not is_active_now:
                logger.info("VAD: active state expired → STANDBY (auto-enter)")
                play_sound("stop")
                # Auto-press Enter when session ends
                if VAD_AUTO_ENTER:
                    _release_modifiers()
                    env = _user_env()
                    prefix = _xdotool_prefix()
                    subprocess.run(
                        prefix + ["xdotool", "key", "--clearmodifiers", "Return"],
                        timeout=5, env=env, capture_output=True,
                    )
            was_active = is_active_now

            # While busy processing, just drain the buffer
            if busy:
                # Reset VAD state so we don't accumulate a huge buffer while busy
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

                # Safety: discard segments that are too long (ambient/speaker noise)
                if speech_frames >= MAX_SEGMENT_FRAMES:
                    duration = speech_frames * FRAME_MS / 1000
                    logger.warning("VAD: segment too long (%.1fs), discarding (ambient noise?)", duration)
                    state = "SILENCE"
                    speech_buf = bytearray()
                    consec_speech = 0
                    silence_frames = 0
                    ring_buf.clear()
                    continue

                if is_speech:
                    silence_frames = 0
                    # Speech resumed — cancel any speculative transcription
                    if spec_future is not None:
                        spec_future.cancel()
                        spec_future = None
                        spec_buf_len = 0
                    # Keep active state alive while speaking
                    if time.monotonic() < vad_active_until:
                        _set_vad_active()
                else:
                    silence_frames += 1
                    # Adaptive threshold: longer in active state to capture natural speech
                    is_active_now = time.monotonic() < vad_active_until
                    threshold = SILENCE_FRAMES_ACTIVE if is_active_now else SILENCE_FRAMES_STOP

                    # Speculative: fire Groq request at half the silence threshold
                    spec_trigger = threshold // 2
                    if (silence_frames == spec_trigger and spec_future is None
                            and speech_frames >= MIN_SPEECH_FRAMES and is_active_now):
                        spec_buf_len = len(speech_buf)
                        spec_future = spec_executor.submit(_spec_transcribe, bytes(speech_buf))
                        logger.debug("VAD: speculative transcription fired at %d silence frames", silence_frames)

                    if silence_frames >= threshold:
                        # Speech ended
                        state = "SILENCE"
                        consec_speech = 0
                        ring_buf.clear()

                        duration = speech_frames * FRAME_MS / 1000
                        is_active_now = time.monotonic() < vad_active_until

                        if speech_frames >= MIN_SPEECH_FRAMES and is_active_now:
                            _set_vad_active()

                            # Check if speculative result is usable (no new speech since it fired)
                            if spec_future is not None and not spec_future.cancelled():
                                try:
                                    result = spec_future.result(timeout=5)
                                    spec_future = None
                                    spec_buf_len = 0
                                    if result:
                                        logger.info("VAD: speech ended (%.1fs) — using speculative result", duration)
                                        text = result.get("text", "").strip()
                                        if text:
                                            # Write WAV for transcribe_and_paste (it reads AUDIOFILE)
                                            with open(RAWFILE, "wb") as f:
                                                f.write(speech_buf)
                                            subprocess.run(
                                                ["sox", "-r", "16000", "-e", "signed", "-b", "16",
                                                 "-c", "1", RAWFILE, AUDIOFILE],
                                                capture_output=True, timeout=5,
                                            )
                                            try: os.unlink(RAWFILE)
                                            except OSError: pass
                                            busy = True
                                            # Pass pre-fetched result to avoid double Groq call
                                            threading.Thread(
                                                target=transcribe_and_paste,
                                                args=(result,),
                                                daemon=True,
                                            ).start()
                                            speech_buf = bytearray()
                                            continue
                                except Exception:
                                    pass

                            # Normal path: no speculative or it was stale
                            spec_future = None
                            spec_buf_len = 0
                            logger.info("VAD: speech ended (%.1fs) — processing", duration)
                            # Save raw → wav → process
                            with open(RAWFILE, "wb") as f:
                                f.write(speech_buf)
                            try:
                                subprocess.run(
                                    ["sox", "-r", "16000", "-e", "signed", "-b", "16",
                                     "-c", "1", RAWFILE, AUDIOFILE],
                                    capture_output=True, timeout=5,
                                )
                                os.unlink(RAWFILE)
                            except Exception as e:
                                logger.error("Raw→WAV failed: %s", e)
                                speech_buf = bytearray()
                                continue

                            busy = True
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


# ── Main ───────────────────────────────────────────

def main():
    logger.info("Dictate desktop client starting (%s)", PLATFORM)
    logger.info("Input: %s | Mode: %s | Language: %s | Magic word: '%s'",
                INPUT_MODE, core.mode, LANGUAGE, MAGIC_WORD)

    if LLM_CLEANUP or TRANSLATE_ENABLED:
        features = []
        if LLM_CLEANUP:
            features.append("cleanup")
        if TRANSLATE_ENABLED:
            features.append(f"translate→{TRANSLATE_TO}")
        logger.info("LLM streaming: %s (provider=%s, model=%s)",
                     "+".join(features), core.llm_provider, core.llm_model)

    # Generate sound files
    _generate_sounds()
    # Generate magic word variants via LLM
    _generate_magic_variants()

    if INPUT_MODE == "vad":
        run_vad_listener()
    elif IS_LINUX:
        try:
            import evdev  # noqa: F401
            logger.info("Using evdev key capture")
            run_evdev_listener()
        except ImportError:
            logger.info("evdev not available, falling back to pynput")
            run_pynput_listener()
    else:
        run_pynput_listener()


if __name__ == "__main__":
    main()
