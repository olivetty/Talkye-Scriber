# Meeting Assistant — Design Document

## Overview

Mode 2 al Talkye Meet: capturezi audio-ul unui meeting (Google Meet, Zoom, orice),
identifici cine vorbeste (diarizare), transcrii per speaker, si la final generezi
un summary pe care il poti trimite la un endpoint.

Totul local, fara bot in meeting. Aplicatia sta pe desktop-ul tau si asculta.


## Arhitectura

```
Google OAuth (Sign In)
        |
        v
Google Calendar API ──> Lista participanti (nume, email)
Google Meet REST API ──> Cine e prezent ACUM in call
        |
        v
┌─────────────────────────────────────────────────┐
│                MEETING ASSISTANT                 │
│                                                  │
│  System Audio ──> Silero VAD (exista deja)       │
│                       |                          │
│                  Speech Segments                 │
│                       |                          │
│              ┌────────┴────────┐                 │
│              |                 |                  │
│        Parakeet STT     WeSpeaker Embedding      │
│        (transcript)     (voice fingerprint)      │
│              |                 |                  │
│              └────────┬────────┘                  │
│                       |                          │
│              Speaker Clustering                  │
│              (cosine similarity)                 │
│                       |                          │
│         "Oliver: Buna ziua, azi discutam..."     │
│                       |                          │
│              Session Transcript Store            │
│                       |                          │
│              ┌────────┴────────┐                 │
│              |                 |                  │
│         LLM Summary      Export POST             │
│         (Groq API)       (endpoint)              │
└─────────────────────────────────────────────────┘
```


## Componente


### 1. Google OAuth + Calendar Integration

Sign In with Google in Flutter app. Scopuri OAuth necesare:

- `calendar.readonly` — citim evenimentele cu attendees
- `meetings.space.readonly` — citim participantii activi din Meet

Flow:
1. User face Sign In with Google la prima utilizare
2. Token-ul OAuth se salveaza local (refresh token persistent)
3. La pornirea Mode 2, citim calendar-ul zilei curente
4. Gasim meeting-ul activ (sau urmatorul) — extragem attendees[]
5. Fiecare attendee are: displayName, email, responseStatus (accepted/declined)

Google Calendar event response (relevant):
```json
{
  "summary": "Weekly Standup",
  "attendees": [
    {"email": "oliver@company.com", "displayName": "Oliver", "responseStatus": "accepted"},
    {"email": "maria@company.com", "displayName": "Maria", "responseStatus": "accepted"}
  ],
  "conferenceData": {
    "conferenceId": "abc-defg-hij",
    "conferenceSolution": {"name": "Google Meet"}
  }
}
```

Google Meet REST API — participants activi:
```
GET /v2/conferenceRecords/{id}/participants
```
Returneaza: signedinUser (displayName + userId), anonymousUser, phoneUser.
Putem face polling la fiecare 30s pentru a vedea cine intra/iese.


### 2. Speaker Diarization (pyannote-rs)

Crate: `pyannote-rs` v0.3.4 (Rust, ONNX Runtime)

Modele necesare (descarcate o singura data):
- `segmentation-3.0.onnx` (~5MB) — pyannote segmentation
- `wespeaker-voxceleb-resnet34-LM.onnx` (~25MB) — speaker embeddings

Cum functioneaza:
1. Silero VAD (exista deja) detecteaza segmente de speech
2. Fiecare segment (1-10s) → wespeaker model → embedding vector (256 dim)
3. Cosine similarity intre embedding-uri → clustering
4. Rezultat: "Speaker 0", "Speaker 1", etc.

Adaptare pentru streaming (pyannote-rs e batch by default):
- Nu folosim segmentation model-ul lor (avem Silero VAD, mai bun pentru streaming)
- Folosim DOAR wespeaker embedding model
- La fiecare segment detectat de VAD → extragem embedding → comparam cu speakerii cunoscuti
- Threshold cosine similarity: ~0.65 = same speaker, < 0.65 = new speaker

Alternativ: putem folosi wespeaker ONNX direct cu `ort` (fara pyannote-rs),
daca crate-ul nu se potriveste cu streaming-ul nostru.


