"""Talkye Sidecar — Voice command detection and execution."""

import logging

import config
from platform_utils import paste_text, exec_keys, release_modifiers, notify

logger = logging.getLogger(__name__)

# Command actions: command_id → keyboard shortcut string or callable
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
        answer = _detect_via_cloud(text)
        if answer is None:
            return None

        logger.info("LLM command detection: '%s' → %s", text, answer)

        if answer == "TEXT":
            return None

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


def _detect_via_cloud(text: str) -> str | None:
    """Fallback to cloud LLM for command detection."""
    try:
        client = config.core._get_llm_client()
        resp = client.chat.completions.create(
            model=config.core.llm_model,
            messages=[
                {"role": "system", "content": _CMD_PROMPT},
                {"role": "user", "content": text},
            ],
            max_tokens=30,
            temperature=0,
        )
        return resp.choices[0].message.content.strip()
    except Exception as e:
        logger.warning("Cloud LLM failed: %s", e)
        return None


def execute_commands(cmd_ids: list[str]) -> bool:
    """Execute a list of command IDs. Returns True if any command was executed."""
    executed = False
    for cmd_id in cmd_ids:
        action = COMMAND_ACTIONS.get(cmd_id)
        if not action:
            continue
        if action == "CANCEL":
            notify("⛔ Cancelled")
            logger.info("Command: cancel")
            return True
        if callable(action):
            action()
        else:
            for combo in action.split():
                exec_keys(combo)
        logger.info("Command executed: %s → %s", cmd_id,
                     "callable" if callable(action) else action)
        notify(f"⚡ {cmd_id}")
        executed = True
    return executed
