# Live Translation — `test_deepgram.py`

Real-time speech translation pipeline. Speak Romanian, hear English translation through your speakers with voice cloning.

## Usage

```bash
./venv/bin/python test_deepgram.py
```

## Pipeline

```
Microphone (parecord 16kHz) → Deepgram Nova-3 STT (streaming WebSocket)
  → Accumulate words from is_final results
  → Flush to Groq LLM translation (RO → EN) when threshold reached
  → Pocket TTS with voice cloning → paplay speaker output
```

## How the Accumulator Works

Deepgram sends `is_final` transcript segments as you speak. Instead of translating each tiny segment individually (which produces fragmented translations), we accumulate words:

1. First flush at **4 words** — gives fast initial response
2. Subsequent flushes at **8+ words** — bigger chunks for better translation quality
3. Immediate flush on **speech end** (speech_final / utterance_end) — no leftover words

This balances latency vs translation quality. The first translated audio plays ~3-4s after you start speaking. Short phrases ("cum te simți?") translate in ~2.3s.

## Latency Breakdown

| Stage | Time |
|---|---|
| Deepgram STT (interim → is_final) | ~2-3s |
| Groq translation | ~150-300ms |
| Pocket TTS first chunk | ~150ms |
| **Total (sunet→sunet)** | **~3-4s typical** |

## Voice Cloning

Record your voice and use it for TTS output:

```bash
# Record 30 seconds of your voice
./record_voice.sh oliver 30

# Set in .env
POCKET_VOICE=voices/oliver.wav
```

The recording script applies audio cleanup: highpass 100Hz, bass reduction, treble boost, normalization.

## Key Settings (.env)

| Variable | Default | Description |
|---|---|---|
| `DEEPGRAM_API_KEY` | — | Required. Get at [deepgram.com](https://console.deepgram.com) |
| `GROQ_API_KEY` | — | Required. Free at [console.groq.com](https://console.groq.com) |
| `DEEPGRAM_ENDPOINTING` | `500` | ms silence before Deepgram finalizes (300=fast, 500=natural, 800=long) |
| `DEEPGRAM_UTTERANCE_END` | `1500` | ms gap before UtteranceEnd event |
| `ACCUM_MIN_WORDS` | `8` | Word threshold for translation flush |
| `ACCUM_FIRST_WORDS` | `4` | Lower threshold for first flush (faster initial response) |
| `POCKET_VOICE` | `alba` | Built-in voice name or path to .wav for voice cloning |
| `POCKET_SPEED` | `1.0` | Playback speed (1.0 = normal) |
| `DICTATE_SOURCE_NAME` | — | Audio source (e.g. `effect_output.voice_enhance`) |

## Translation Context

The translator maintains a sliding window of recent translations to ensure consistency. Within a single utterance, previous fragments are passed as context so translations flow naturally as continuations.

## Dependencies

```
deepgram-sdk          # not used directly — we use raw WebSocket
websocket-client      # Deepgram streaming connection
openai                # Groq API (OpenAI-compatible)
pocket-tts            # Local TTS with voice cloning
python-dotenv         # .env loading
numpy                 # Audio processing
```
