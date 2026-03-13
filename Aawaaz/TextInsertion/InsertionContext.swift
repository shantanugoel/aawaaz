import AppKit

/// Describes the context in which text will be inserted: the target application,
/// the kind of text field, and any per-app insertion preferences.
///
/// Passed downstream to post-processing (Phase 3) for context-aware formatting.
struct InsertionContext {

    /// The frontmost application's display name (e.g. "Safari", "VS Code").
    let appName: String

    /// The frontmost application's bundle identifier (e.g. "com.apple.Safari").
    let bundleIdentifier: String

    /// The kind of text element that is focused.
    let fieldType: TextFieldType

    /// The insertion method that was actually used.
    var insertionMethod: InsertionMethod = .accessibility

    /// Describes the kind of focused text element.
    enum TextFieldType: String, Codable {
        case singleLine   // AXTextField
        case multiLine    // AXTextArea
        case comboBox     // AXComboBox
        case webArea      // AXWebArea (browser content editable)
        case unknown
    }

    /// Which insertion strategy was used for this insertion.
    enum InsertionMethod: String, Codable {
        case accessibility
        case keystrokeSimulation
        case clipboardOnly
    }

    /// Build an `InsertionContext` from the currently focused element.
    ///
    /// Returns `nil` if no frontmost application can be determined.
    static func current() -> InsertionContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }

        let appName = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        let bundleID = app.bundleIdentifier ?? ""
        let fieldType = detectFieldType()

        return InsertionContext(
            appName: appName,
            bundleIdentifier: bundleID,
            fieldType: fieldType
        )
    }

    /// Detect the focused element's text field type via the Accessibility API.
    private static func detectFieldType() -> TextFieldType {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else {
            return .unknown
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            axApp,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard result == .success, let ref = focusedRef else { return .unknown }

        let element = ref as! AXUIElement
        var roleRef: CFTypeRef?
        let roleResult = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleRef
        )
        guard roleResult == .success, let role = roleRef as? String else {
            return .unknown
        }

        switch role {
        case kAXTextFieldRole:  return .singleLine
        case kAXTextAreaRole:   return .multiLine
        case kAXComboBoxRole:   return .comboBox
        case "AXWebArea":       return .webArea
        default:                return .unknown
        }
    }
}
