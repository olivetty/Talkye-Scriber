# Talkye Scriber — AppImage Distribution Plan

## Goal
Single `TalkyeScriber-x86_64.AppImage` file that anyone on Linux can download and run.
First run: auto-setup + download whisper model. Subsequent runs: instant. Auto-updates from GitHub Releases.

---

## Phase 1: Flexible Paths (sidecar + Flutter)

### 1.1 — sidecar/config.py
- [ ] `WHISPER_BIN`: search order: `$TALKYE_WHISPER_BIN` env → `<appdir>/usr/whisper/whisper-cli` → `<project_root>/whisper.cpp/build/bin/whisper-cli`
- [ ] `WHISPER_MODEL`: keep `~/.config/talkye/models/ggml-large-v3-turbo.bin` (user home, persists across updates)
- [ ] Add `APPDIR` detection from `$APPDIR` env var (set by AppImage runtime)

### 1.2 — app/lib/main.dart (_startSidecar)
- [ ] Add candidate path: `$TALKYE_SIDECAR_DIR` env var (AppImage layout)
- [ ] Use `$TALKYE_PYTHON` env var for Python binary (bundled), fallback to system `python3`
- [ ] Ensure `setup.sh` receives `TALKYE_PYTHON` so venv uses bundled Python
- [ ] Pass `TALKYE_WHISPER_BIN` env var to sidecar process pointing to bundled whisper-cli

### 1.3 — Test
- [ ] Verify app still works in dev mode (current paths still work)
- [ ] Build release, verify paths resolve correctly

---

## Phase 2: First-Run Setup Screen

### 2.1 — Model download endpoint in sidecar
- [ ] New endpoint `GET /setup/status` → returns `{ "model_exists": bool, "model_path": str, "venv_ready": bool }`
- [ ] New endpoint `POST /setup/download-model` → starts download of `ggml-large-v3-turbo.bin` from Hugging Face
- [ ] New endpoint `GET /setup/download-progress` → returns `{ "downloading": bool, "bytes_downloaded": int, "bytes_total": int }`
- [ ] URL: `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin`
- [ ] Download to `~/.config/talkye/models/ggml-large-v3-turbo.bin`

### 2.2 — Flutter setup screen
- [ ] New `SetupScreen` widget in `app/lib/screens/setup_screen.dart`
- [ ] Shown when model is missing (check file existence directly from Dart, no sidecar needed)
- [ ] Progress bar: "Downloading speech model... 45% (720 MB / 1.6 GB)"
- [ ] Download directly from Dart (HttpClient) — no sidecar dependency for this step
- [ ] When done → transition to DictateScreen
- [ ] Sidecar venv setup happens automatically when sidecar starts (existing setup.sh)

### 2.3 — AppShell routing
- [ ] On startup, check if `~/.config/talkye/models/ggml-large-v3-turbo.bin` exists
- [ ] If missing → show SetupScreen
- [ ] If exists → show DictateScreen (current behavior)

### 2.4 — Test
- [ ] Rename/move model file temporarily
- [ ] Run app → should show setup screen
- [ ] Download completes → transitions to Scriber
- [ ] Run app again → goes straight to Scriber

---

## Phase 3: Auto-Update

### 3.1 — Version management
- [ ] Define version constant in `app/lib/version.dart`: `const appVersion = '0.3.0';`
- [ ] Show version in status bar (already shows "Talkye Scriber v0.3.0")
- [ ] GitHub Release tag format: `v0.3.0`

### 3.2 — Update check
- [ ] On startup (after setup screen passes), check `https://api.github.com/repos/olivetty/Talkye-Meet-Assistant/releases/latest`
- [ ] Compare `tag_name` with `appVersion`
- [ ] If newer version exists, find asset matching `TalkyeScriber-*.AppImage`

