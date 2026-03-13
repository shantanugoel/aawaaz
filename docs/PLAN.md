# Aawaaz - Implementation Plan

## Tech Stack

| Component | Technology | Rationale |
|-----------|-----------|-----------|
| Language | Swift | Native macOS, required for Accessibility API, AVAudioEngine, system integration. No bridging layers |
| UI Framework | SwiftUI + minimal AppKit | SwiftUI for all views (beginner-friendly, declarative). AppKit only for AXUIElement, CGEvent, NSEvent global monitors |
| Transcription | [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | Best Apple Silicon optimization (Metal, CoreML, NEON). Consumed via precompiled XCFramework. GGML quantized models |
| VAD | [Silero VAD](https://github.com/snakers4/silero-vad) | Industry standard, ~2MB, language-agnostic. Run via ONNX Runtime Swift package or CoreML conversion |
| Audio | AVAudioEngine | Apple's native audio graph. ~5ms latency, 16kHz mono tap for transcription |
| Local LLM | [llama.cpp](https://github.com/ggerganov/llama.cpp) | Same ecosystem as whisper.cpp (same author, same model format, same patterns). Swift bindings available |
| Remote LLM | URLSession + Codable | Simple HTTP client for Claude/OpenAI API. No SDK dependency needed |
| Build | Xcode + Swift Package Manager | SPM for dependencies. whisper.cpp via precompiled XCFramework (v1.8.3), llama.cpp and ONNX Runtime via SPM |
| Min deployment | macOS 14 (Sonoma) | Ensures modern SwiftUI features, Metal 3, good AVAudioEngine APIs |

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    AawaazApp                        │
│                  (SwiftUI Entry)                    │
├──────────┬──────────┬──────────┬────────────────────┤
│ MenuBar  │ Overlay  │ Settings │   Onboarding       │
│  View    │  View    │  View    │     View            │
├──────────┴──────────┴──────────┴────────────────────┤
│                   AppState                          │
│            (ObservableObject)                       │
├─────────────────────────────────────────────────────┤
│              TranscriptionPipeline                  │
│    ┌───────────┐  ┌──────────┐  ┌───────────────┐  │
│    │  Audio    │→ │   VAD    │→ │   Whisper     │  │
│    │ Capture   │  │ Processor│  │   Manager     │  │
│    └───────────┘  └──────────┘  └───────┬───────┘  │
│                                         │          │
│                                         ▼          │
│                               ┌───────────────┐   │
│                               │ Post-Processor│   │
│                               │ (LLM optional)│   │
│                               └───────┬───────┘   │
│                                       │           │
│                                       ▼           │
│                              ┌────────────────┐   │
│                              │ Text Insertion │   │
│                              │  (AX / CGEvent)│   │
│                              └────────────────┘   │
├─────────────────────────────────────────────────────┤
│  HotkeyManager  │  ModelManager  │ PermissionsGuide│
└─────────────────────────────────────────────────────┘
```

### Key Design Principles

1. **Pipeline pattern**: Audio → VAD → Whisper → LLM → Insertion. Each stage is an independent, testable component.
2. **Observable state**: Single `AppState` object drives all UI reactively via SwiftUI's `@Observable` macro.
3. **Lazy loading**: Models are loaded only when needed, can be unloaded to free RAM.
4. **Async/await**: All heavy work (inference, model loading) runs on background tasks using Swift concurrency. UI never blocks.
5. **Protocol-oriented**: Key components (transcription engine, text inserter, LLM processor) are protocol-defined so implementations can be swapped.

### Implementation Guidance

- Treat concrete APIs named in this document as strong starting points, not irrevocable decisions. When implementation begins, verify them against the actual UX and compatibility requirements before locking them in.
- For system integration work (hotkeys, Accessibility insertion, event synthesis), prefer a short spike and test matrix over assuming the first plausible API will generalize across macOS apps.
- Benchmark early on target Apple Silicon hardware. If measured latency misses the UX bar, reprioritize the implementation plan rather than preserving phase order for its own sake.
- Choose one canonical runtime storage location for downloaded models and keep code, docs, onboarding, and local development conventions aligned around it.

## Project Structure

```
aawaaz/
├── docs/
│   ├── SPEC.md
│   └── PLAN.md
├── Aawaaz/
│   ├── Aawaaz.xcodeproj
│   ├── Package.swift                    # Local SPM package: whisper.cpp XCFramework binary target + other deps
│   ├── App/
│   │   ├── AawaazApp.swift              # @main, MenuBarExtra, app lifecycle
│   │   ├── AppState.swift               # @Observable central state
│   │   └── AppDelegate.swift            # NSApplicationDelegate for AppKit-level setup
│   ├── Views/
│   │   ├── MenuBarView.swift            # MenuBarExtra popover content
│   │   ├── OverlayView.swift            # Floating NSPanel with transcription text
│   │   ├── OverlayWindowController.swift # NSPanel creation and positioning
│   │   ├── SettingsView.swift           # Preferences window (tabbed)
│   │   ├── OnboardingView.swift         # First-launch permission guide
│   │   └── ModelDownloadView.swift      # Model browser and download progress
│   ├── Audio/
│   │   ├── AudioCaptureManager.swift    # AVAudioEngine setup, mic tap, 16kHz PCM buffer
│   │   └── AudioDevice.swift            # Enumerate and select input devices
│   ├── VAD/
│   │   ├── VADProcessor.swift           # Silero VAD wrapper, speech boundary detection
│   │   └── VADState.swift               # Speech start/end state machine
│   ├── Transcription/
│   │   ├── TranscriptionPipeline.swift  # Orchestrates VAD → Whisper → LLM → Insertion
│   │   ├── WhisperManager.swift         # whisper.cpp Swift wrapper, model load/unload, inference
│   │   ├── WhisperConfiguration.swift   # Model params, language, beam size, etc.
│   │   └── TranscriptionResult.swift    # Structured result (text, language, confidence, timestamps)
│   ├── PostProcessing/
│   │   ├── PostProcessor.swift          # Protocol: process(rawText, context) → cleanedText
│   │   ├── LocalLLMProcessor.swift      # llama.cpp-based cleanup
│   │   ├── RemoteLLMProcessor.swift     # Claude/OpenAI API cleanup
│   │   └── NoOpProcessor.swift          # Pass-through when disabled
│   ├── TextInsertion/
│   │   ├── TextInsertionManager.swift   # Orchestrator: try AX → fallback CGEvent → fallback clipboard
│   │   ├── AccessibilityManager.swift   # AXUIElement: find focused element, insert text
│   │   ├── KeystrokeSimulator.swift     # CGEventPost: simulate typing/paste
│   │   └── ClipboardManager.swift       # NSPasteboard: copy and paste
│   ├── Hotkey/
│   │   ├── HotkeyManager.swift          # Register/unregister global shortcuts
│   │   └── HotkeyConfiguration.swift    # Key + modifiers + mode (hold/toggle)
│   ├── Models/
│   │   ├── ModelManager.swift           # Download, verify, cache GGML models
│   │   ├── ModelCatalog.swift           # Available models with metadata (size, speed, languages)
│   │   └── ModelDownloader.swift        # URLSession download with progress
│   └── Permissions/
│       └── PermissionsManager.swift     # Check/request microphone, accessibility permissions
├── Resources/
│   ├── Assets.xcassets                  # App icon, menu bar icon
│   └── silero_vad.onnx                  # Silero VAD model (or .mlmodel if CoreML converted)
├── Models/                              # Optional local dev fixtures only; runtime app models should live in Application Support
├── Tests/
│   ├── VADProcessorTests.swift
│   ├── WhisperManagerTests.swift
│   ├── TextInsertionTests.swift
│   └── TranscriptionPipelineTests.swift
└── .gitignore
```

## Implementation Phases

---

### Phase 1: Foundation + Local Transcription MVP

**Goal**: Menu bar app → press hotkey → speak → see transcription in overlay → copied to clipboard.

**No AX API text insertion yet.** The user manually pastes. This lets us validate the transcription quality and UX before tackling the hardest system integration.

#### Step 1.1: Project Setup

- [x] Create Xcode project (macOS App, SwiftUI lifecycle)
- [x] Configure as menu bar app (LSUIElement in Info.plist)
- [x] Add whisper.cpp as XCFramework binary dependency (v1.8.3, via local SPM package)
- [x] Add ONNX Runtime Swift package (for Silero VAD)
- [x] Set up code signing with microphone entitlement
- [x] Set up .gitignore (Models/, .build/, etc.)

#### Step 1.2: Menu Bar + Basic UI

- [x] `AawaazApp.swift` — MenuBarExtra with a simple popover
- [x] `MenuBarView.swift` — Status indicator (idle/listening/processing), model name, quit button
- [x] `AppState.swift` — Observable state: status enum, current transcription text, selected model
- [x] Menu bar icon (microphone SF Symbol for now)

#### Step 1.3: Audio Capture

- [x] `AudioCaptureManager.swift` — AVAudioEngine with installTap on input node
- [x] Configure: 16kHz sample rate, mono, Float32 PCM format
- [x] Provide audio buffer callback (deliver `[Float]` samples)
- [x] Handle audio session setup and microphone permission request
- [x] `AudioDevice.swift` — List available input devices, handle device changes

#### Step 1.4: Voice Activity Detection

- [x] Bundle Silero VAD ONNX model in app resources
- [x] `VADProcessor.swift` — Load model, run inference on 30ms audio frames
- [x] `VADState.swift` — State machine: idle → speech_started → speech_ongoing → speech_ended
- [x] Configure speech padding (300ms default) and minimum speech duration (250ms)
- [x] Output: emits buffered audio segments when speech ends

#### Step 1.5: Whisper Integration

- [x] Confirm the canonical model storage path and keep all code/docs consistent with it (prefer `~/Library/Application Support/Aawaaz/Models/` for runtime downloads; use repo-local `Models/` only for development fixtures if intentionally needed)
- [x] `ModelManager.swift` — Check for models in ~/Library/Application Support/Aawaaz/Models/
- [x] `ModelCatalog.swift` — Hardcoded catalog of available models with download URLs (Hugging Face GGML repos)
- [x] `ModelDownloadView.swift` — Download model with progress bar (URLSession download task)
- [x] `WhisperManager.swift` — Load GGML model, run inference on audio buffer, return text
- [x] Configure: Metal acceleration enabled, no language forced (auto-detect), beam size 5
- [x] Handle model loading/unloading lifecycle

#### Step 1.6: Transcription Pipeline

- [ ] `TranscriptionPipeline.swift` — Wire: AudioCapture → VAD → Whisper → output
- [ ] On speech end: send audio buffer to WhisperManager, receive text
- [ ] Publish transcription result to AppState
- [ ] Copy result to clipboard automatically (NSPasteboard)
- [ ] Benchmark end-to-end latency on representative short and medium utterances; if VAD-segmented final inference does not meet the UX bar, pull interim/streaming work forward instead of deferring it to a later polish phase

#### Step 1.7: Overlay Window

- [ ] `OverlayWindowController.swift` — NSPanel, floating, always-on-top, non-activating
- [ ] `OverlayView.swift` — SwiftUI view showing: recording indicator (when listening), transcription text (when processing/done)
- [ ] Position: near mouse cursor or near focused window
- [ ] Auto-dismiss after a few seconds, or on next hotkey press
- [ ] Animate: fade in/out, subtle slide

#### Step 1.8: Global Hotkey

- [ ] Evaluate candidate hotkey mechanisms (`RegisterEventHotKey`, event taps, `NSEvent` monitors, or other native options) against system-wide reliability, modifier-only support, hold/release detection, permission behavior, and conflict rate
- [ ] `HotkeyManager.swift` — Implement the most reliable validated option; do not assume `NSEvent` monitors are sufficient until tested
- [ ] Choose the default shortcut only after testing conflict rate and ergonomics; do not assume a modifier-only shortcut (for example right Option) is viable across target apps
- [ ] Hold mode: key down → start listening, key up → stop and process
- [ ] Toggle mode: key down → toggle listening state
- [ ] `HotkeyConfiguration.swift` — Persist chosen key + mode in UserDefaults

#### Step 1.9: Settings

- [ ] `SettingsView.swift` — SwiftUI Settings scene
- [ ] Tabs: General (hotkey, activation mode), Models (select/download), Audio (input device)
- [ ] Language mode selector: Auto / English / Hindi
- [ ] Latency preset: Fast (small model, short chunks) / Balanced (turbo) / Quality (large-v3)

#### Step 1.10: First Launch & Permissions

- [ ] `PermissionsManager.swift` — Check microphone permission status
- [ ] `OnboardingView.swift` — Welcome screen, request microphone permission, guide to download first model
- [ ] Show permission status indicators

**Phase 1 deliverable**: A working menu bar app that listens on hotkey, transcribes via Whisper, shows result in an overlay, and copies to clipboard. User pastes manually.

---

### Phase 2: System-Wide Text Insertion

**Goal**: Transcribed text is directly inserted into the focused text field of any application.

#### Step 2.1: Accessibility Permission

- [ ] Add Accessibility description to Info.plist
- [ ] `PermissionsManager.swift` — Check `AXIsProcessTrusted()`, guide user to enable
- [ ] Update `OnboardingView` to include Accessibility permission step with screenshot/instructions
- [ ] Show persistent warning in menu bar if Accessibility is not granted

#### Step 2.2: AX API Text Insertion

- [ ] Build a compatibility matrix across representative targets: AppKit text fields, AppKit text views, SwiftUI text inputs, Electron apps, browsers/contenteditable, Terminal/code editors
- [ ] Evaluate insertion strategies before locking one in: direct AX value mutation, selected-text replacement, keystroke simulation, paste-based fallback
- [ ] `AccessibilityManager.swift`:
  - [ ] Get frontmost app PID via `NSWorkspace.shared.frontmostApplication`
  - [ ] Create AX element: `AXUIElementCreateApplication(pid)`
  - [ ] Get focused element: query `kAXFocusedUIElementAttribute`
  - [ ] Verify the focused element is actually editable/settable; do not assume `AXTextField`/`AXTextArea` coverage is sufficient for all supported apps
  - [ ] Get current value and selection range where available
  - [ ] Prefer the least-destructive insertion strategy that works for the current app/element; do not assume whole-value `kAXValueAttribute` replacement is universally correct
  - [ ] Update cursor position to end of inserted text

#### Step 2.3: Fallback: Keystroke Simulation

- [ ] `KeystrokeSimulator.swift`:
  - [ ] Save current clipboard contents
  - [ ] Copy transcription to clipboard
  - [ ] Simulate Cmd+V via `CGEventPost`
  - [ ] Restore original clipboard contents
  - [ ] Add small delay between clipboard set and paste simulation (~50ms)

#### Step 2.4: Insertion Orchestration

- [ ] `TextInsertionManager.swift`:
  - [ ] Try AX API insertion first
  - [ ] If AX API fails (element not found, not a text field, permission denied), fall back to keystroke simulation
  - [ ] If keystroke simulation fails, fall back to clipboard-only with notification
  - [ ] Log which method was used (for debugging)

#### Step 2.5: Context Detection

- [ ] Detect the frontmost application name and bundle identifier
- [ ] Detect the type of text field (single-line input, multi-line text area, code editor)
- [ ] Pass this context to post-processing (Phase 3) for context-aware formatting
- [ ] Store per-app preferences (e.g., always use keystroke simulation for app X)

**Phase 2 deliverable**: Transcription is automatically typed into whatever text field is focused, in any app.

---

### Phase 3: LLM Post-Processing

**Goal**: Clean up transcription (filler words, grammar, formatting) before insertion.

#### Step 3.1: Post-Processor Protocol

- [ ] `PostProcessor.swift` — Protocol:
  ```swift
  protocol PostProcessor {
      func process(rawText: String, context: InsertionContext) async throws -> String
  }
  ```
- [ ] `InsertionContext`: app name, bundle ID, text field type, existing text (if available)
- [ ] `NoOpProcessor.swift` — Pass-through implementation (when disabled)

#### Step 3.2: Local LLM Integration

- [ ] Add llama.cpp as Swift Package dependency
- [ ] `LocalLLMProcessor.swift`:
  - [ ] Load GGUF model (Phi-3.5-mini or Llama 3.2 3B)
  - [ ] Construct prompt: system instruction + context + raw text → cleaned text
  - [ ] Run inference with appropriate temperature (0.1-0.3 for cleanup tasks)
  - [ ] Parse output, extract cleaned text
  - [ ] Model lazy-load and unload support

#### Step 3.3: Remote LLM Integration

- [ ] `RemoteLLMProcessor.swift`:
  - [ ] Support Claude API (Haiku for speed, Sonnet for quality)
  - [ ] Support OpenAI API (GPT-4o-mini)
  - [ ] API key stored in Keychain (not UserDefaults)
  - [ ] Construct same prompt as local, send via URLSession
  - [ ] Handle errors gracefully (fall back to raw text if API fails)

#### Step 3.4: LLM Prompt Engineering

- [ ] System prompt template:
  ```
  Clean up this dictated text. The speaker was using [app_name].
  - Remove filler words (um, uh, like, you know, basically)
  - Fix grammar and punctuation
  - Keep the original meaning and tone
  - Format appropriately for [context]
  - If the text mixes Hindi and English, preserve the code-switching naturally
  - Do not add information that wasn't spoken
  Output only the cleaned text, nothing else.
  ```
- [ ] Cleanup level presets (Light / Medium / Full) adjust the prompt

#### Step 3.5: Settings Integration

- [ ] Add Post-Processing tab to Settings
- [ ] Toggle: Off / Local / Remote
- [ ] Model selection (for local)
- [ ] API key entry (for remote) with test button
- [ ] Cleanup level selector
- [ ] Preview: show raw vs. cleaned text for last transcription

#### Step 3.6: Script Preference (Hinglish-specific)

- [ ] Setting: Hindi portions in Devanagari vs. Romanized
- [ ] If Romanized preferred, add to LLM prompt: "Transliterate any Devanagari script to Roman/Latin script"
- [ ] If no LLM, implement basic Devanagari → Roman transliteration (or vice versa) as a simple post-processor

**Phase 3 deliverable**: Transcription is cleaned up by a local or remote LLM before insertion. Filler words removed, grammar fixed, formatting context-aware.

---

### Phase 4: Voice Commands

**Goal**: Detect and execute editing commands spoken by the user.

#### Step 4.1: Pattern-Matched Commands

- [ ] Define command vocabulary:
  - "delete that" / "undo" → Cmd+Z
  - "new line" / "enter" → Insert \n
  - "new paragraph" → Insert \n\n
  - "select all" → Cmd+A
  - "copy that" → Cmd+C
  - "paste" → Cmd+V
  - "tab" → Insert \t
  - "stop" → Deactivate dictation
- [ ] Command detection: check transcription against known phrases before insertion
- [ ] Execute via CGEvent keystroke simulation
- [ ] Visual feedback in overlay (show command name, not the spoken text)

#### Step 4.2: LLM-Interpreted Commands

- [ ] Enhanced LLM prompt that can return either text or a command
- [ ] JSON-structured output: `{"type": "text", "content": "..."}` or `{"type": "command", "action": "...", "params": {...}}`
- [ ] Command execution engine that maps LLM output to system actions
- [ ] Support complex commands: "make that bold" (Cmd+B), "move to the beginning" (Cmd+Up), etc.

**Phase 4 deliverable**: Users can speak commands to control editing, not just dictate text.

---

### Phase 5: Polish & Multi-Language Expansion

#### Step 5.1: UX Polish

- [ ] Refined overlay design (glassmorphic, matches macOS aesthetic)
- [ ] Transcription history viewer (searchable, with timestamps)
- [ ] Audio waveform visualization during recording
- [ ] Sound effects (subtle chime on start/stop dictation)
- [ ] Menubar icon animation during recording/processing
- [ ] Keyboard shortcut customization UI (record-a-shortcut style)

#### Step 5.2: Performance Optimization

- [ ] Profile and optimize the VAD → Whisper pipeline
- [ ] Implement interim results (show partial transcription while still speaking)
- [ ] Pre-warm whisper.cpp model on app launch (optional, uses more RAM)
- [ ] Benchmark and optimize CoreML conversion for VAD
- [ ] Explore CoreML conversion for Whisper models (ANE acceleration)

#### Step 5.3: IndicWhisper Integration

- [ ] Convert AI4Bharat IndicWhisper models to GGML format
- [ ] Benchmark against vanilla Whisper turbo/large-v3 on Hinglish test set
- [ ] Add as downloadable model option if performance is better
- [ ] Document conversion process for community contributions

#### Step 5.4: Additional Languages

- [ ] Language-specific model recommendations in ModelCatalog
- [ ] Test and validate top 10 languages by user demand
- [ ] Community contribution pipeline for language-specific fine-tuned models

#### Step 5.5: Custom Fine-Tuning (Advanced)

- [ ] Document LoRA fine-tuning process for Hinglish
- [ ] Provide sample training data format
- [ ] MLX-based fine-tuning script that runs on Apple Silicon
- [ ] Model export to GGML format for use in Aawaaz

---

## Technical Decisions & Trade-offs

### Why whisper.cpp over MLX Whisper?

| Factor | whisper.cpp | MLX Whisper |
|--------|------------|-------------|
| Language | C/C++ with Swift bindings | Python (mlx framework) |
| Integration | Native SPM package | Python subprocess or embedding |
| Performance | Metal + CoreML + NEON | MLX unified memory |
| Streaming | Built-in stream example | Manual implementation |
| Community | Massive (30k+ stars) | Smaller |
| Maintenance | Extremely active | Active but smaller scope |

**Decision**: whisper.cpp. Embedding Python in a Swift app adds massive complexity. whisper.cpp's Swift bindings make it a natural fit. Performance is comparable.

### Why llama.cpp over MLX LLM?

Same reasoning as above. Same developer ecosystem, same model format, same Swift integration patterns. Consistency reduces learning surface.

### Why ONNX Runtime for Silero VAD (not CoreML)?

| Factor | ONNX Runtime | CoreML |
|--------|-------------|--------|
| Setup | Add SPM package, load .onnx file | Convert model, handle .mlmodel compilation |
| Compatibility | Silero ships .onnx natively | Manual conversion (may have issues) |
| Performance | Fast enough (sub-ms per frame) | Slightly faster (ANE) but overkill for 2MB model |
| Debugging | Standard ONNX tooling | Apple-specific tooling |

**Decision**: Start with ONNX Runtime for simplicity. Migrate to CoreML later if needed for performance (unlikely — VAD is not the bottleneck).

### Why not use Apple's Speech Framework as a fallback?

- No code-switching support (single locale per recognizer)
- Less accurate than Whisper for non-English
- Could be offered as an ultra-low-latency option for English-only mode in the future
- Not worth the complexity of maintaining two transcription backends in MVP

### Hold-to-talk vs. Toggle: Default?

**Working hypothesis**: Default to **hold-to-talk** because it is more intuitive for short dictation and prevents the "forgot to turn it off" problem. Confirm the actual shortcut choice only after validating hotkey capture reliability and conflicts in real apps. Toggle mode should remain available in settings for longer dictation sessions.

### Audio chunk size for streaming

**Working hypothesis**: Start with VAD-based segmentation rather than fixed chunks. Speech boundaries are natural break points. This gives:
- Lower latency (process as soon as speech ends, don't wait for fixed interval)
- Better accuracy (Whisper gets complete utterances, not arbitrary cuts)
- More efficient (skip silence entirely)

Validate this against real UX expectations. If end-to-end latency still feels too slow, add interim inference or more streaming-oriented behavior earlier instead of treating it as Phase 5 polish.

For long continuous speech without pauses, impose a maximum segment duration of 15 seconds (process what we have and continue buffering).

## Dependencies

| Package | Source | Purpose |
|---------|--------|---------|
| whisper.cpp | github.com/ggerganov/whisper.cpp | Transcription engine |
| llama.cpp | github.com/ggerganov/llama.cpp | Local LLM post-processing |
| onnxruntime-swift | (Microsoft) | Silero VAD inference |

Three external dependencies total. All are well-maintained, widely-used C/C++ libraries with Swift bindings.

## Risk Mitigation

| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| Hinglish accuracy insufficient | Medium | High | Test early (Phase 1). IndicWhisper models as fallback. LoRA fine-tuning as escape hatch |
| AX API doesn't work in some apps | High | Medium | Keystroke simulation fallback. Per-app override settings. Document known incompatible apps |
| whisper.cpp Swift bindings have issues | Low | High | Well-established bindings, SwiftUI example in repo. Fallback: use C API directly from Swift |
| LLM over-corrects transcription | Medium | Medium | Configurable cleanup levels. Show raw vs. cleaned text. "Undo cleanup" button in overlay |
| Memory pressure on 8GB machines | Medium | Medium | Smart model loading/unloading. Recommend model sizes based on system RAM. Never load Whisper + LLM simultaneously on 8GB |

## Development Environment Setup

```bash
# Prerequisites
# - macOS 14+ (Sonoma or later)
# - Xcode 15+ (with Swift 5.9+)
# - Apple Silicon Mac (M1 or later)

# Clone
git clone <repo-url> aawaaz
cd aawaaz

# Open in Xcode
open Aawaaz/Aawaaz.xcodeproj

# Or build from command line
xcodebuild -project Aawaaz/Aawaaz.xcodeproj -scheme Aawaaz -configuration Debug build

# Download a model for testing
mkdir -p ~/Library/Application\ Support/Aawaaz/Models
curl -L -o ~/Library/Application\ Support/Aawaaz/Models/ggml-base.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
```

## Learning Resources (Swift/SwiftUI for newcomers)

- whisper.cpp SwiftUI example: `whisper.cpp/examples/whisper.swiftui/` — a complete transcription app you can build on
- Apple's SwiftUI tutorials: developer.apple.com/tutorials/swiftui
- Hacking with Swift (free): hackingwithswift.com — practical SwiftUI guides
- MenuBarExtra documentation: developer.apple.com/documentation/swiftui/menubarextra
- AXUIElement reference: developer.apple.com/documentation/applicationservices/accessibility
