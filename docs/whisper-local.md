# Whisper Local STT — Implementation Guide

## Current State
- whisper.cpp compiled with CUDA on dev machine (RTX 4070)
- Model: ggml-medium.bin (1.5GB) at ~/.config/talkye/models/
- Integrated as `local` backend in sidecar (alongside `groq`)
- Flutter setting: STT Engine dropdown (Groq Cloud / Whisper Local)

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
| ggml-large-v3.bin | 3.1GB | Best | ~800ms |

Recommended: medium for balanced quality/speed, large-v3 for max quality.

## Auto-download for end users
When user selects "Whisper Local" for the first time:
1. Check if whisper-cli binary exists → if not, show "Setup required" dialog
2. Check if model file exists → if not, download automatically
3. Download URL: `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin`
4. Store at: `~/.config/talkye/models/ggml-medium.bin`
5. Show progress bar during download (~1.5GB)

Future: bundle whisper-cli binary per platform in app installer.

## Streaming (future)
whisper.cpp has a `--stream` mode that processes audio incrementally.
Instead of batch (record → transcribe → paste), it would:
1. Start whisper-cli in stream mode with mic input
2. Read partial transcriptions from stdout
3. Type text as it appears (word by word)

This requires a different integration (long-running process instead of
one-shot subprocess), but the binary already supports it.

Command: `whisper-cli --stream -m model.bin -l auto --no-timestamps`

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
