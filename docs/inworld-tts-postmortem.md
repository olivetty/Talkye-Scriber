# Inworld TTS — Post-Mortem Analysis

## Timeline
- **Task 60**: Investigated TTS distortion in interpreter. Replaced `Mutex<VecDeque>` with `ringbuf::HeapRb` lock-free SPSC in playback. Concluded Pocket TTS RTF ≈ 0.94–1.05 was the bottleneck.
- **Task 61**: Switched to Inworld Cloud TTS ($5/1M chars). Full integration: HTTP streaming, WAV header stripping, NDJSON parsing, chunked transfer encoding.
- **Task 62**: Discovered Flutter audio was garbled. Replaced cpal-based `AudioPlayback` with `paplay` (PulseAudio CLI). **Audio played perfectly after this fix.**
- **Task 63**: Voice cloning on Inworld produced ~11s audio for ~2s of speech. Root cause: SpeechLM architecture includes prompt/reference audio in output. Attempted timestamp-based stripping — a hack over a fundamental architectural limitation.

## The Real Root Cause (Discovered Too Late)

**The original distortion problem was NOT in Pocket TTS or Chatterbox.** It was in the Flutter/cpal audio playback layer.

Evidence:
- After replacing cpal with `paplay` in Task 62, audio from Inworld played perfectly
- This same fix would have resolved the distortion with Pocket TTS and Chatterbox
- The RTF ≈ 0.94–1.05 measurement for Pocket TTS was a red herring — the audio was being corrupted during playback, not during generation

**cpal on Linux (PulseAudio/PipeWire)** was the culprit:
- Sample rate mismatches between the TTS output and the audio device
- Buffer underruns causing clicks and distortion
- The lock-free ring buffer fix (Task 60) improved things but didn't solve the fundamental cpal issue

## Inworld TTS Problems

### 1. Voice Cloning is Broken for Real-Time Use
- Inworld's model is a SpeechLM (confirmed from their [training repo](https://github.com/inworld-ai/tts))
- At inference, cloned voices (IVC) include the full prompt/reference audio in the output
- "Hello, how are you?" with system voice = **2660ms**, with cloned voice = **11100ms** (~4x longer)
- Word timestamps confirm: words appear at 0.0s, 0.39s, 0.84s, then jump to 9.88s — a 9-second gap of reference audio
- `autoMode: true` does NOT fix it
- All 4 models (tts-1.5-mini, tts-1.5-max, tts-1, tts-1-max) have the same issue
- Timestamp-based stripping is possible but fragile — it's a hack over a fundamental architecture issue

### 2. Cost
- $5/1M characters — expensive for a real-time interpreter that processes continuous speech
- A 1-hour meeting with active interpretation could easily consume 50K+ characters = $0.25/hour
- Local TTS (Pocket/Chatterbox) = $0/hour

### 3. Latency
- First chunk latency: 1600–2200ms (network round-trip + model inference)
- Pocket TTS local: ~200–400ms first chunk
- Chatterbox local: ~500–800ms first chunk (with streaming)

## What We Should Have Done

1. **Diagnosed the playback layer first** — the distortion was consistent across all audio sources, which should have pointed to playback, not TTS
2. **Tested with a simple WAV file playback** through cpal to isolate the issue
3. **Tried paplay earlier** — it's the standard Linux audio playback tool and bypasses cpal entirely

## Recommendation: Revert to Chatterbox + Pocket TTS

### What to restore:
- `core/src/tts/pocket.rs` — Pocket TTS backend (fast, low-latency)
- `core/src/tts/sidecar.rs` — Chatterbox sidecar TTS backend (voice cloning)
- `sidecar/chatterbox_worker.py` — Chatterbox Python worker
- `sidecar/tts_chatterbox.py` — Chatterbox TTS module
- All Flutter UI for voice selection, Chatterbox settings, etc.

### What to KEEP from the Inworld work:
- **`paplay` playback** in `pipeline.rs` — this was the real fix
- **Lock-free ring buffer** in `playback.rs` — good improvement regardless
- **Voice clone UX improvements** in Flutter UI
- **Debug console** and other audit fixes (already committed)

### What to discard:
- `core/src/tts/inworld.rs` — Inworld TTS backend
- All `test_*.rs` binaries in `core/src/bin/`
- Inworld API key configuration in settings
- `strip_reference_audio()` timestamp hack

## Key Lesson

**Always isolate the layer causing the problem before switching providers.** The distortion was in playback (cpal), not in TTS generation. Switching from local TTS to cloud TTS was an expensive detour that didn't address the root cause.