### 3. Voice Enrollment + Speaker Profiles

Doua moduri de a asocia un speaker cu un nume:

**A. Automatic (cu Calendar)**
1. Stim ca in meeting sunt Oliver, Maria, Alex (din Calendar)
2. Primii 3 speakeri detectati → ii asociem in ordinea in care vorbesc
3. User-ul confirma/corecteaza din UI: "Speaker 1 e de fapt Maria, nu Alex"

**B. Manual**
1. User-ul introduce manual numele participantilor
2. Sau pur si simplu "Speaker 1", "Speaker 2" cu optiune de redenumire

**Voice Profile Database:**
- JSON local: `~/.talkye/voice_profiles.json`
- Stocam embedding-ul mediu per persoana (media ultimelor N segmente)
- La meeting-uri viitoare, recunoastem automat vocile cunoscute
- Format:
```json
{
  "profiles": [
    {
      "name": "Oliver",
      "email": "oliver@company.com",
      "embedding": [0.12, -0.34, ...],  // 256 float32
      "updated_at": "2026-02-21T10:00:00Z",
      "sample_count": 47
    }
  ]
}
```


### 4. Meeting Pipeline (Mode 2)

Diferente fata de Mode 1 (Live Translation):

| Aspect | Mode 1 (Translation) | Mode 2 (Meeting Assistant) |
|--------|----------------------|---------------------------|
| STT | Parakeet/Deepgram | Parakeet/Deepgram (identic) |
| Dupa STT | Accumulator → Translate → TTS | Diarize → Attribute → Store |
| Output | Audio tradus | Transcript per speaker |
| Real-time | Da (audio output) | Da (text in UI) |
| La final | - | Summary + Export |

Pipeline Mode 2:
```
Audio Capture → VAD → Speech Segment
                        |
                   ┌────┴────┐
                   |         |
              STT (text)  Embedding (who)
                   |         |
                   └────┬────┘
                        |
                  Attributed Segment
                  {speaker: "Oliver", text: "...", timestamp: ...}
                        |
                  Session Store (in-memory Vec)
                        |
                  ┌─────┴─────┐
                  |           |
             Live UI     End of Meeting
             (scroll)         |
                         LLM Summary
                              |
                         Export POST
```


### 5. Session Transcript Store

In-memory during meeting, persist la final:

```rust
struct MeetingSession {
    id: String,                    // UUID
    title: String,                 // din Calendar sau manual
    started_at: DateTime,
    ended_at: Option<DateTime>,
    participants: Vec<Participant>,
    segments: Vec<TranscriptSegment>,
}

struct Participant {
    id: u8,                        // speaker index (0-7)
    name: String,                  // din Calendar sau manual
    email: Option<String>,
    embedding: Vec<f32>,           // voice embedding mediu
}

struct TranscriptSegment {
    speaker_id: u8,
    text: String,
    start_ms: u64,
    end_ms: u64,
    confidence: f32,               // STT confidence
}
```

Salvare: `~/.talkye/meetings/{id}.json`


### 6. LLM Summary

La finalul meeting-ului, trimitem tot transcript-ul la Groq:

Prompt:
```
You are a meeting summarizer. Given the following transcript with speaker labels,
generate a concise summary with:
1. Key topics discussed
2. Decisions made
3. Action items (with assigned person if mentioned)
4. Next steps

Transcript:
[Oliver 00:01] Buna ziua, azi discutam despre lansarea produsului...
[Maria 02:15] Eu am terminat design-ul, trebuie sa...
...
```

Model: llama-3.3-70b-versatile (Groq, deja il avem)
Output: Markdown summary


### 7. Export Endpoint

POST request cu meeting data:

```json
{
  "meeting_id": "uuid",
  "title": "Weekly Standup",
  "date": "2026-02-21",
  "duration_minutes": 45,
  "participants": ["Oliver", "Maria", "Alex"],
  "summary": "...",
  "action_items": [...],
  "full_transcript": [
    {"speaker": "Oliver", "text": "...", "timestamp": "00:01:23"}
  ]
}
```

