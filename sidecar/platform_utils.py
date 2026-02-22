"""Talkye Sidecar — Platform helpers (Linux/macOS).

Clipboard, notifications, keyboard simulation, environment.
"""

import os
import subprocess
import time

from config import IS_LINUX, IS_MAC, REAL_USER, REAL_HOME, DISPLAY, XDG_RUNTIME


def user_env():
    """Build environment dict for subprocess calls (handles sudo context)."""
    env = os.environ.copy()
    if IS_LINUX and os.getenv("SUDO_USER"):
        env["HOME"] = REAL_HOME
        env["DISPLAY"] = DISPLAY
        if XDG_RUNTIME:
            env["XDG_RUNTIME_DIR"] = XDG_RUNTIME
            env["PULSE_SERVER"] = f"unix:{XDG_RUNTIME}/pulse/native"
    return env


def xdotool_prefix():
    """Return sudo prefix for xdotool/xclip commands."""
    if os.getenv("SUDO_USER"):
        return ["sudo", "-u", REAL_USER, "env",
                f"DISPLAY={DISPLAY}", f"XAUTHORITY={REAL_HOME}/.Xauthority"]
    return []


def release_modifiers():
    """Force-release all modifier keys to prevent ghost state."""
    if IS_MAC:
        return
    subprocess.run(
        xdotool_prefix() + ["xdotool", "keyup", "alt", "Alt_L", "Alt_R",
                             "ctrl", "Control_L", "Control_R",
                             "shift", "Shift_L", "Shift_R",
                             "super", "Super_L", "Super_R"],
        timeout=5, env=user_env(), capture_output=True,
    )


def notify(msg: str):
    """Show desktop notification."""
    try:
        if IS_MAC:
            subprocess.Popen(
                ["osascript", "-e", f'display notification "{msg}" with title "Dictate"'],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
        elif IS_LINUX and os.getenv("SUDO_USER"):
            subprocess.Popen(
                ["sudo", "-u", REAL_USER, "notify-send", "-t", "2000", "Dictate", msg],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=user_env(),
            )
        else:
            subprocess.Popen(
                ["notify-send", "-t", "2000", "Dictate", msg],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=user_env(),
            )
    except FileNotFoundError:
        pass


def paste_text(text: str):
    """Paste text at cursor via clipboard."""
    env = user_env()
    if IS_MAC:
        proc = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE, env=env)
        proc.communicate(input=text.encode("utf-8"), timeout=5)
        time.sleep(0.1)
        subprocess.run(
            ["osascript", "-e", 'tell application "System Events" to keystroke "v" using command down'],
            timeout=5, env=env,
        )
    else:
        prefix = xdotool_prefix()
        proc = subprocess.Popen(
            prefix + ["xclip", "-selection", "clipboard"],
            stdin=subprocess.PIPE, env=env,
        )
        proc.communicate(input=text.encode("utf-8"), timeout=5)
        time.sleep(0.1)
        release_modifiers()
        subprocess.run(
            prefix + ["xdotool", "key", "--clearmodifiers", "ctrl+v"],
            timeout=5, env=env,
        )


def type_chunk(text: str):
    """Type text character by character (for streaming output)."""
    env = user_env()
    if IS_MAC:
        escaped = text.replace("\\", "\\\\").replace('"', '\\"')
        subprocess.run(
            ["osascript", "-e", f'tell application "System Events" to keystroke "{escaped}"'],
            timeout=5, env=env,
        )
    else:
        subprocess.run(
            xdotool_prefix() + ["xdotool", "type", "--clearmodifiers", "--delay", "0", "--", text],
            timeout=10, env=env,
        )


def exec_keys(*keys):
    """Execute keyboard shortcut via xdotool/osascript."""
    env = user_env()
    if IS_MAC:
        key_str = " + ".join(keys)
        subprocess.run(
            ["osascript", "-e", f'tell application "System Events" to key code {key_str}'],
            timeout=5, env=env,
        )
    else:
        release_modifiers()
        combo = "+".join(keys)
        subprocess.run(
            xdotool_prefix() + ["xdotool", "key", "--clearmodifiers", combo],
            timeout=5, env=env,
        )
