import AppKit
import ApplicationServices

/// Simulates text insertion via clipboard paste (Cmd+V).
///
/// Used as a fallback when the Accessibility API cannot insert text directly
/// (e.g., Electron apps, terminals, code editors). The workflow:
/// 1. Save current clipboard contents
/// 2. Set clipboard to the transcription text
/// 3. Simulate Cmd+V keystroke via `CGEvent`
/// 4. Restore original clipboard contents
///
/// Requires Accessibility permission for `CGEvent` posting.
final class KeystrokeSimulator {

    // MARK: - Errors

    enum SimulationError: Error, LocalizedError {
        case accessibilityNotGranted
        case eventCreationFailed

        var errorDescription: String? {
            switch self {
            case .accessibilityNotGranted:
                return "Accessibility permission is required for keystroke simulation."
            case .eventCreationFailed:
                return "Failed to create CGEvent for paste simulation."
            }
        }
    }

    /// Delay between setting the clipboard and simulating paste.
    /// Ensures the pasteboard is ready before the target app reads it.
    private static let clipboardSettleDelay: UInt64 = 50_000_000 // 50ms

    /// Delay after pasting, before restoring the original clipboard.
    /// Gives the target application time to read the pasted content.
    private static let pasteCompleteDelay: UInt64 = 100_000_000 // 100ms

    // MARK: - Public API

    /// Insert text by copying to clipboard and simulating Cmd+V.
    ///
    /// Saves and restores the original clipboard contents around the operation.
    ///
    /// - Parameter text: The text to insert via paste simulation.
    /// - Throws: ``SimulationError/eventCreationFailed`` if CGEvent creation fails.
    func insertText(_ text: String) async throws {
        // CGEvent.post silently drops events when Accessibility is not granted.
        guard AXIsProcessTrusted() else {
            throw SimulationError.accessibilityNotGranted
        }

        let savedClipboard = saveClipboard()
        setClipboard(text)

        do {
            try await Task.sleep(nanoseconds: Self.clipboardSettleDelay)
            try simulatePaste()
            try await Task.sleep(nanoseconds: Self.pasteCompleteDelay)
        } catch {
            restoreClipboard(savedClipboard)
            throw error
        }

        restoreClipboard(savedClipboard)
        print("[KeystrokeSimulator] Inserted text via Cmd+V paste simulation")
    }

    // MARK: - Clipboard Save / Restore

    /// Save current clipboard contents by deep-copying all pasteboard items.
    ///
    /// `NSPasteboardItem` references become invalid after the clipboard is modified,
    /// so each item's data is copied for every type it provides.
    private func saveClipboard() -> [NSPasteboardItem] {
        let pasteboard = NSPasteboard.general
        guard let items = pasteboard.pasteboardItems else { return [] }

        return items.map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    /// Overwrite the clipboard with the given text.
    private func setClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Restore previously saved clipboard contents.
    private func restoreClipboard(_ items: [NSPasteboardItem]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    // MARK: - Keystroke Simulation

    /// Simulate Cmd+V paste keystroke via CGEvent.
    ///
    /// Posts key-down and key-up events for the 'V' key with the Command modifier
    /// to the HID event tap, which delivers them to the frontmost application.
    private func simulatePaste() throws {
        // Virtual key code for 'V' on a US keyboard layout (0x09).
        let vKeyCode: CGKeyCode = 0x09

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false) else {
            throw SimulationError.eventCreationFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
