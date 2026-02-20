#!/bin/bash
# ── Record voice sample for Pocket TTS voice cloning ──
# Usage: ./record_voice.sh [name] [seconds]
# Example: ./record_voice.sh oliver 30

NAME="${1:-oliver}"
DURATION="${2:-30}"
OUTPUT="voices/${NAME}.wav"
SOURCE="effect_output.voice_enhance"

mkdir -p voices

echo "╔══════════════════════════════════════════════════════╗"
echo "║         🎙️  VOICE RECORDING — ${NAME}               "
echo "╠══════════════════════════════════════════════════════╣"
echo "║                                                      "
echo "║  Duration: ${DURATION} seconds                       "
echo "║  Output:   ${OUTPUT}                                 "
echo "║  Source:   ${SOURCE}                                 "
echo "║                                                      "
echo "║  TIPS:                                               "
echo "║  • Speak naturally, like a conversation              "
echo "║  • Keep a steady pace, not too fast                  "
echo "║  • Stay close to the mic, consistent distance        "
echo "║  • No background noise/music                         "
echo "║  • Read the script below clearly                     "
echo "║                                                      "
echo "╠══════════════════════════════════════════════════════╣"
echo "║  SCRIPT TO READ (English):                           "
echo "║                                                      "
echo "║  The sun was setting behind the mountains as I       "
echo "║  walked through the quiet village. Every evening,    "
echo "║  the old baker would stand by his door, watching     "
echo "║  the sky change colors. He told me once that the     "
echo "║  best bread comes from patience, not from rushing.   "
echo "║  I think about that sometimes when I'm working       "
echo "║  late at night on a difficult problem. You have to   "
echo "║  let things take their natural course. The river     "
echo "║  doesn't hurry, yet it reaches the sea eventually.   "
echo "║  Technology moves fast, but good ideas need time     "
echo "║  to grow. Yesterday I spoke with a friend about      "
echo "║  building something meaningful, something that       "
echo "║  actually helps people in their daily lives.         "
echo "║  We agreed that simplicity is the ultimate form      "
echo "║  of sophistication.                                  "
echo "║                                                      "
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Press ENTER when ready to record..."
read

echo "🔴 RECORDING in 3..."
sleep 1
echo "🔴 RECORDING in 2..."
sleep 1
echo "🔴 RECORDING in 1..."
sleep 1
echo "🔴 RECORDING NOW — read the script!"
echo ""

# Record raw PCM then convert to clean WAV
parecord --device="$SOURCE" \
    --format=s16le --rate=24000 --channels=1 \
    --raw /tmp/voice_raw_${NAME}.raw &
REC_PID=$!

# Countdown timer
for i in $(seq "$DURATION" -1 1); do
    printf "\r  ⏱  %02d seconds remaining..." "$i"
    sleep 1
done

kill $REC_PID 2>/dev/null
wait $REC_PID 2>/dev/null
echo ""
echo ""

# Convert to WAV (24kHz mono, matching Pocket TTS sample rate)
sox -r 24000 -e signed -b 16 -c 1 /tmp/voice_raw_${NAME}.raw /tmp/voice_raw_${NAME}.wav
rm -f /tmp/voice_raw_${NAME}.raw

# Clean audio: remove muddiness, add clarity, normalize
sox /tmp/voice_raw_${NAME}.wav "$OUTPUT" \
    highpass 100 \
    bass -4 300 \
    treble +4 3000 \
    norm -1
rm -f /tmp/voice_raw_${NAME}.wav

# Show file info
FILESIZE=$(du -h "$OUTPUT" | cut -f1)
echo "✅ Saved: ${OUTPUT} (${FILESIZE}) — cleaned & normalized"
echo ""

# Quick test with Pocket TTS
echo "Testing voice clone with Pocket TTS..."
./venv/bin/python -c "
from pocket_tts import TTSModel
import scipy.io.wavfile, time

t0 = time.monotonic()
model = TTSModel.load_model()
voice = model.get_state_for_audio_prompt('${OUTPUT}')
load_ms = (time.monotonic() - t0) * 1000

t0 = time.monotonic()
audio = model.generate_audio(voice, 'Hello, this is my cloned voice. How does it sound?')
gen_ms = (time.monotonic() - t0) * 1000

scipy.io.wavfile.write('/tmp/voice_test_${NAME}.wav', model.sample_rate, audio.numpy())
print(f'  🧠 Model+voice loaded in {load_ms:.0f}ms')
print(f'  🗣️  Generated test audio in {gen_ms:.0f}ms')
print(f'  🔊 Playing test...')
" && paplay /tmp/voice_test_${NAME}.wav

echo ""
echo "Done! To use this voice in the pipeline:"
echo "  Edit .env → POCKET_VOICE=voices/${NAME}.wav"
echo ""
echo "To export for faster loading:"
echo "  ./venv/bin/python -c \"from pocket_tts import TTSModel, export_model_state; m=TTSModel.load_model(); v=m.get_state_for_audio_prompt('${OUTPUT}'); export_model_state(v, 'voices/${NAME}.safetensors')\""
echo "  Then set: POCKET_VOICE=voices/${NAME}.safetensors"
