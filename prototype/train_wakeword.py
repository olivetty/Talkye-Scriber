#!/usr/bin/env python3
"""Train a custom OpenWakeWord model locally.

Follows the exact same process as the official Colab notebook:
https://github.com/dscripka/openWakeWord/blob/main/notebooks/automatic_model_training.ipynb

Prerequisites (run once):
    python3 -m venv /tmp/oww_train
    /tmp/oww_train/bin/pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu121
    /tmp/oww_train/bin/pip install openwakeword piper-tts piper-phonemize-cross webrtcvad pyyaml
    /tmp/oww_train/bin/pip install mutagen torchinfo torchmetrics speechbrain audiomentations
    /tmp/oww_train/bin/pip install torch-audiomentations acoustics pronouncing datasets deep-phonemizer
    git clone https://github.com/dscripka/openWakeWord /tmp/oww_train/openWakeWord
    /tmp/oww_train/bin/pip install -e /tmp/oww_train/openWakeWord
    git clone https://github.com/rhasspy/piper-sample-generator /tmp/oww_train/piper-sample-generator
    wget -O /tmp/oww_train/piper-sample-generator/models/en_US-libritts_r-medium.pt \
        'https://github.com/rhasspy/piper-sample-generator/releases/download/v2.0.0/en_US-libritts_r-medium.pt'

Usage:
    /tmp/oww_train/bin/python train_wakeword.py "hey mira"
"""

import os
import sys
import subprocess
import shutil

import numpy as np
import yaml
import scipy
import scipy.io.wavfile
from pathlib import Path
from tqdm import tqdm

# ── Config ──
TARGET = sys.argv[1] if len(sys.argv) > 1 else "hey mira"
MODEL_NAME = TARGET.replace(" ", "_")
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OWW_DIR = "/tmp/oww_train/openWakeWord"
TRAIN_PY = os.path.join(OWW_DIR, "openwakeword", "train.py")
PYTHON = sys.executable

# Work in a dedicated directory
WORK_DIR = "/tmp/oww_train/training"
os.makedirs(WORK_DIR, exist_ok=True)
os.chdir(WORK_DIR)

print(f"Training wake word: '{TARGET}'")
print(f"Working directory: {WORK_DIR}")
print()

# ── Step 0: Ensure piper-sample-generator is accessible from WORK_DIR ──
PSG_SRC = "/tmp/oww_train/piper-sample-generator"
PSG_LINK = os.path.join(WORK_DIR, "piper-sample-generator")
if os.path.isdir(PSG_SRC) and not os.path.exists(PSG_LINK):
    os.symlink(PSG_SRC, PSG_LINK)
    print(f"Symlinked piper-sample-generator → {PSG_LINK}")

# ── Step 0b: Download embedding/melspectrogram models if missing ──
RESOURCES_DIR = os.path.join(OWW_DIR, "openwakeword", "resources", "models")
os.makedirs(RESOURCES_DIR, exist_ok=True)
MODEL_FILES = [
    "embedding_model.onnx",
    "embedding_model.tflite",
    "melspectrogram.onnx",
    "melspectrogram.tflite",
]
BASE_URL = "https://github.com/dscripka/openWakeWord/releases/download/v0.5.1"
for mf in MODEL_FILES:
    dest = os.path.join(RESOURCES_DIR, mf)
    if not os.path.isfile(dest):
        print(f"Downloading {mf}...")
        subprocess.run(["wget", "-q", "-O", dest, f"{BASE_URL}/{mf}"], check=True)
    else:
        print(f"Already have {mf}")
print()

# ── Step 1: Download Room Impulse Responses ──
print("=" * 60)
print("STEP 1: Downloading MIT Room Impulse Responses...")
print("=" * 60)

output_dir = "./mit_rirs"
if not os.path.exists(output_dir) or len(os.listdir(output_dir)) < 10:
    os.makedirs(output_dir, exist_ok=True)
    import datasets
    rir_dataset = datasets.load_dataset(
        "davidscripka/MIT_environmental_impulse_responses", split="train", streaming=True
    )
    for row in tqdm(rir_dataset, desc="RIRs"):
        name = row['audio']['path'].split('/')[-1]
        scipy.io.wavfile.write(
            os.path.join(output_dir, name), 16000,
            (row['audio']['array'] * 32767).astype(np.int16)
        )
    print(f"Downloaded {len(os.listdir(output_dir))} RIR files")
