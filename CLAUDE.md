# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

voicecom is a macOS menu bar app that provides system-wide voice-to-text. It records audio via a global hotkey (toggle or push-to-talk), transcribes it using on-device Whisper models, and pastes the result into the frontmost application via simulated Cmd+V.

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

- **`TranscriptionService`** — Facade over the two transcription backends. Manages backend lifecycle (create, switch, unload). The active backend is lazily resolved via `resolveBackend(for:)`.
- **`TranscriptionBackend` protocol** — Defines `fetchAvailableModels()`, `loadModel(name:)`, `transcribe(audioBuffer:)`, `unloadModel()`. Audio is always 16kHz mono Float PCM (`[Float]`).
- **`WhisperKitBackend`** — Uses the WhisperKit SPM package (CoreML/ANE acceleration). Models download from HuggingFace automatically via WhisperKit's API. Models cached in `~/Library/Application Support/voicecom/models/`.
- **`WhisperCppBackend`** — Uses the vendored whisper.cpp C library via the `LocalWhisper` SPM package. Downloads GGML model `.bin` files and optional CoreML encoder `.mlmodelc` from HuggingFace. Models cached in `~/Library/Application Support/voicecom/models/whispercpp/`.
- **`AudioRecorder`** — Records to a temp WAV file (16kHz, 16-bit PCM) using `AVAudioRecorder`, then reads it back as `[Float]`. Resamples via vDSP if the source sample rate doesn't match 16kHz.
- **`TextInsertionService`** — Pastes text by: saving clipboard → setting text → simulating Cmd+V via CGEvent → restoring clipboard after 1s delay. Requires Accessibility permission.
- **`HotkeyManager`** — Registers global/local `NSEvent` monitors for two independent hotkeys: toggle-mode and push-to-talk. Uses `keyDown`/`keyUp` events (not Carbon hot keys).
- **`PermissionManager`** — Checks/requests microphone and accessibility permissions.

### Views (`voicecom/Views/`)

- **`MenuBarView`** — Main popover UI shown from the menu bar icon. Mic button, status badge, last transcription card, model info chip.
- **`SettingsView`** — Tabbed settings: General (backend picker, model picker, hotkey config) and Permissions.
- **`HotkeyRecorderView`** — `NSViewRepresentable` wrapping an `NSView` that captures keyboard shortcuts.

### LocalWhisper Package (`LocalWhisper/`)

A local SPM package that wraps the vendored whisper.cpp C/C++ library for use from Swift:

- `LocalWhisper/vendor/` — Git submodule containing the whisper.cpp source (ggml + whisper core)
- `LocalWhisper/include/` — Public headers (`whisper.h`, ggml headers) and `module.modulemap`
- `LocalWhisper/Package.swift` — Compiles only Apple-relevant sources (ARM NEON, Accelerate, CoreML encoder). Excludes CUDA, Vulkan, x86, and other non-Apple backends.
- Linked frameworks: Accelerate, CoreML
- Key defines: `GGML_USE_ACCELERATE`, `GGML_USE_CPU`, `WHISPER_USE_COREML`, `WHISPER_COREML_ALLOW_FALLBACK`

### SPM Dependencies

- **WhisperKit** (argmaxinc) — CoreML-based Whisper inference
- **swift-transformers** (huggingface) — Transitive dependency of WhisperKit
- **swift-argument-parser**, **swift-crypto**, **swift-collections**, **swift-jinja**, **yyjson** — Transitive dependencies

## Key Patterns

- The app requires two macOS permissions: **Microphone** (requested on first recording) and **Accessibility** (needed for CGEvent-based paste, prompted at launch).
- Backend switching (`switchBackend(to:)`) unloads the current model and reloads the default model for the new backend.
- Both backends strip emoji hallucinations from Whisper output post-transcription.
- Settings are stored directly in `UserDefaults` via computed properties on `AppState` (no separate settings model).
