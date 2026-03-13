import AppKit
import ApplicationServices

/// Manages text insertion via the macOS Accessibility (AX) API.
///
/// Uses `AXUIElement` APIs to locate the focused text element in the frontmost
/// application and insert transcribed text at the current cursor position.
///
/// ## Insertion Strategies (tried in order)
///
/// 1. **Selected text replacement** — Sets `kAXSelectedTextAttribute`, which
///    replaces the current selection (or inserts at cursor if nothing is selected).
///    Least destructive; works in most native AppKit/SwiftUI text fields.
/// 2. **Value splice** — Reads the full `kAXValueAttribute` and selection range,
///    splices the new text in, then writes the entire value back. More destructive
///    but works in apps that don't support `kAXSelectedTextAttribute`.
///
/// ## Expected Compatibility
///
/// | Target                             | Expected Support                        |
/// |------------------------------------|-----------------------------------------|
/// | AppKit NSTextField / NSTextView     | ✅ Full (kAXSelectedTextAttribute)       |
/// | SwiftUI TextField / TextEditor      | ✅ Via AppKit backing                    |
/// | Electron apps (VS Code, Slack)      | ⚠️ Varies — may need keystroke fallback  |
/// | Safari / Chrome (contenteditable)   | ⚠️ Limited — AX tree depth varies        |
/// | Terminal.app / iTerm2               | ⚠️ Limited — prefer keystroke fallback   |
///
/// For apps where AX insertion fails, the caller should fall back to
/// ``KeystrokeSimulator`` (paste-based insertion).
final class AccessibilityManager {

    // MARK: - Errors

    enum InsertionError: Error, LocalizedError {
        case accessibilityNotGranted
        case noFrontmostApp
        case noFocusedElement
        case elementNotEditable

        var errorDescription: String? {
            switch self {
            case .accessibilityNotGranted:
                return "Accessibility permission is not granted."
            case .noFrontmostApp:
                return "No frontmost application found."
            case .noFocusedElement:
                return "No focused UI element found."
            case .elementNotEditable:
                return "The focused element is not an editable text field."
            }
        }
    }

    // MARK: - Permission Check

    /// Whether the app has Accessibility permission required for AX operations.
    static var hasPermission: Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Public API

    /// Insert text into the currently focused text element of the frontmost app.
    ///
    /// Tries insertion strategies in order from least-destructive to most-destructive.
    /// Throws if no strategy succeeds.
    ///
    /// - Parameter text: The text to insert.
    /// - Throws: ``InsertionError`` if insertion fails via all strategies.
    func insertText(_ text: String) throws {
        guard Self.hasPermission else {
            throw InsertionError.accessibilityNotGranted
        }

        let focusedElement = try getFocusedElement()

        guard isTextInputElement(focusedElement) else {
            throw InsertionError.elementNotEditable
        }

        // Strategy 1: Set selected text (preferred — least destructive)
        if trySetSelectedText(text, on: focusedElement) {
            print("[AX] Inserted text via kAXSelectedTextAttribute")
            return
        }

        // Strategy 2: Splice into value attribute
        if trySpliceIntoValue(text, on: focusedElement) {
            print("[AX] Inserted text via kAXValueAttribute splice")
            return
        }

        throw InsertionError.elementNotEditable
    }

    // MARK: - Element Discovery

    /// Retrieve the focused UI element from the frontmost application.
    private func getFocusedElement() throws -> AXUIElement {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw InsertionError.noFrontmostApp
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            axApp,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )

        guard result == .success, let ref = focusedRef else {
            throw InsertionError.noFocusedElement
        }

        return (ref as! AXUIElement)
    }

    /// Determine if an AX element represents an editable text input.
    ///
    /// Checks the element's role against known text roles. For non-standard roles
    /// (common in Electron and web-based apps), falls back to checking whether
    /// the value or selected-text attribute is settable.
    private func isTextInputElement(_ element: AXUIElement) -> Bool {
        guard let role = stringAttribute(kAXRoleAttribute, of: element) else {
            return isAttributeSettable(kAXValueAttribute, on: element)
        }

        let textRoles: Set<String> = [
            kAXTextFieldRole,
            kAXTextAreaRole,
            kAXComboBoxRole,
        ]

        if textRoles.contains(role) {
            return true
        }

        // Non-standard role — check if the element accepts text input.
        return isAttributeSettable(kAXSelectedTextAttribute, on: element)
            || isAttributeSettable(kAXValueAttribute, on: element)
    }

    // MARK: - Insertion Strategies

    /// Strategy 1: Replace the current selection with the given text.
    ///
    /// Uses `kAXSelectedTextAttribute`, which replaces the selected text. When
    /// nothing is selected (i.e. the cursor is at an insertion point), this
    /// effectively inserts text at the cursor position.
    private func trySetSelectedText(_ text: String, on element: AXUIElement) -> Bool {
        guard isAttributeSettable(kAXSelectedTextAttribute, on: element) else {
            return false
        }

        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        return result == .success
    }

    /// Strategy 2: Read the full value, splice in the new text, write back.
    ///
    /// Reads the current `kAXValueAttribute` and `kAXSelectedTextRangeAttribute`,
    /// inserts the text at the cursor position (or replaces the selection), and
    /// writes the entire value back. Then repositions the cursor to the end of the
    /// inserted text.
    private func trySpliceIntoValue(_ text: String, on element: AXUIElement) -> Bool {
        guard isAttributeSettable(kAXValueAttribute, on: element) else {
            return false
        }

        let currentValue = stringAttribute(kAXValueAttribute, of: element)
        let selection = selectedTextRange(of: element)

        // If we cannot read the current value, we must not assume the field is
        // empty — it may be a secure/redacted field. Fail so the caller can
        // fall back to a safer insertion method.
        guard let currentValue else {
            return false
        }

        let nsCurrentValue = currentValue as NSString
        let nsText = text as NSString
        let newValue: String
        let newCursorLocation: Int

        if let selection,
           selection.location >= 0,
           selection.location + selection.length <= nsCurrentValue.length {
            let nsRange = NSRange(location: selection.location, length: selection.length)
            newValue = nsCurrentValue.replacingCharacters(in: nsRange, with: text)
            newCursorLocation = selection.location + nsText.length
        } else {
            // No valid selection range — append to end.
            newValue = currentValue + text
            newCursorLocation = (newValue as NSString).length
        }

        let setResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            newValue as CFTypeRef
        )

        guard setResult == .success else {
            return false
        }

        // Best-effort: reposition cursor to end of inserted text.
        setCursorPosition(newCursorLocation, on: element)

        return true
    }

    // MARK: - AX Attribute Helpers

    /// Read a string attribute from an AX element.
    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard result == .success else { return nil }
        return ref as? String
    }

    /// Check whether an attribute can be written on the given element.
    private func isAttributeSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return result == .success && settable.boolValue
    }

    /// Read the selected text range (location + length in UTF-16 code units).
    private func selectedTextRange(of element: AXUIElement) -> (location: Int, length: Int)? {
        var ref: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &ref
        )
        guard result == .success, let axValue = ref else { return nil }

        // AXValue is always the correct type for range attributes.
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue as! AXValue, .cfRange, &range) else { return nil }

        return (location: range.location, length: range.length)
    }

    /// Set the cursor position (collapsed selection) on the element.
    private func setCursorPosition(_ location: Int, on element: AXUIElement) {
        var range = CFRange(location: location, length: 0)
        guard let value = AXValueCreate(.cfRange, &range) else { return }
        AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        )
    }
}