else:
    print(f"Already have {len(os.listdir(output_dir))} RIR files, skipping")

# ── Step 2: Download background noise (AudioSet + FMA) ──
print("\n" + "=" * 60)
print("STEP 2: Downloading background noise datasets...")
print("=" * 60)

import datasets as ds

# AudioSet — download balanced train split via HuggingFace datasets API
audioset_dir = "./audioset_16k"
if not os.path.exists(audioset_dir) or len(os.listdir(audioset_dir)) < 10:
    os.makedirs(audioset_dir, exist_ok=True)
    print("Downloading AudioSet balanced train split via HuggingFace...")
    audioset_dataset = ds.load_dataset(
        "agkphysics/AudioSet", "balanced", split="train", streaming=True,
    )
    audioset_dataset = audioset_dataset.cast_column("audio", ds.Audio(sampling_rate=16000))
    count = 0
    for row in tqdm(audioset_dataset, desc="AudioSet"):
        name = row['audio']['path'].split('/')[-1].replace(".flac", ".wav")
        scipy.io.wavfile.write(
            os.path.join(audioset_dir, name), 16000,
            (row['audio']['array'] * 32767).astype(np.int16)
        )
        count += 1
    print(f"AudioSet: {count} files")
else:
    print(f"AudioSet already downloaded ({len(os.listdir(audioset_dir))} files)")

# FMA (1 hour) — download non-streaming (zip format doesn't support streaming)
fma_dir = "./fma"
if not os.path.exists(fma_dir) or len(os.listdir(fma_dir)) < 10:
    os.makedirs(fma_dir, exist_ok=True)
    print("Downloading FMA dataset (non-streaming, this may take a few minutes)...")
    fma_dataset = ds.load_dataset("rudraml/fma", name="small", split="train")
    fma_dataset = fma_dataset.cast_column("audio", ds.Audio(sampling_rate=16000))
    n_hours = 1
    n_clips = n_hours * 3600 // 30
    for i in tqdm(range(min(n_clips, len(fma_dataset))), desc="FMA"):
        row = fma_dataset[i]
        name = row['audio']['path'].split('/')[-1].replace(".mp3", ".wav")
        scipy.io.wavfile.write(
            os.path.join(fma_dir, name), 16000,
            (row['audio']['array'] * 32767).astype(np.int16)
        )
    print(f"FMA: {len(os.listdir(fma_dir))} files")
else:
    print(f"FMA already downloaded ({len(os.listdir(fma_dir))} files)")

# ── Step 3: Download pre-computed features ──
print("\n" + "=" * 60)
print("STEP 3: Downloading pre-computed features (~2.5 GB)...")
print("=" * 60)

features_file = "openwakeword_features_ACAV100M_2000_hrs_16bit.npy"
validation_file = "validation_set_features.npy"

if not os.path.exists(features_file):
    subprocess.run([
        "wget", f"https://huggingface.co/datasets/davidscripka/openwakeword_features/resolve/main/{features_file}"
    ], check=True)
else:
    print(f"Already have {features_file}")

if not os.path.exists(validation_file):
    subprocess.run([
        "wget", f"https://huggingface.co/datasets/davidscripka/openwakeword_features/resolve/main/{validation_file}"
    ], check=True)
else:
    print(f"Already have {validation_file}")

# ── Step 4: Create training config ──
print("\n" + "=" * 60)
print("STEP 4: Creating training config...")
print("=" * 60)

# Load default config from openwakeword
default_config_path = os.path.join(OWW_DIR, "examples", "custom_model.yml")
config = yaml.load(open(default_config_path, 'r').read(), yaml.Loader)

# Override with our settings
config["target_phrase"] = [TARGET]
config["model_name"] = MODEL_NAME
config["n_samples"] = 50000
config["n_samples_val"] = 5000
config["steps"] = 50000
config["target_accuracy"] = 0.6
config["target_recall"] = 0.25
config["background_paths"] = ['./audioset_16k', './fma']
config["false_positive_validation_data_path"] = validation_file
config["feature_data_files"] = {"ACAV100M_sample": features_file}

config_path = os.path.join(WORK_DIR, "my_model.yaml")
with open(config_path, 'w') as f:
    yaml.dump(config, f)

print(f"Config saved: {config_path}")
print(f"  target_phrase: {config['target_phrase']}")
print(f"  n_samples: {config['n_samples']}")
print(f"  steps: {config['steps']}")

