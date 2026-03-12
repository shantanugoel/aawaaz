# Aawaaz - Product Specification

## Overview

Aawaaz (आवाज़ — "voice" in Hindi) is a system-wide, real-time, fully local voice-to-text dictation app for macOS. It enables users to speak in any application and have their speech transcribed and inserted at the cursor — similar to WisprFlow, but with full privacy (no cloud dependency), multi-lingual support, and first-class Hindi-English (Hinglish) code-switching.

## Target Platform

- macOS on Apple Silicon (M1/M2/M3/M4)
- Intel Macs are explicitly out of scope
- iOS port is a future goal (shared SwiftUI views + AVAudioEngine code)
- Android is not planned

## Core Value Proposition

1. **Fully local** — All transcription happens on-device. No audio ever leaves the machine. Privacy by default.
2. **System-wide** — Works in any app (Slack, VS Code, browser, Notes, Terminal, etc.) via macOS Accessibility API.
3. **Hinglish-native** — First-class support for Hindi-English code-switching (speaking Hindi mixed with English words mid-sentence).
4. **Fast** — Competitive with WisprFlow's ~1-2s latency for short phrases using whisper.cpp with Metal GPU acceleration.
5. **Beautiful & minimal** — Small floating overlay + menu bar presence. Stays out of the way.

## User Experience

### Activation Flow

1. User presses a configurable global hotkey (e.g., hold `Fn`, or double-tap `Ctrl`)
2. A small floating overlay appears near the cursor/focused text field, showing a recording indicator
3. User speaks naturally (in English, Hindi, or mixed Hinglish)
4. Real-time transcription appears in the overlay as speech is processed
5. On release of hotkey (or silence timeout), final transcription is inserted into the focused text field
6. Overlay dismisses

### Two Activation Modes

- **Hold-to-talk**: Hold the hotkey while speaking. Release to finish. Best for short dictation.
- **Toggle mode**: Press hotkey to start, press again to stop. Best for longer dictation.

### Menu Bar App

- Lives in macOS menu bar (no dock icon)
- Popover shows:
  - Current status (idle / listening / processing)
  - Selected model (turbo / large-v3 / custom)
  - Selected language mode (Auto / English / Hindi / Hinglish)
  - Quick access to settings
- Runs as a background process (LSUIElement)

### Settings

- **Model selection**: Choose between downloaded models (turbo, large-v3, etc.) with size/speed/accuracy trade-off displayed
- **Model management**: Download, delete, and update GGML models
- **Language mode**: Auto-detect (default), force English, force Hindi, or Hinglish-optimized
- **Hotkey configuration**: Choose activation key and mode (hold vs. toggle)
- **LLM post-processing**: Off / Local (Phi-3.5-mini or Llama 3.2 3B) / Remote (Claude API / OpenAI API)
- **LLM cleanup level**: Light (filler words only) / Medium (+ grammar) / Full (+ context-aware formatting)
- **Latency vs. accuracy**: Slider or presets (Fast/Balanced/Quality) that adjust chunk size and model
- **Text insertion method**: Auto / AX API / Keystroke simulation / Clipboard
- **Audio input**: Select microphone device

## Transcription Engine

### Primary: whisper.cpp

- C/C++ Whisper implementation optimized for Apple Silicon
- Metal GPU acceleration for encoder
- Optional CoreML acceleration for Apple Neural Engine
- GGML quantized models (Q5_0 for best size/quality trade-off)
- No language parameter by default for best code-switching behavior

### Models (user-downloadable)

| Model | Download Size | RAM Usage | Speed (M2, 1min) | Hinglish Quality | Recommended For |
|-------|--------------|-----------|-------------------|------------------|-----------------|
| small | ~181 MB | ~1 GB | ~3s | Marginal | Low-RAM machines, quick notes |
| turbo | ~600 MB | ~2.5 GB | ~4s | Good | **Default — best trade-off** |
| large-v3 | ~1.1 GB | ~4 GB | ~8s (Metal) | Best | Quality mode, important dictation |
| indicwhisper* | TBD | TBD | TBD | Potentially best | Hinglish-optimized (if GGML conversion works) |

*IndicWhisper models from AI4Bharat, pending GGML format conversion and benchmarking.

### Voice Activity Detection (VAD)

- Silero VAD (~2 MB model)
- Runs on every 30ms audio frame
- Detects speech start/end boundaries
- Prevents Whisper hallucinations on silence
- Configurable speech padding (default: 300ms after speech ends)

### Streaming Architecture

```
Microphone (AVAudioEngine, 16kHz mono)
    │
    ▼
Silero VAD (per 30ms frame)
    │
    ├── No speech → discard, continue
    │
    └── Speech detected → buffer audio
            │
            ├── Speech ongoing → continue buffering
            │                    (optionally run interim inference every N seconds)
            │
            └── Speech ended (+ padding) → send buffer to whisper.cpp
                    │
                    ▼
              whisper.cpp inference (Metal GPU)
                    │
                    ▼
              Raw transcription text
                    │
                    ▼
              [Optional] LLM post-processing
                    │
                    ▼
              Insert text into focused app
```

### Latency Budget (turbo model, M2+)

| Stage | Time |
|-------|------|
| VAD speech-end detection + padding | ~300ms |
| whisper.cpp inference (turbo, Metal) | ~2-4s for typical utterance |
| LLM cleanup (if enabled, local) | ~1-2s |
| Text insertion (AX API) | ~10ms |
| **Total without LLM** | **~2.5-4.5s** |
| **Total with local LLM** | **~4-7s** |

