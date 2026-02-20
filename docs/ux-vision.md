# Talkye Meet — UX Vision

## Cine e userul

Un profesionist într-un video call (Meet, Zoom, Teams) care vorbește o limbă și trebuie să comunice în alta. Nu e tehnic. Nu vrea să configureze nimic. Vrea să vorbească natural și să funcționeze.

## Insight-ul central

În timpul unui call, userul NU se uită la Talkye. Se uită la video call. Talkye e un co-pilot — prezent dar nu deranjant. UI-ul există pentru încredere ("funcționează") și monitorizare, nu pentru interacțiune activă.

## Momentul WOW

Prima dată când userul își aude propria voce vorbind altă limbă — ăsta e momentul în care decide să plătească $20/lună. Setup wizard-ul trebuie să facă momentul ăsta să se întâmple devreme.

---

## Stările aplicației

### 1. IDLE — gata de start
- System tray icon (gri/neutru)
- Fereastra principală vizibilă sau minimizată
- Un singur click pentru a porni

### 2. ACTIVE — traduce
- System tray icon (verde)
- Fereastra arată transcriptul live
- Status: Listening → Translating → Speaking (ciclic)
- Buton Stop vizibil

### 3. SETTINGS — configurare
- Accesibil din fereastra principală (icon ⚙)
- Limbi, voce, audio, avansat

### 4. FIRST RUN — onboarding
- Wizard pas cu pas la prima deschidere
- Se termină cu momentul WOW (auzi vocea ta tradusă)

---

## Fereastra principală

Dimensiune default: ~420x500px. Poate fi redimensionată. Toggle "always on top" pentru a sta peste video call.

```
┌──────────────────────────────────────────┐
│  ◉ Talkye Meet              ⚙  ─  □  ✕ │
├──────────────────────────────────────────┤
│                                          │
│  RO → EN                    00:12:34  ▼  │
│                                          │
│ ┌──────────────────────────────────────┐ │
│ │                                      │ │
│ │  🎤 Deci, hai să discutăm          │ │
│ │     despre proiectul nou             │ │
│ │  🔊 So, let's discuss the          │ │
│ │     new project                      │ │
│ │                                      │ │
│ │  🎤 Cred că ar trebui să           │ │
│ │     începem cu designul              │ │
│ │  🔊 I think we should start        │ │
│ │     with the design                  │ │
│ │                                      │ │
│ │  🎤 Ce părere ai?                  │ │
│ │  🔊 What do you think?             │ │
│ │                                      │ │
│ │  🎤 ░░░░░░░░                       │ │
│ │     (ascultă...)                     │ │
│ │                                      │ │
│ └──────────────────────────────────────┘ │
│                                          │
│  ● Listening...                          │
│                                          │
│         [ ■  Stop Translation ]          │
│                                          │
└──────────────────────────────────────────┘
```

### Elementele cheie:

**Header**: Logo + settings icon. Curat, fără clutter.

**Language bar**: `RO → EN` cu posibilitate de swap (▼ dropdown). Timer de sesiune. Arată cât timp traduci.

**Transcript area** (hero element):
- Scroll automat în jos
- Fiecare pereche: 🎤 ce ai zis (font mai mic, gri) + 🔊 traducerea (font mai mare, alb/negru)
- Ultima intrare poate fi "în progres" — text parțial cu animație de typing
- Fade subtil pe intrările vechi (nu dispar, doar devin mai puțin proeminente)
- Click pe o intrare → copiază textul

**Status bar**: Un singur rând cu starea curentă:
- `● Listening...` (verde, pulsează ușor)
- `● Translating...` (galben)
- `● Speaking...` (albastru)
- `● Idle` (gri)

**Action button**: Mare, centrat, imposibil de ratat.
- Când idle: `[ ▶ Start Translation ]` (verde)
- Când activ: `[ ■ Stop Translation ]` (roșu)

---

## System Tray

**Left click**: Toggle fereastra principală (show/hide)

**Right click menu**:
```
  ▶ Start Translation  (sau ■ Stop)
  ─────────────────
  Open Talkye Meet
  Settings
  ─────────────────
  Quit
```

**Icon states**:
- Gri: idle, gata de start
- Verde: activ, traduce
- Roșu: eroare (mic deconectat, Groq down, etc.)

---

## Settings

Accesibil din ⚙ în header. Organizat pe tab-uri sau secțiuni:

### Languages
```
┌──────────────────────────────────────────┐
│  Speak:    [ Romanian          ▼ ]       │
│                  ⇅                       │
│  Hear:     [ English           ▼ ]       │
└──────────────────────────────────────────┘
```
- Dropdown cu cele 25 limbi europene suportate de Parakeet TDT v3
- Buton swap ⇅ pentru inversare rapidă

### Voice
```
┌──────────────────────────────────────────┐
│  Your voice clone:                       │
│                                          │
│  ● Oliver (current)          [ ▶ Preview]│
│  ○ Default (Alba)            [ ▶ Preview]│
│                                          │
│  [ 🎤 Record New Voice ]                │
│                                          │
│  Record 10 seconds of natural speech     │
│  for the best voice clone quality.       │
└──────────────────────────────────────────┘
```
- Lista vocilor disponibile cu preview
- Buton de înregistrare voce nouă
- Instrucțiuni clare: "Vorbește natural, 10 secunde"

### Audio
```
┌──────────────────────────────────────────┐
│  Microphone:  [ Enhanced Mic       ▼ ]   │
│               [ 🔊 Test ]               │
│                                          │
│  Speaker:     [ Headphones         ▼ ]   │
│               [ 🔊 Test ]               │
│                                          │
│  Virtual Audio: ✅ Configured            │
│  (Talkye_Mic ready for video calls)      │
│                                          │
│  Speed:       [ 1.0x              ▼ ]    │
└──────────────────────────────────────────┘
```
- Auto-detect dispozitive
- Test buttons pentru verificare
- Status virtual audio (creat automat la start)
- Speed control pentru TTS