# ── Step 5: Generate synthetic clips ──
print("\n" + "=" * 60)
print("STEP 5: Generating synthetic clips (~10 min)...")
print("=" * 60)

subprocess.run([PYTHON, TRAIN_PY, "--training_config", config_path, "--generate_clips"], check=True)

# ── Step 5b: Resample generated clips to 16 kHz ──
# Piper TTS outputs at 22050 Hz but openWakeWord augmentation expects 16000 Hz
print("\n" + "=" * 60)
print("STEP 5b: Resampling generated clips to 16 kHz...")
print("=" * 60)

import torchaudio

output_base = config.get("output_dir", "my_custom_model")
clip_dirs = [
    os.path.join(output_base, MODEL_NAME, "positive_train"),
    os.path.join(output_base, MODEL_NAME, "positive_test"),
    os.path.join(output_base, MODEL_NAME, "negative_train"),
    os.path.join(output_base, MODEL_NAME, "negative_test"),
]
resampled = 0
for clip_dir in clip_dirs:
    if not os.path.isdir(clip_dir):
        continue
    wavs = [f for f in os.listdir(clip_dir) if f.endswith(".wav")]
    for wav in tqdm(wavs, desc=os.path.basename(clip_dir)):
        fpath = os.path.join(clip_dir, wav)
        audio, sr = torchaudio.load(fpath)
        if sr != 16000:
            audio = torchaudio.functional.resample(audio, sr, 16000)
            torchaudio.save(fpath, audio, 16000)
            resampled += 1
print(f"Resampled {resampled} clips to 16 kHz")

# Clean stale feature files so augmentation re-runs properly
feature_dir = os.path.join(config.get("output_dir", "my_custom_model"), MODEL_NAME)
if os.path.isdir(feature_dir):
    for f in os.listdir(feature_dir):
        if f.endswith("_features_train.npy") or f.endswith("_features_test.npy"):
            os.remove(os.path.join(feature_dir, f))
            print(f"  Removed stale {f}")

# ── Step 6: Augment clips ──
print("\n" + "=" * 60)
print("STEP 6: Augmenting clips...")
print("=" * 60)

subprocess.run([PYTHON, TRAIN_PY, "--training_config", config_path, "--augment_clips"], check=True)

# ── Step 7: Train model ──
print("\n" + "=" * 60)
print("STEP 7: Training model (~15-30 min on GPU)...")
print("=" * 60)

subprocess.run([PYTHON, TRAIN_PY, "--training_config", config_path, "--train_model"], check=False)

# ── Step 8: Copy model to project ──
print("\n" + "=" * 60)
print("STEP 8: Copying model...")
print("=" * 60)

# Find the output model
output_dir = config.get("output_dir", "my_custom_model")
trained_onnx = os.path.join(output_dir, f"{MODEL_NAME}.onnx")
if not os.path.isfile(trained_onnx):
    trained_onnx = os.path.join(WORK_DIR, f"{MODEL_NAME}.onnx")
if not os.path.isfile(trained_onnx):
    # Search for it
    for root, dirs, files in os.walk(WORK_DIR):
        for f in files:
            if f == f"{MODEL_NAME}.onnx":
                trained_onnx = os.path.join(root, f)
                break

dest = os.path.join(SCRIPT_DIR, "models", f"{MODEL_NAME}.onnx")
os.makedirs(os.path.dirname(dest), exist_ok=True)

if os.path.isfile(trained_onnx):
    shutil.copy2(trained_onnx, dest)
    size_kb = os.path.getsize(dest) / 1024
    print(f"\n{'=' * 60}")
    print(f"SUCCESS! Model: {dest} ({size_kb:.0f} KB)")
    print(f"{'=' * 60}")
    print(f"\nUpdate .env:")
    print(f"  DICTATE_WAKEWORD_MODEL=models/{MODEL_NAME}.onnx")
    print(f"  DICTATE_MAGIC_WORD={TARGET}")
    print(f"\nThen: sudo systemctl restart whisper-p2t")
else:
    print(f"\nERROR: Could not find trained model")
    print(f"Searched: {WORK_DIR}")
    for root, dirs, files in os.walk(WORK_DIR):
        for f in files:
            if f.endswith(".onnx"):
                print(f"  Found: {os.path.join(root, f)}")
