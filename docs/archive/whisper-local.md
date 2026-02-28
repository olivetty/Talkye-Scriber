# Whisper Local STT — Implementation Guide

## Current State
- whisper.cpp compiled with CUDA on dev machine (RTX 4070)
- Default model: ggml-large-v3-turbo.bin (1.6GB) at ~/.config/talkye/models/
- Integrated as `local` backend in sidecar (default, alongside `groq` fallback)
- Flutter setting: Dictation Engine in Settings page (Whisper Local / Groq Cloud)
- Transcription speed: ~1.2-1.5s per segment on RTX 4070

## Architecture
```
User speaks → VAD detects speech → WAV segment
  → if STT_BACKEND=groq:  Groq API (cloud, ~300ms)
  → if STT_BACKEND=local:  whisper-cli subprocess (GPU, ~500-800ms)
```

## Build whisper.cpp

### Linux + NVIDIA (CUDA)
```bash
git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git
cd whisper.cpp
cmake -B build -DGGML_CUDA=1 -DCMAKE_BUILD_TYPE=Release
cmake --build build -j --config Release
```

### Linux + AMD (Vulkan)
```bash
cmake -B build -DGGML_VULKAN=1 -DCMAKE_BUILD_TYPE=Release
cmake --build build -j --config Release
```

### Linux CPU only (no GPU)
```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j --config Release
```

### macOS (Metal — Apple Silicon)
```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j --config Release
# Metal is auto-detected on macOS
```

## Models (ggml format)
Download from: https://huggingface.co/ggerganov/whisper.cpp/tree/main

| Model | Size | Quality | Speed (RTX 4070) |
|-------|------|---------|-------------------|
| ggml-tiny.bin | 75MB | Basic | ~100ms |
| ggml-base.bin | 142MB | OK | ~150ms |
| ggml-small.bin | 466MB | Good | ~300ms |
| ggml-medium.bin | 1.5GB | Great | ~500ms |
| ggml-large-v3-turbo.bin | 1.6GB | Near-best | ~1.2s |
| ggml-large-v3.bin | 3.1GB | Best | ~2-3s |

Default: large-v3-turbo (best quality/speed ratio, same size as medium).

## Auto-download for end users
When user selects "Whisper Local" for the first time:
1. Check if whisper-cli binary exists → if not, show "Setup required" dialog
2. Check if model file exists → if not, download automatically
3. Download URL: `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin`
4. Store at: `~/.config/talkye/models/ggml-large-v3-turbo.bin`
5. Show progress bar during download (~1.6GB)

Future: bundle whisper-cli binary per platform in app installer.

## Streaming (future — high priority)
Current flow: record segment → transcribe entire file → paste all at once.
Goal: text appears word-by-word as user speaks.

### Option A: whisper-server (recommended)
whisper.cpp ships a built-in HTTP server with streaming support:
```bash
whisper.cpp/build/bin/whisper-server -m model.bin --port 8178 -l auto
```
- Keeps model loaded in VRAM permanently (~2.5GB for large-v3-turbo)
- Accepts audio chunks via HTTP/WebSocket
- Returns partial transcriptions incrementally
- Much faster per-request (no model load/unload overhead)
- Integration: send audio chunks from VAD → read streaming response → type_chunk()

### Option B: whisper-cli --stream mode
```bash
whisper-cli --stream -m model.bin -l auto --no-timestamps
```
- Reads from microphone directly (bypasses our VAD)
- Outputs text incrementally to stdout
- Simpler but less control over VAD/wake word integration

### Option C: Python bindings (pywhispercpp / faster-whisper)
- Load model once in Python process
- Feed audio segments directly (no subprocess overhead)
- Most flexible but adds Python dependency complexity

### Implementation plan for Option A:
1. Start whisper-server as long-running sidecar process
2. VAD sends audio chunks via HTTP POST as they accumulate
3. Server returns partial transcriptions
4. type_chunk() outputs text character by character
5. Final transcription replaces partial output
6. Benefit: model stays warm in VRAM, ~100-200ms latency per chunk

## Cross-platform distribution plan
1. Linux: compile per GPU vendor (CUDA .deb, Vulkan .deb, CPU .deb)
2. macOS: single universal binary (Metal auto-detected)
3. Windows: CUDA + Vulkan + CPU variants
4. Or: ship Vulkan build everywhere (works on all GPUs + CPU fallback)

## Dependencies
- CUDA toolkit (for NVIDIA build)
- Vulkan SDK (for AMD/cross-vendor build)
- cmake, gcc/clang
- sox (for audio format conversion)
