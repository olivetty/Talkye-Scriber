#!/usr/bin/env python3
"""Real-time speech translation: RO → EN

Pipeline: Microphone → Deepgram STT (streaming) → Groq translate → Pocket TTS (voice clone)
Config: see .env and docs/live-translation.md

Usage: ./venv/bin/python test_deepgram.py
"""

import os, sys, subprocess, threading, time, json, queue
from dotenv import load_dotenv
load_dotenv()

API_KEY = os.getenv("DEEPGRAM_API_KEY")
GROQ_KEY = os.getenv("GROQ_API_KEY", "")
if not API_KEY:
    print("ERROR: Set DEEPGRAM_API_KEY in .env"); sys.exit(1)
if not GROQ_KEY:
    print("ERROR: Set GROQ_API_KEY in .env"); sys.exit(1)

LANGUAGE = os.getenv("DICTATE_LANGUAGE", "ro")
SOURCE = os.getenv("DICTATE_SOURCE_NAME", "")
POCKET_VOICE = os.getenv("POCKET_VOICE", "alba")
POCKET_SPEED = float(os.getenv("POCKET_SPEED", "1.0"))
DG_ENDPOINTING = os.getenv("DEEPGRAM_ENDPOINTING", "500")
DG_UTTERANCE_END = os.getenv("DEEPGRAM_UTTERANCE_END", "1500")
ACCUM_MIN_WORDS = int(os.getenv("ACCUM_MIN_WORDS", "8"))
ACCUM_FIRST_WORDS = int(os.getenv("ACCUM_FIRST_WORDS", "4"))

import openai
groq_client = openai.OpenAI(api_key=GROQ_KEY, base_url="https://api.groq.com/openai/v1")

translate_q = queue.Queue()
tts_q = queue.Queue()
translation_context = []
segment_fragments = []  # list of (ro_fragment, en_translation) sent so far in this segment
segment_lock = threading.Lock()  # protects segment_fragments and translation_context
CONTEXT_SIZE = 4

# ── Pocket TTS ──
pocket_model = None
pocket_voice_state = None

def init_pocket():
    global pocket_model, pocket_voice_state
    if pocket_model is not None:
        return
    from pocket_tts import TTSModel
    t0 = time.monotonic()
    pocket_model = TTSModel.load_model()
    load_ms = (time.monotonic() - t0) * 1000

    voice = POCKET_VOICE
    t1 = time.monotonic()
    if voice.endswith(".safetensors"):
        from pocket_tts import import_model_state
        pocket_voice_state = import_model_state(voice)
        voice_label = f"{voice} (safetensors)"
    else:
        pocket_voice_state = pocket_model.get_state_for_audio_prompt(voice)
        voice_label = voice
    voice_ms = (time.monotonic() - t1) * 1000
    print(f"🗣️  Pocket TTS loaded in {load_ms:.0f}ms + voice '{voice_label}' in {voice_ms:.0f}ms (sr={pocket_model.sample_rate})")


def speak_pocket(text):
    """Stream TTS via Pocket → paplay. Returns (first_chunk_ms, total_ms)."""
    import numpy as np
    t0 = time.monotonic()
    first_chunk_ms = 0
    sr = pocket_model.sample_rate
    play_rate = int(sr * POCKET_SPEED)

    player = subprocess.Popen(
        ["paplay", "--format=s16le", f"--rate={play_rate}", "--channels=1", "--raw"],
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )
    try:
        first = True
        for chunk in pocket_model.generate_audio_stream(pocket_voice_state, text):
            pcm = chunk.cpu().numpy()
            pcm = np.clip(pcm, -1.0, 1.0)
            pcm_int16 = (pcm * 32767).astype(np.int16)
            if first:
                first_chunk_ms = (time.monotonic() - t0) * 1000
                first = False
            try:
                player.stdin.write(pcm_int16.tobytes())
                player.stdin.flush()
            except BrokenPipeError:
                break
    finally:
        try: player.stdin.close()
        except: pass
        player.wait()

    total_ms = (time.monotonic() - t0) * 1000
    return first_chunk_ms, total_ms


def find_source():
    if not SOURCE: return None
    try:
        out = subprocess.check_output(["pactl", "list", "sources", "short"], text=True)
        for line in out.strip().split("\n"):
            if SOURCE in line: return line.split("\t")[1]
    except: pass
    return None


