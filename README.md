# voicecom

A macOS menu bar app for system-wide voice-to-text. Press a hotkey, speak, and the transcribed text is pasted into whatever app you're using. All processing happens on-device using Whisper or NVIDIA Parakeet models -- no data leaves your Mac.

## Features

- **Menu bar app** -- lives in your menu bar, works system-wide with no dock icon
- **Two input modes** -- toggle recording (press to start, press to stop) or push-to-talk (hold to record, release to transcribe)
- **Two model families** -- OpenAI Whisper (via whisper.cpp) and NVIDIA Parakeet, selectable from a single model picker
- **Hardware-accelerated transcription** -- on-device inference with Metal GPU acceleration, CPU + Accelerate, and optional CoreML encoder for ANE (Whisper)
- **Multiple model sizes** -- Whisper from tiny to large-v3, plus Parakeet f16 and quantized variants, downloaded automatically on first use with a progress bar
- **Language selection** -- choose a transcription language or use auto-detect with multilingual models (Parakeet auto-detects the language)
- **Automatic text insertion** -- transcribed text is pasted directly into the frontmost app (full clipboard save/restore)
- **Configurable hotkeys** -- set your own keyboard shortcuts for toggle and push-to-talk
- **Recording safety** -- automatic stop after 5 minutes to prevent runaway recordings
- **Fully offline** -- models run locally, no network required after initial download

## Screenshots

| Menu bar popover | Settings — General | Settings — Permissions |
|---|---|---|
| ![Menu bar popover](img/Screenshot%202026-03-12%20at%2017.49.47.png) | ![Settings — General](img/Screenshot%202026-03-18%20at%2016.29.12.png) | ![Settings — Permissions](img/Screenshot%202026-03-12%20at%2017.50.16.png) |

## Requirements

- macOS 26.2+
- Apple Silicon (ARM64) recommended for best performance
- Xcode 26+ to build from source

## Getting Started

1. Clone the repository with submodules:
   ```bash
   git clone --recurse-submodules https://github.com/your-username/voicecom.git
   ```

2. Open `voicecom.xcodeproj` in Xcode

3. Build and run (Cmd+R)

4. Grant the requested permissions:
   - **Microphone** -- prompted on first recording
   - **Accessibility** -- needed to paste text into other apps (prompted at launch, or grant manually in System Settings > Privacy & Security > Accessibility)

## Usage

| Action | Default Shortcut |
|---|---|
| Toggle recording | Option + Shift + R |
| Push-to-talk (hold) | Option + Shift + T (enabled by default) |

1. Click the mic icon in the menu bar or press the toggle hotkey to start recording
2. Speak
3. Press the hotkey again (or release for push-to-talk) to stop and transcribe
4. The transcribed text is automatically pasted at your cursor

Shortcuts can be changed in Settings (Cmd+,).

## Transcription

