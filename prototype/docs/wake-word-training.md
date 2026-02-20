# Wake Word Training — `train_wakeword.py`

Train custom wake word models (.onnx) for use with `desktop.py` in VAD mode.

## Usage

```bash
# Create training venv (separate from runtime)
python3 -m venv /tmp/oww_train
/tmp/oww_train/bin/pip install openwakeword torchaudio speechbrain onnx

# Train a wake word
/tmp/oww_train/bin/python train_wakeword.py "hey mira" --output models/hey_mira.onnx
/tmp/oww_train/bin/python train_wakeword.py "alo" --output models/alo.onnx
```

## How It Works

1. **Text-to-speech generation** — Uses Piper TTS to generate hundreds of audio clips of the wake phrase with varied speakers and augmentation
2. **Negative samples** — Downloads background noise and random speech that should NOT trigger the wake word
3. **Feature extraction** — Converts audio to mel spectrograms matching openWakeWord's input format
4. **Training** — Trains a small neural network to distinguish the wake phrase from everything else
5. **ONNX export** — Exports the model as .onnx for fast CPU inference

## Options

```
train_wakeword.py PHRASE [--output PATH] [--epochs N]

Arguments:
  PHRASE              Wake phrase (e.g. "hey mira", "alo")
  --output PATH       Output .onnx path (default: models/<phrase>.onnx)
  --epochs N          Training epochs (default: 50)
```

## Using Trained Models

Set in `.env`:

```env
# Single model
DICTATE_WAKEWORD_MODEL=models/hey_mira.onnx

# Multiple models (comma-separated)
DICTATE_WAKEWORD_MODEL=models/hey_mira.onnx,models/alo.onnx
```

## Notes

- Training takes ~5-10 minutes on CPU
- The training venv (`/tmp/oww_train`) is separate from the runtime venv (`./venv`) because training requires newer openwakeword + extra dependencies
- Runtime uses an older openwakeword version with `wakeword_model_paths` parameter
- Threshold tuning: start at `0.1`, increase if too many false positives
- Models are small (~100KB) and run on CPU with negligible overhead


## Alternative: Google Colab (free GPU)

If you prefer not to train locally:

1. Open the [openWakeWord training notebook](https://colab.research.google.com/github/dscripka/openWakeWord/blob/main/notebooks/automatic_model_training.ipynb)
2. Set target wake word to your phrase (e.g. `hey mira`)
3. Run all cells (~1 hour on free Colab GPU)
4. Download the `.onnx` file → place in `models/`

### Colab Tips
- If pronunciation sounds wrong, try phonetic spelling: `hey_meer_ah`
- Pin versions if needed: `tensorflow==2.19.0 onnx==1.17.0`
- Only the `.onnx` file is needed (ignore TFLite conversion errors)
