# Desktop Dictation — `desktop.py`

Real-time speech-to-text that types at your cursor position. Two input modes: push-to-talk and wake word.

## Usage

```bash
# As systemd service (recommended)
sudo systemctl start whisper-p2t
sudo systemctl status whisper-p2t

# Manual run
./venv/bin/python desktop.py
```

## Input Modes

### Push-to-Talk (PTT)
Hold a key, speak, release — text appears at cursor.

```env
DICTATE_INPUT=ppt
DICTATE_KEY=KEY_RIGHTCTRL
```

### Wake Word (VAD)
Say a wake word to activate, speak, pause to finish. Hands-free.

```env
DICTATE_INPUT=vad
DICTATE_WAKEWORD_MODEL=models/hey_mira.onnx,models/alo.onnx
DICTATE_MAGIC_WORD=hey mira
DICTATE_WAKEWORD_THRESHOLD=0.1
```

Multiple wake word models supported (comma-separated paths).

## Pipeline

```
Audio capture (parecord) → Wake word / PTT trigger
  → Record speech → sox convert to WAV
  → Groq Whisper API (~0.5s)
  → Optional: LLM cleanup/translation (streaming tokens)
  → Each token typed at cursor via xdotool
```

## Key Settings (.env)

| Variable | Default | Description |
|---|---|---|
| `DICTATE_MODE` | `server` | `server`, `groq`, `api` |
| `DICTATE_INPUT` | `ppt` | `ppt` (push-to-talk) or `vad` (voice activity) |
| `DICTATE_KEY` | `KEY_RIGHTCTRL` | Trigger key for PTT mode |
| `DICTATE_LANGUAGE` | `ro` | `auto`, `ro`, `en`, etc. |
| `DICTATE_SOURCE_NAME` | — | Audio source (e.g. `effect_output.voice_enhance`) |
| `DICTATE_WAKEWORD_MODEL` | — | Path(s) to .onnx wake word model(s) |
| `DICTATE_WAKEWORD_THRESHOLD` | `0.1` | Detection sensitivity (0.0-1.0, lower = more sensitive) |
| `LLM_CLEANUP` | `false` | Post-process transcription with LLM |
| `LLM_PROVIDER` | `xai` | `xai`, `groq`, `openai` |
| `TRANSLATE_ENABLED` | `false` | Auto-translate output |
| `TRANSLATE_TO` | `ro` | Target language code |

## Features

- Auto-detects keyboard and audio source
- RNNoise noise suppression (via PipeWire virtual mic)
- Voice commands: "enter", "tab", "select all", "undo", etc.
- Streaming LLM output — tokens appear as they generate
- Multi-monitor xdotool support