## LLM Post-Processing

### Purpose

- Remove filler words ("um", "uh", "so like", "basically")
- Fix grammar and punctuation
- Context-aware formatting (Markdown in code editors, casual in chat apps, formal in email)
- Handle Hinglish romanization preferences (user may prefer "kaise ho" vs "कैसे हो")

### Local LLM Options

| Model | Size (Q4) | RAM | Speed | Quality |
|-------|-----------|-----|-------|---------|
| Phi-3.5-mini (3.8B) | ~2.2 GB | ~3 GB | ~1-2s | Good for cleanup tasks |
| Llama 3.2 3B | ~1.8 GB | ~2.5 GB | ~1-2s | Good general purpose |
| Gemma 2 2B | ~1.5 GB | ~2 GB | ~1s | Lighter, decent quality |

### Remote LLM Options

- Claude API (Haiku for speed, Sonnet for quality)
- OpenAI API (GPT-4o-mini for speed)
- User provides their own API key in settings

### Memory Management

- LLM model is lazy-loaded (only when post-processing is enabled)
- Can be unloaded to free RAM
- Whisper and LLM can coexist on 16GB+ machines (~6-8 GB total)
- On 8GB machines, recommend smaller Whisper model + smaller LLM, or disable LLM

## Text Insertion

### Primary: Accessibility API (AXUIElement)

1. Get the frontmost application via `NSWorkspace.shared.frontmostApplication`
2. Get the AX application element via `AXUIElementCreateApplication(pid)`
3. Find the focused UI element via `kAXFocusedUIElementAttribute`
4. Check if it accepts text input
5. Get current value and selection range
6. Insert transcription at cursor position via `AXUIElementSetAttributeValue`

### Fallback: Keystroke Simulation

For apps that don't properly expose AX text elements (some Electron apps, games):
1. Copy transcription to clipboard
2. Simulate Cmd+V keystroke via `CGEventPost`

### Fallback: Clipboard Only

If both methods fail, copy to clipboard and show a notification.

### Permissions Required

- **Microphone**: Requested via standard macOS permission dialog
- **Accessibility**: User must manually enable in System Settings > Privacy & Security > Accessibility
- App should guide user through this on first launch with clear instructions

## Voice Commands (Future Phase)

### Pattern-Matched Commands (Phase 4a)

Detect keywords in transcription and execute actions instead of inserting text:

| Command | Action |
|---------|--------|
| "delete that" / "undo that" | Cmd+Z |
| "new line" / "next line" | Insert newline |
| "new paragraph" | Insert double newline |
| "select all" | Cmd+A |
| "copy that" | Cmd+C |
| "period" / "comma" / "question mark" | Insert punctuation |
| "stop dictation" | Deactivate |

### LLM-Interpreted Commands (Phase 4b)

Pass transcription through LLM with instruction to detect commands:
- "Move that paragraph up"
- "Change the email to john@example.com"
- "Make the last sentence more formal"
- "Read that back to me" (future: TTS integration)

## Multi-Language Support

### Independent Languages

Whisper turbo/large-v3 supports 99 languages. Users select their language in settings, or use auto-detect mode. No special work needed beyond exposing the language selector.

### Code-Switching Pairs

| Priority | Pair | Approach |
|----------|------|----------|
| P0 | Hindi-English (Hinglish) | Whisper auto-detect + IndicWhisper fine-tuned models |
| P1 | Tamil-English | IndicWhisper models |
| P1 | Punjabi-English | IndicWhisper models (limited) |
| P2 | Spanish-English | Whisper auto-detect (works reasonably well) |
| P2 | French-English | Whisper auto-detect |
| P3 | Other Indian languages | AI4Bharat ecosystem |
| P3 | Other pairs | Custom fine-tuning (LoRA on Whisper) |

### Hinglish-Specific Considerations

- Whisper may output Devanagari script for Hindi portions — user should be able to configure preference (Devanagari vs. romanized)
- LLM post-processing can handle script normalization
- Common Hinglish patterns: English technical terms in Hindi sentences, Hindi colloquialisms in English sentences
- Test with representative speakers — Hinglish varies significantly by region and speaker

## Non-Functional Requirements

### Performance

- App launch to ready: < 3 seconds (model pre-loaded)
- Hotkey to listening: < 100ms
- End-of-speech to text inserted: < 5 seconds (turbo, no LLM)
- Idle CPU usage: < 1% (VAD only runs during active listening)
- Idle RAM: ~50-100 MB (app only, models loaded on demand or kept resident per user preference)

### Reliability

- Graceful handling of model loading failures
- Fallback text insertion methods
- Crash recovery (save last transcription)
- Audio device hot-swap support (e.g., switching headsets)

### Privacy

- Zero network calls in default configuration (no telemetry, no cloud)
- Remote LLM is opt-in only with clear indication
- No audio stored to disk (unless user explicitly enables transcription history)
- Optional: encrypted local transcription history

### Accessibility

- VoiceOver compatible settings UI
- High contrast overlay option
- Configurable overlay size and position

## Out of Scope (for now)

- Speaker diarization (who said what)
- Audio file transcription (only live microphone)
- Real-time translation
- Text-to-speech
- Windows/Linux support
- Collaboration/sharing features
- Built-in fine-tuning UI
