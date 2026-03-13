# Aawaaz आवाज़

System-wide, real-time, fully local voice-to-text dictation for macOS.

Speak in any app — English, Hindi, or mixed Hinglish — and your words are transcribed and inserted at the cursor. All processing happens on-device. No audio ever leaves your Mac.

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon (M1/M2/M3/M4)
- Xcode 15+

## Setup

1. Clone the repo
2. Open `Aawaaz/Aawaaz.xcodeproj` in Xcode
3. Build & Run (⌘R)

On first launch, the app will:
- Guide you through granting **Accessibility** and **Microphone** permissions
- Download a Whisper transcription model (~50–500 MB depending on size chosen)

## Usage

- **Menu bar**: Aawaaz lives in your menu bar (no dock icon). Click to see status and settings.
- **Hold-to-talk**: Hold the global hotkey while speaking, release to insert text.
- **Toggle mode**: Press hotkey to start, press again to stop. Better for longer dictation.
- **Undo**: Press the undo hotkey to revert the last insertion.

The hotkey is configurable in Settings.

## Project Structure

```
Aawaaz/
├── App/            # App entry point, AppDelegate, AppState
├── Audio/          # Microphone capture (AVAudioEngine)
├── Hotkey/         # Global hotkey handling
├── Models/         # Whisper model management
├── Permissions/    # macOS permissions
├── TextInsertion/  # Accessibility text insertion
├── Transcription/  # whisper.cpp integration
├── VAD/            # Voice activity detection (Silero)
├── Views/          # SwiftUI UI
├── Tests/          # Unit tests
└── Resources/      # Assets, VAD model
docs/
├── SPEC.md         # Product specification
└── PLAN.md         # Architecture & implementation plan
```

## License

Private — not yet licensed for distribution.
