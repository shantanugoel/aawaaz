# Agents Guide

## Orientation

- Read `docs/SPEC.md` (product spec) and `docs/PLAN.md` (architecture & implementation plan) before making any changes.
- The plan tracks implementation phases — check which phase is current before starting work.

## Project Layout

All source lives under `Aawaaz/`. Key modules:

| Directory | Purpose |
|-----------|---------|
| `App/` | App entry, AppDelegate, AppState |
| `Audio/` | AVAudioEngine capture |
| `Hotkey/` | Global hotkey handling |
| `Models/` | Whisper model download & management |
| `Permissions/` | macOS permission requests |
| `TextInsertion/` | Accessibility-based text insertion |
| `Transcription/` | whisper.cpp integration |
| `VAD/` | Silero VAD (voice activity detection) |
| `Views/` | SwiftUI views (menu bar, overlay, settings, onboarding) |
| `Tests/` | Unit tests |

## Principles

1. **User first** — Every decision should improve the user's experience. When in doubt, choose the simpler, more intuitive option.
2. **Simplicity** — Prefer straightforward solutions. Don't over-engineer or add abstraction layers that aren't needed yet.
3. **Maintainability** — Write code that's easy to read and change. Future-you (or another agent) will thank you.
4. **Privacy** — Everything runs locally. Never send audio or transcription data off-device.
5. **Clarity** - Don't make any non-obvious assumptions. When in doubt, provide your researched options and trade offs and ask developer to help choose.

## Standards

- Follow [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/) for all UX decisions.
- Follow [Apple's Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) and modern Swift/SwiftUI conventions.
- Use AppKit only where SwiftUI cannot do the job (AXUIElement, CGEvent, global event monitors).
- If you need to code/use any python scripts/packages, make sure to use `uv` with a virtualenv. If one doesn't exist already, ask developer if they want to create a new one.

## Workflow

- **Build**: Open `Aawaaz/Aawaaz.xcodeproj` in Xcode, or build from CLI:
  ```
  cd Aawaaz && xcodebuild -project Aawaaz.xcodeproj -scheme Aawaaz -configuration Debug build
  ```
- **Test**: Run tests via Xcode or `xcodebuild test`.
- **After every change**: Build and run tests. Fix what you broke. Don't leave the project in a non-compiling state.
- **Review your own work** — Re-read your changes, check for edge cases, and verify the UI behaves correctly before considering a task done.
- Never commit changes yourself. Leave that to the developer to do it themselves.