### Advanced (collapsed by default)
```
┌──────────────────────────────────────────┐
│  STT Backend:  [ Local (Parakeet)  ▼ ]   │
│  Translation:  Groq (Llama 3.3 70B)     │
│  API Key:      [ gsk_...          ]      │
│                                          │
│  [ Reset to Defaults ]                   │
└──────────────────────────────────────────┘
```

---

## First Run — Onboarding Wizard

5 pași, fiecare pe un ecran curat. Progress bar în sus.

### Step 1: Welcome
```
┌──────────────────────────────────────────┐
│          ○ ○ ○ ○ ○                       │
│                                          │
│          🌍                              │
│                                          │
│     Welcome to Talkye Meet               │
│                                          │
│  Real-time voice translation             │
│  for your video calls.                   │
│  Speak your language,                    │
│  others hear theirs —                    │
│  in your voice.                          │
│                                          │
│        [ Get Started → ]                 │
└──────────────────────────────────────────┘
```

### Step 2: Languages
```
┌──────────────────────────────────────────┐
│          ● ○ ○ ○ ○                       │
│                                          │
│     What languages do you need?          │
│                                          │
│  I speak:    [ Romanian          ▼ ]     │
│                    ↓                     │
│  They hear:  [ English           ▼ ]     │
│                                          │
│  You can change this anytime.            │
│                                          │
│        [ ← Back ]    [ Next → ]          │
└──────────────────────────────────────────┘
```

### Step 3: Audio Check
```
┌──────────────────────────────────────────┐
│          ● ● ○ ○ ○                       │
│                                          │
│     Let's check your audio               │
│                                          │
│  Microphone: Enhanced Mic ✅             │
│  ████████████░░░░ (live level meter)     │
│                                          │
│  Speakers: Headphones ✅                 │
│  [ 🔊 Play Test Sound ]                 │
│                                          │
│  Virtual Audio: Setting up...            │
│  ✅ Talkye_Mic created                  │
│                                          │
│        [ ← Back ]    [ Next → ]          │
└──────────────────────────────────────────┘
```
- Live level meter pe microfon (userul vede că funcționează)
- Test sound pe speakers
- Auto-creare virtual audio devices

### Step 4: Voice Clone (opțional dar recomandat)
```
┌──────────────────────────────────────────┐
│          ● ● ● ○ ○                       │
│                                          │
│     Clone your voice                     │
│                                          │
│  Record 10 seconds of natural speech     │
│  so translations sound like YOU.         │
│                                          │
│         [ 🎤 Start Recording ]           │
│                                          │
│  ████████░░░░░░░░░░  6s / 10s           │
│                                          │
│  Or use a default voice:                 │
│  [ Skip → use default voice ]            │
│                                          │
│        [ ← Back ]    [ Next → ]          │
└──────────────────────────────────────────┘
```
- Progress bar vizual pentru înregistrare
- Opțiune de skip (dar nu e promovată — vrem voice clone)

### Step 5: Test Drive (momentul WOW)
```
┌──────────────────────────────────────────┐
│          ● ● ● ● ○                       │
│                                          │
│     Try it out!                          │
│                                          │
│  Say something in Romanian...            │
│                                          │
│  🎤 "Bună ziua, mă numesc Oliver"      │
│  🔊 "Hello, my name is Oliver"          │
│     ▶ (playing your cloned voice)        │
│                                          │
│  ✨ That's YOUR voice in English!       │
│                                          │
│        [ ← Back ]    [ Done ✓ ]          │
└──────────────────────────────────────────┘
```
- Userul vorbește → aude traducerea cu vocea lui
- ACESTA e momentul WOW
- Dacă funcționează, userul e convins

---

## Comportamente importante

### Auto Virtual Audio
La pornirea traducerii, app-ul:
1. Verifică dacă talkye_out, talkye_combined, talkye_mic există
2. Dacă nu → le creează automat (pactl load-module)
3. Afișează notificare: "Set your video call mic to Talkye_Mic"
4. La oprire: opțional cleanup (sau lasă pentru sesiunea următoare)

### Error Handling vizibil
- Mic deconectat → banner roșu "Microphone disconnected"
- Groq timeout → "Translation delayed, retrying..."
- Model loading → progress bar la start "Loading speech engine..."

### Keyboard Shortcuts
- `Ctrl+Shift+T` — toggle start/stop (global hotkey)
- `Escape` — hide window (nu quit)
- `Ctrl+Q` — quit

### Notificări
- La start: "Talkye Meet is translating. Set your call mic to Talkye_Mic."
- La eroare: "Translation paused — check your connection"
- La stop: "Session ended. 45 minutes, 230 translations."

---

## Design Direction

- Dark mode default (profesioniștii lucrează noaptea)
- Light mode disponibil
- Font: system default (nativ pe fiecare OS)
- Culori: verde (#4CAF50) = activ, gri (#9E9E9E) = idle, roșu (#F44336) = eroare
- Animații subtile: pulsare pe status, fade pe transcript entries
- Rounded corners, shadows ușoare — modern dar nu flashy
- Inspirație: Discord overlay, Krisp, Otter.ai sidebar

---

## Ce NU face (încă)

- Traducere bidirecțională (Phase 3)
- Transcript export / call history (Phase 3+)
- Auto-detect limba vorbită (Parakeet face auto-detect, dar UI-ul nu expune asta încă)
- Multiple language pairs simultane
- Mobile app
- Browser extension