def translate_worker():
    """Translate phrases in parallel, output to TTS in order."""
    import concurrent.futures
    seq = [0]  # sequence counter
    pending = {}  # seq_num → result
    next_to_send = [0]  # next sequence number to send to TTS
    lock = threading.Lock()

    def do_translate(ro_text, t_user_spoke, t_final, seq_num):
        t0 = time.monotonic()
        try:
            ctx = ""
            with segment_lock:
                if segment_fragments:
                    prev = " → ".join(f"'{ro}' = '{en}'" for ro, en in segment_fragments[-3:])
                    ctx = f"Previous parts of same sentence: {prev}\nContinue translating naturally.\n\n"
                elif translation_context:
                    pairs = [f"{ro} → {en}" for ro, en in translation_context[-CONTEXT_SIZE:]]
                    ctx = f"Recent:\n" + "\n".join(pairs) + "\n\n"
            resp = groq_client.chat.completions.create(
                model="llama-3.3-70b-versatile",
                messages=[
                    {"role": "system", "content":
                     "You are a real-time Romanian to English interpreter in a live conversation. "
                     "Translate naturally. Output ONLY the English translation, nothing else. "
                     "If given previous parts of the same sentence, ensure your translation flows naturally as a continuation."},
                    {"role": "user", "content": f"{ctx}Translate: {ro_text}"},
                ],
                max_tokens=200, temperature=0.1,
            )
            en_text = resp.choices[0].message.content.strip()
            translate_ms = (time.monotonic() - t0) * 1000
            with segment_lock:
                segment_fragments.append((ro_text, en_text))
                translation_context.append((ro_text, en_text))
                if len(translation_context) > CONTEXT_SIZE * 2:
                    translation_context[:] = translation_context[-CONTEXT_SIZE:]
            return (en_text, ro_text, translate_ms, t_user_spoke, t_final, seq_num)
        except Exception as e:
            print(f"  ⚠ Translate error: {e}")
            return None

    def on_done(future):
        try:
            result = future.result()
        except Exception as e:
            print(f"  ⚠ Translate future error: {e}")
            return
        if not result:
            return
        seq_num = result[5]
        with lock:
            pending[seq_num] = result
            # Flush in order
            while next_to_send[0] in pending:
                r = pending.pop(next_to_send[0])
                tts_q.put(r[:5])  # (en_text, ro_text, translate_ms, t_user_spoke, t_final)
                next_to_send[0] += 1

    pool = concurrent.futures.ThreadPoolExecutor(max_workers=3, thread_name_prefix="translate")

    while True:
        ro_text, t_user_spoke, t_final = translate_q.get()
        s = seq[0]
        seq[0] += 1
        fut = pool.submit(do_translate, ro_text, t_user_spoke, t_final, s)
        fut.add_done_callback(on_done)


def tts_worker():
    """Play translated phrases via Pocket TTS — sequential, no dropping."""
    while True:
        en_text, ro_text, translate_ms, t_first_heard, t_final = tts_q.get()

        print(f"  🇷🇴 {ro_text}")
        print(f"  🇬🇧 {en_text}  (translate: {translate_ms:.0f}ms)")

        try:
            t_before = time.monotonic()
            fc_ms, total_ms = speak_pocket(en_text)
            # Latency from is_final to first sound
            pipeline_ms = (t_before - t_final) * 1000 + fc_ms
            # TRUE latency: from first interim (when Deepgram first heard speech) to first TTS sound
            sound_to_sound = (t_before - t_first_heard) * 1000 + fc_ms
            e2e = (time.monotonic() - t_first_heard) * 1000
            print(f"  ⏱  🔊 {sound_to_sound:.0f}ms sunet→sunet | pipeline={pipeline_ms:.0f}ms | tts={fc_ms:.0f}ms | e2e={e2e:.0f}ms")
            print(f"  {'─'*50}")
        except Exception as e:
            print(f"  ⚠ TTS error: {e}")


