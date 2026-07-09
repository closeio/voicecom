# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

voicecom is a macOS menu bar app that provides system-wide voice-to-text. It records audio via a global hotkey (toggle or push-to-talk), transcribes it using on-device speech models (Whisper or NVIDIA Parakeet), and pastes the result into the frontmost application via simulated Cmd+V.

## Build & Run

This is an Xcode project (not SPM-only). The primary way to build is through Xcode or `xcodebuild`.

```bash
# Build (Release)
xcodebuild -scheme voicecom -configuration Release -derivedDataPath build/DerivedData

# Build (Debug)
xcodebuild -scheme voicecom -configuration Debug -derivedDataPath build/DerivedData

# Run tests
xcodebuild test -scheme voicecom -derivedDataPath build/DerivedData

# Archive for export
xcodebuild archive -scheme voicecom -archivePath build/voicecom.xcarchive
xcodebuild -exportArchive -archivePath build/voicecom.xcarchive -exportPath build/export -exportOptionsPlist build/ExportOptions.plist
```

- Swift 6.0, macOS deployment target 26.2
- Bundle ID: `newstuff.io.voicecom`
- DerivedData lives in `build/DerivedData/` (custom path, not the default Xcode location)
- Tests use Swift Testing framework (`import Testing`, `@Test`)

## Architecture

### App Entry Point & State

- `voicecomApp.swift` — `@main` SwiftUI app. Menu bar-only (no dock icon). Uses `MenuBarExtra` with `.window` style and a `Settings` scene.
- `AppState.swift` — `@Observable @MainActor` singleton holding all UI state, user settings (persisted via `UserDefaults`), and service instances. Passed through SwiftUI `@Environment`.

### Services (`voicecom/Services/`)

All services are plain classes (no dependency injection container):

- **`TranscriptionService`** — Facade over the transcription backends. Holds a single `any TranscriptionBackend` and routes by model name via `prepareBackend(for:)`: names prefixed `parakeet-` go to `ParakeetBackend`, everything else (the `ggml-*` models) to `WhisperCppBackend`. Selecting a model that belongs to the other backend unloads the current one and swaps. `fetchAvailableModels()` merges both backends' lists so all models appear in one picker.
- **`TranscriptionBackend` protocol** — Defines `fetchAvailableModels()`, `loadModel(name:onPhaseChange:)`, `transcribe(audioBuffer:language:)`, `unloadModel()`. Audio is always 16kHz mono Float PCM (`[Float]`).
- **`WhisperCppBackend`** — Uses the vendored whisper.cpp C library via the `LocalWhisper` SPM package. Downloads GGML model `.bin` files and optional CoreML encoder `.mlmodelc` from HuggingFace. Models cached in `~/Library/Application Support/voicecom/models/whispercpp/`.
- **`ParakeetBackend`** — Uses the `parakeet_*` C API from the same `LocalWhisper` package (whisper.cpp v1.9.0+). Runs on the Metal GPU (`parakeet_context_params.use_gpu = true`) with no CoreML/ANE path. Downloads a single GGML `.bin` from the `ggml-org/parakeet-GGUF` HuggingFace repo. Models cached in `~/Library/Application Support/voicecom/models/parakeet/`. Parakeet v3 is multilingual/auto-detecting, so the `language` argument is ignored.
- **`AudioRecorder`** — Records to a temp WAV file (16kHz, 16-bit PCM) using `AVAudioRecorder`, then reads it back as `[Float]`. Resamples via vDSP if the source sample rate doesn't match 16kHz.
- **`TextInsertionService`** — Pastes text by: saving clipboard → setting text → simulating Cmd+V via CGEvent → restoring clipboard after 1s delay. Requires Accessibility permission.
- **`HotkeyManager`** — Registers global/local `NSEvent` monitors for two independent hotkeys: toggle-mode and push-to-talk. Uses `keyDown`/`keyUp` events (not Carbon hot keys).
- **`PermissionManager`** — Checks/requests microphone and accessibility permissions.

### Views (`voicecom/Views/`)

- **`MenuBarView`** — Main popover UI shown from the menu bar icon. Mic button, status badge, last transcription card, model info chip.
- **`SettingsView`** — Tabbed settings: General (model picker, language picker, hotkey config) and Permissions.
- **`HotkeyRecorderView`** — `NSViewRepresentable` wrapping an `NSView` that captures keyboard shortcuts.

### LocalWhisper Package (`LocalWhisper/`)

A local SPM package (the app's only package dependency) that wraps the vendored whisper.cpp C/C++ library — including Whisper and Parakeet — for use from Swift:

- `LocalWhisper/vendor/` — Git submodule pinned to a whisper.cpp release tag (currently v1.9.1), containing the ggml + whisper + parakeet source.
- `LocalWhisper/include/` — Copies of the public headers (`whisper.h`, `parakeet.h`, ggml headers) and `module.modulemap`. These are physical copies, not symlinks.
- `LocalWhisper/MetalObjC/` — The ggml Metal backend: the `.metal` shader + its headers (raw copies of the vendor sources) and thin `*-mrc.m` wrappers compiled without ARC.
- `LocalWhisper/Package.swift` — Hand-curated source list compiling only Apple-relevant sources (ARM NEON, Accelerate, Metal, CoreML encoder). Excludes CUDA, Vulkan, x86, and other non-Apple backends. Because there is no CMake, version macros (`WHISPER_VERSION`, `PARAKEET_VERSION`, etc.) must be defined here manually.
- Linked frameworks: Accelerate, CoreML, Metal, MetalKit
- Key defines: `GGML_USE_ACCELERATE`, `GGML_USE_CPU`, `GGML_USE_METAL`, `WHISPER_USE_COREML`, `WHISPER_COREML_ALLOW_FALLBACK`

Bumping the vendored whisper.cpp version is a manual multi-step sync (submodule checkout + re-copy headers/Metal sources + update `Package.swift`), not just a submodule update.

## Key Patterns

- The app requires two macOS permissions: **Microphone** (requested on first recording) and **Accessibility** (needed for CGEvent-based paste, prompted at launch).
- Backend selection is driven entirely by the selected model name — `TranscriptionService` swaps backends transparently when the chosen model belongs to the other one.
- Both backends strip bracketed markers and emoji hallucinations from the output post-transcription.
- Settings are stored directly in `UserDefaults` via computed properties on `AppState` (no separate settings model).