Endpoint configurabil in Settings (URL + optional API key header).


### 8. Flutter UI — Mode 2

Ecranul principal Mode 2:
```
┌──────────────────────────────┐
│  ● Meeting Assistant    LIVE │
│  Weekly Standup              │
│  3 participants              │
├──────────────────────────────┤
│                              │
│  [Oliver] 00:01              │
│  Buna ziua, azi discutam     │
│  despre lansarea produsului  │
│                              │
│  [Maria] 02:15               │
│  Eu am terminat design-ul    │
│                              │
│  [Alex] 03:42                │
│  Trebuie sa vorbim si despre │
│  buget                       │
│                              │
│  ● Oliver vorbeste...        │
├──────────────────────────────┤
│  [Stop] [Summary] [Export]   │
└──────────────────────────────┘
```

Navigare intre moduri: tab bar sau dropdown in header.
- Mode 1: Live Translation (icon: translate)
- Mode 2: Meeting Assistant (icon: groups)


## Platforme suportate

| Platforma meeting | Audio capture | Lista participanti |
|---|---|---|
| Google Meet | System audio (exista) | Calendar API + Meet REST API |
| Zoom | System audio (exista) | Calendar API (daca e in Google Cal) sau manual |
| Microsoft Teams | System audio (exista) | Manual |
| Discord / orice | System audio (exista) | Manual |


## Dependente noi

| Crate/Plugin | Scop | Size |
|---|---|---|
| pyannote-rs (sau wespeaker ONNX direct) | Speaker embeddings | ~25MB model |
| google_sign_in (Flutter) | OAuth Sign In | Flutter plugin |
| googleapis / http (Dart) | Calendar + Meet API calls | Dart packages |
| uuid (Rust) | Meeting session IDs | Minimal |


## Modele de descarcat

| Model | Size | Sursa |
|---|---|---|
| wespeaker-voxceleb-resnet34-LM.onnx | ~25MB | HuggingFace |
| (optional) segmentation-3.0.onnx | ~5MB | HuggingFace |

Se pun in `models/` alaturi de parakeet-tdt si silero_vad.onnx.


## Faze de implementare

### Faza 1: Diarizare de baza (fara Google)
1. Integram wespeaker ONNX pentru speaker embeddings
2. Speaker clustering cu cosine similarity
3. Pipeline Mode 2: VAD → STT + Embedding → Attributed transcript
4. UI simpla cu transcript per speaker
5. Manual participant names

### Faza 2: Google Integration
1. Sign In with Google in Flutter
2. Google Calendar API — lista meeting-uri + attendees
3. Auto-match speakers cu attendees
4. Voice profile database

### Faza 3: Summary + Export
1. LLM summary la finalul meeting-ului
2. Export POST la endpoint configurabil
3. Meeting history (lista meeting-uri anterioare)
4. Re-export / re-summarize

### Faza 4: Polish
1. Google Meet REST API — participanti activi real-time
2. Voice enrollment flow (guided)
3. Meeting templates
4. Keyboard shortcuts (start/stop/mark)


## Riscuri si mitigari

| Risc | Impact | Mitigare |
|---|---|---|
| Diarizare imprecisa pe audio mixat | Mediu | Threshold tuning, user correction in UI |
| Overlapping speech (2 vorbesc simultan) | Mediu | Marcam ca "multiple speakers", nu atribuim |
| Google OAuth review process | Scazut | Incepem cu "Testing" mode (100 useri) |
| pyannote-rs incompatibil cu streaming | Scazut | Folosim wespeaker ONNX direct cu ort |
| Meeting lung (2h+) → memorie | Scazut | Flush periodic la disk |


## Note tehnice

- Speaker embedding extraction: ~5-10ms per segment pe CPU (wespeaker e mic)
- Cosine similarity: O(n) per segment (n = numar speakeri, max ~10)
- Nu avem nevoie de GPU pentru diarizare — totul CPU
- Parakeet STT ruleaza in paralel cu embedding extraction (tokio tasks)
- Mode 1 si Mode 2 partajeaza: audio capture, VAD, STT, config
- Diferenta e doar ce se intampla DUPA STT