### 3.3 — Update flow
- [ ] Show subtle indicator in status bar or header: "Update v0.4.0 available"
- [ ] User clicks → confirmation dialog
- [ ] Download new AppImage to `$APPIMAGE.new` (temp file next to current)
- [ ] Progress bar in dialog: "Downloading update... 65%"
- [ ] When done: `chmod +x`, rename `$APPIMAGE.new` → `$APPIMAGE`
- [ ] Restart: `Process.start($APPIMAGE, [])` then `exit(0)`
- [ ] If `$APPIMAGE` env not set (not running as AppImage) → show "Download from GitHub" link instead

### 3.4 — Test
- [ ] Set `appVersion` to old value, publish a release on GitHub
- [ ] Run AppImage → should show update available
- [ ] Click update → downloads, replaces, restarts
- [ ] After restart → new version, no update notification

---

## Phase 4: AppImage Build Script

### 4.1 — `build-appimage.sh`
- [ ] Location: project root `build-appimage.sh`
- [ ] Steps:
  1. `flutter build linux --release` (in app/)
  2. Download Python standalone from astral-sh/python-build-standalone (if not cached)
  3. Create AppDir structure:
     ```
     TalkyeScriber.AppDir/
     ├── AppRun
     ├── talkye-scriber.desktop
     ├── talkye-scriber.png
     └── usr/
         ├── bin/
         │   └── talkye_app (Flutter binary)
         ├── lib/
         │   └── *.so (Flutter libs)
         ├── data/
         │   └── (Flutter data assets)
         ├── python/
         │   └── (python-build-standalone, ~30MB)
         ├── sidecar/
         │   ├── *.py
         │   ├── sounds/
         │   ├── requirements-base.txt
         │   └── setup.sh
         ├── sox/
         │   ├── sox (binary)
         │   └── lib/ (libsox.so.3, libltdl.so.7, libgsm.so.1)
         └── whisper/
             └── whisper-cli
     ```
  4. Create `AppRun` script (sets env vars, launches binary)
  5. Create `.desktop` file
  6. Copy icon
  7. Download `appimagetool` if not present
  8. Run `appimagetool` → output `TalkyeScriber-x86_64.AppImage`

### 4.2 — AppRun script
- [ ] Set `APPDIR` to script's directory
- [ ] Set `LD_LIBRARY_PATH` to include `$APPDIR/usr/lib`
- [ ] Set `TALKYE_WHISPER_BIN=$APPDIR/usr/whisper/whisper-cli`
- [ ] Set `TALKYE_SIDECAR_DIR=$APPDIR/usr/sidecar`
- [ ] Set `TALKYE_PYTHON=$APPDIR/usr/python/bin/python3` (bundled Python)
- [ ] Set `TALKYE_SOX=$APPDIR/usr/sox/sox` (bundled sox)
- [ ] Prepend `$APPDIR/usr/sox/lib` to `LD_LIBRARY_PATH` (sox libs)
- [ ] Exec `$APPDIR/usr/bin/talkye_app`

### 4.3 — Test
- [ ] Run `./build-appimage.sh`
- [ ] Verify AppImage is created
- [ ] Run AppImage on clean-ish environment
- [ ] Full flow: setup → download model → Scriber works → dictation works

---

## Phase 5: End-to-End Test

- [ ] Fresh test (rename ~/.config/talkye temporarily)
- [ ] Run AppImage → setup screen appears
- [ ] Model downloads with progress
- [ ] Sidecar starts, Scriber is functional
- [ ] Dictation works (hold key, speak, text appears)
- [ ] Settings persist across restarts
- [ ] Sounds work
- [ ] Auto-update check works
- [ ] Publish to GitHub Releases
- [ ] Share AppImage file with tester

---

## Notes
- Model: `ggml-large-v3-turbo.bin` (1.6GB) — NOT bundled in AppImage, downloaded on first run
- whisper-cli: ~1MB — bundled in AppImage
- Python standalone: ~30MB — bundled (astral-sh/python-build-standalone), zero system deps
- Sidecar Python source: ~50KB — bundled, venv created on first run using bundled Python
- Sound files: ~200KB — bundled
- AppImage size (without model): ~47MB estimated
- ZERO external dependencies. No Python, no pip, no sox, nothing needed on target system.
