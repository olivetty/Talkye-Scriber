# Sidecar Cleanup Plan

## Flow-ul PTT care RĂMÂNE (singurul flow din Scriber):
```
keyboard.py (evdev/pynput) → audio.py (pw-record) → transcribe.py (whisper.cpp local / Groq STT)
  → optional: config.core.llm_process() (Groq LLM cleanup/translate)
  → platform_utils.py (paste via xclip+xdotool)
```

## Fișiere Python de ȘTERS:
- `tts.py` — TTS server (Pocket TTS) — nu e folosit de dictation
- `voice_chat.py` — voice chat pipeline — Chat screen eliminat
- `llm_groq.py` — Groq chat streaming — Chat screen eliminat
- `vad.py` — VAD + Rustpotter wake word — eliminat
- `venv-chatterbox/` — Chatterbox TTS venv

## Endpoint-uri de ȘTERS din server.py:
- `/chat/models`, `/chat` — Chat eliminat
- `/voice-chat/status`, `/voice-chat` WS — Voice chat eliminat
- `/tts/status`, `/tts/test` — TTS eliminat
- `/wakeword/*` (record-sample, build, status, samples) — Wake word eliminat
- TTS startup/shutdown din lifecycle

## Endpoint-uri care RĂMÂN:
- `GET /health`
- `GET /dictate/status`
- `POST /dictate/config`
- `POST /dictate/preview-sound`
- `WS /events`

## config.py — de curățat:
- Șters: VAD state (vad_active_until, vad_silent_end, vad_cooldown_until, set_vad_active)
- Șters: wake word (WAKE_PHRASE, wake_phrase_words, _PHONETIC_MAP, rebuild_strip_variants, training)
- Șters: WAKEWORD_THRESHOLD, INPUT_MODE (mereu PTT)
- Rămâne: TRIGGER_KEY, SOUND_THEME, LANGUAGE, STT_BACKEND, DICTATE_TRANSLATE, DICTATE_GRAMMAR
- Rămâne: core (DictateCore) — pentru LLM post-processing
- Rămâne: load_flutter_settings() — simplificat

## desktop.py — de curățat:
- Șters: VAD branch (if INPUT_MODE == "vad")
- Simplificat: mereu keyboard listener

## transcribe.py — de curățat:
- Șters: _strip_wake_phrase()
- Șters: VAD logic din transcribe_and_paste() (vad_active_until, session_had_output)
- Rămâne: local_transcribe(), groq_transcribe(), _transcribe(), transcribe_and_paste()
- Rămâne: hallucination filter

## requirements — de curățat:
- Șters: webrtcvad, llama-cpp-python, setuptools<81
- Rămâne: python-dotenv, openai, fastapi, uvicorn, python-multipart, websockets, evdev, pynput

## Flutter — de adăugat:
- AppSettings: groqApiKey (pentru LLM translate/grammar)
- Settings screen: câmp Groq API key, toggle translate, toggle grammar, trigger key, sound theme