voicecom supports two on-device model families, both powered by [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (vendored at v1.9.1). Pick a model in Settings and the app swaps backends transparently -- Whisper and Parakeet models appear side by side in the same picker. Models are downloaded from HuggingFace on first use (with download progress shown in the UI) and cached under `~/Library/Application Support/voicecom/models/`.

### Whisper (`ggml-*` models)

GGML `.bin` weights (and an optional CoreML encoder) are cached in `models/whispercpp/`. Hardware acceleration is layered for maximum performance:

- **Metal GPU** -- accelerates the decoder via the ggml Metal backend (enabled with flash attention)
- **CoreML encoder** -- downloaded alongside the model for ANE acceleration (falls back to CPU automatically)
- **Accelerate** -- used for CPU-side BLAS operations
- **Performance cores only** -- inference threads are pinned to P-cores to avoid latency from E-cores

### Parakeet (`parakeet-*` models)

NVIDIA's Parakeet TDT 0.6B v3 is available via whisper.cpp's `parakeet_*` C API (whisper.cpp v1.9.0+), and `parakeet-tdt-0.6b-v3-q8_0` is the default model for new installs. Weights are downloaded as a single GGML `.bin` from the [ggml-org/parakeet-GGUF](https://huggingface.co/ggml-org/parakeet-GGUF) HuggingFace repo and cached in `models/parakeet/`. Three variants are offered:

| Model | Precision | Approx. download |
|---|---|---|
| `parakeet-tdt-0.6b-v3` | f16 | ~1.2 GB |
| `parakeet-tdt-0.6b-v3-q8_0` | q8_0 | ~650 MB |
| `parakeet-tdt-0.6b-v3-q4_k` | q4_k | smaller still |

Parakeet runs on the Metal GPU (with CPU fallback) and, like Whisper, pins inference threads to P-cores. There is no CoreML/ANE path. Parakeet v3 is multilingual and auto-detects the spoken language, so the language setting is ignored while a Parakeet model is selected.

### Language selection

You can select a transcription language in Settings (General tab). Use "Auto-detect" with multilingual Whisper models (e.g. `ggml-small`, `ggml-large`). English-only models (`.en` suffix) always transcribe in English, and Parakeet models always auto-detect, regardless of this setting.

## Building from Source

```bash
# Debug build
xcodebuild -scheme voicecom -configuration Debug -derivedDataPath build/DerivedData

# Release build
xcodebuild -scheme voicecom -configuration Release -derivedDataPath build/DerivedData

# Run tests
xcodebuild test -scheme voicecom -derivedDataPath build/DerivedData
```

The Release `.app` bundle is output to `build/DerivedData/Build/Products/Release/voicecom.app`.

### Creating a .dmg for Distribution

To package the app into a `.dmg` installer with a drag-to-Applications layout:

```bash
# 1. Build in Release mode
xcodebuild -scheme voicecom -configuration Release -derivedDataPath build/DerivedData

# 2. Create a staging directory
mkdir -p build/dmg_staging
cp -R build/DerivedData/Build/Products/Release/voicecom.app build/dmg_staging/
ln -s /Applications build/dmg_staging/Applications

# 3. Create the .dmg
hdiutil create -volname "voicecom" \
  -srcfolder build/dmg_staging \
  -ov -format UDZO \
  build/voicecom.dmg

# 4. Clean up staging directory
rm -rf build/dmg_staging
```

The resulting `build/voicecom.dmg` can be shared and opened on any compatible Mac. Users open the DMG and drag `voicecom.app` into the Applications folder to install.

> **Note:** For distribution outside your own machines, sign with a Developer ID certificate and notarize:
> ```bash
> codesign --force --deep --sign "Developer ID Application: Your Name (TEAM_ID)" build/DerivedData/Build/Products/Release/voicecom.app
> xcrun notarytool submit build/voicecom.dmg --apple-id YOUR_APPLE_ID --team-id TEAM_ID --password APP_SPECIFIC_PASSWORD --wait
> xcrun stapler staple build/voicecom.dmg
> ```

## Project Structure

```
voicecom/
  voicecomApp.swift          # App entry point (MenuBarExtra + Settings scene)
  AppState.swift             # Central @Observable state, settings, service wiring
  Services/
    TranscriptionBackend.swift   # Protocol for transcription backends
    TranscriptionService.swift   # Facade that routes models to the right backend
    WhisperCppBackend.swift      # whisper.cpp (GGML) Whisper backend
    ParakeetBackend.swift        # NVIDIA Parakeet backend (Metal GPU)
    ModelDownloader.swift        # Model downloads with progress reporting
    AudioRecorder.swift          # AVAudioRecorder-based recording
    TextInsertionService.swift   # Clipboard + CGEvent paste
    HotkeyManager.swift         # Global keyboard shortcut handling
    PermissionManager.swift      # Mic + Accessibility permission checks
  Views/
    MenuBarView.swift            # Menu bar popover UI
    SettingsView.swift           # Settings window (General + Permissions tabs)
    HotkeyRecorderView.swift     # Keyboard shortcut capture widget
LocalWhisper/                # Local SPM package wrapping vendored whisper.cpp (Whisper + Parakeet)
  include/                   # Public C headers (whisper.h, parakeet.h) + module.modulemap
  MetalObjC/                 # Metal backend ObjC files (compiled without ARC)
  vendor/                    # whisper.cpp source (git submodule, v1.9.1)
  Package.swift              # Builds whisper.cpp for Apple platforms (CPU + Metal + CoreML)
```