def main():
    import websocket

    init_pocket()

    source = find_source()
    rec_args = ["parecord", "--format=s16le", "--rate=16000", "--channels=1",
                "--raw", "--latency-msec=30", "/dev/stdout"]
    if source:
        rec_args.insert(1, f"--device={source}")
        print(f"🎤 Audio: {source}")
    mic = subprocess.Popen(rec_args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)

    # Wall clock time when audio stream started (set on first audio send)
    stream_start = [0.0]

    lang = LANGUAGE if LANGUAGE != "auto" else "ro"
    url = (f"wss://api.deepgram.com/v1/listen"
           f"?model=nova-3&language={lang}&encoding=linear16"
           f"&sample_rate=16000&channels=1&interim_results=true"
           f"&smart_format=true&endpointing={DG_ENDPOINTING}"
           f"&utterance_end_ms={DG_UTTERANCE_END}&vad_events=true")

    # ── Accumulator: collect is_final words, flush when big enough or speech ends ──
    accum_words = []           # accumulated words from consecutive is_finals
    accum_t_spoke = [0.0]     # wall-clock time when user said first word of accumulated chunk
    first_flushed = [False]   # True after first flush — switches to higher threshold

    def flush_accum(t_final):
        """Send accumulated words to translation and reset."""
        if not accum_words:
            return
        text = " ".join(accum_words)
        t_spoke = accum_t_spoke[0] if accum_t_spoke[0] > 0 else t_final
        print(f"  → flush ({len(accum_words)}w): {text}")
        translate_q.put((text, t_spoke, t_final))
        accum_words.clear()
        accum_t_spoke[0] = 0.0
        first_flushed[0] = True

    def on_message(ws, msg):
        data = json.loads(msg)
        msg_type = data.get("type", "")

        if msg_type == "UtteranceEnd":
            print(f"  ── utterance end ──")
            flush_accum(time.monotonic())
            with segment_lock:
                segment_fragments.clear()
            first_flushed[0] = False
            return

        if msg_type != "Results":
            return

        alt = data["channel"]["alternatives"][0]
        transcript = alt["transcript"]
        is_final = data.get("is_final", False)
        speech_final = data.get("speech_final", False)

        if not transcript:
            if speech_final:
                print(f"  ── pause ──")
                flush_accum(time.monotonic())
            return

        if is_final:
            t_now = time.monotonic()
            words = alt.get("words", [])
            word_texts = [w["word"] for w in words]
            first_word_start = words[0]["start"] if words else 0
            t_user_spoke = stream_start[0] + first_word_start if stream_start[0] > 0 else t_now

            print(f"  ✓ {transcript}" + (" ◼" if speech_final else ""))

            # Set timing for first word in this accumulation batch
            if accum_t_spoke[0] == 0.0:
                accum_t_spoke[0] = t_user_spoke

            accum_words.extend(word_texts)

            # First flush at lower threshold, then switch to higher
            threshold = ACCUM_FIRST_WORDS if not first_flushed[0] else ACCUM_MIN_WORDS
            if len(accum_words) >= threshold or speech_final:
                flush_accum(t_now)
                if speech_final:
                    with segment_lock:
                        segment_fragments.clear()
                    first_flushed[0] = False
        else:
            print(f"  ... {transcript}          ", end="\r", flush=True)

    def on_error(ws, error):
        if "closed" not in str(error).lower():
            print(f"WS Error: {error}")

    def on_open(ws):
        print("✅ Connected! Speak Romanian...\n")
        def send_audio():
            try:
                stream_start[0] = time.monotonic()
                while True:
                    data = mic.stdout.read(4096)
                    if not data: break
                    ws.send(data, opcode=websocket.ABNF.OPCODE_BINARY)
            except Exception: pass
            finally:
                try: ws.send(json.dumps({"type": "CloseStream"}))
                except: pass
        threading.Thread(target=send_audio, daemon=True).start()

    def on_close(ws, code, reason):
        print(f"Connection closed ({code})")

    # Start workers
    threading.Thread(target=translate_worker, daemon=True).start()
    threading.Thread(target=tts_worker, daemon=True).start()

    print(f"Pipeline: RO → Deepgram STT (endpointing={DG_ENDPOINTING}ms) → Groq → Pocket TTS")
    print(f"  Voice: {POCKET_VOICE} | Speed: {POCKET_SPEED}x")
    print(f"  Mode: accumulator (first flush at {ACCUM_FIRST_WORDS}w, then {ACCUM_MIN_WORDS}w)\n")

    ws = websocket.WebSocketApp(
        url,
        header={"Authorization": f"Token {API_KEY}"},
        on_open=on_open,
        on_message=on_message,
        on_error=on_error,
        on_close=on_close,
    )
    try:
        ws.run_forever()
    except KeyboardInterrupt:
        print("\nStopping...")
    finally:
        try: mic.kill()
        except: pass

if __name__ == "__main__":
    main()
