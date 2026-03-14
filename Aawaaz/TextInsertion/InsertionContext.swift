import AppKit

/// Describes the context in which text will be inserted: the target application,
/// the kind of text field, and any per-app insertion preferences.
///
/// Passed downstream to post-processing (Phase 3) for context-aware formatting.
struct InsertionContext: Sendable {

    /// The frontmost application's display name (e.g. "Safari", "VS Code").
    let appName: String

    /// The frontmost application's bundle identifier (e.g. "com.apple.Safari").
    let bundleIdentifier: String

    /// The kind of text element that is focused.
    let fieldType: TextFieldType

    /// The insertion method that was actually used.
    var insertionMethod: InsertionMethod = .accessibility

    /// Describes the kind of focused text element.
    enum TextFieldType: String, Codable, Sendable {
        case singleLine   // AXTextField
        case multiLine    // AXTextArea
        case comboBox     // AXComboBox
        case webArea      // AXWebArea (browser content editable)
        case unknown
    }

    /// Which insertion strategy was used for this insertion.
    enum InsertionMethod: String, Codable, Sendable {
        case accessibility
        case keystrokeSimulation
        case clipboardOnly
    }

    /// High-level category of the target application, used by post-processors
    /// to tailor tone and formatting (e.g., formal for email, casual for chat).
    ///
    /// Determined automatically from the app's bundle identifier via
    /// ``bundleIDToCategory``. Users can override per-app in settings
    /// (Step 3.5.7).
    enum AppCategory: String, Codable, CaseIterable, Sendable {
        case email
        case chat
        case document
        case code
        case terminal
        case browser
        case other
    }

    /// Known bundle-ID → category mappings.
    ///
    /// Used by ``appCategory`` to infer the category automatically.
    /// User overrides (stored in UserDefaults, Step 3.5.7) take precedence.
    static let bundleIDToCategory: [String: AppCategory] = [
        // Email
        "com.apple.mail": .email,
        "com.microsoft.Outlook": .email,
        // Chat / Messaging
        "com.tinyspeck.slackmacgap": .chat,
        "com.apple.MobileSMS": .chat,
        "com.hnc.Discord": .chat,
        "com.electron.whatsapp": .chat,
        "ru.keepcoder.Telegram": .chat,
        "com.facebook.archon": .chat,
        // Documents
        "com.microsoft.Word": .document,
        "com.apple.iWork.Pages": .document,
        "com.apple.TextEdit": .document,
        "com.apple.Notes": .document,
        "md.obsidian": .document,
        "notion.id": .document,
        // Code editors
        "com.apple.dt.Xcode": .code,
        "com.microsoft.VSCode": .code,
        "com.sublimetext.4": .code,
        // Terminal
        "com.googlecode.iterm2": .terminal,
        "com.apple.Terminal": .terminal,
        "dev.warp.Warp-Stable": .terminal,
        // Browsers
        "com.apple.Safari": .browser,
        "com.google.Chrome": .browser,
        "org.mozilla.firefox": .browser,
        "com.brave.Browser": .browser,
        "com.microsoft.edgemac": .browser,
        "company.thebrowser.Browser": .browser,
    ]

    /// Bundle ID prefixes that map to categories, checked when no exact
    /// match exists in ``bundleIDToCategory``.
    private static let prefixToCategory: [(String, AppCategory)] = [
        ("com.jetbrains.", .code),
    ]

    /// The inferred category for this app based on its bundle identifier.
    ///
    /// Resolution order:
    /// 1. User override (stored in UserDefaults, Step 3.5.7)
    /// 2. Exact match in ``bundleIDToCategory``
    /// 3. Prefix match in ``prefixToCategory``
    /// 4. `.other`
    var appCategory: AppCategory {
        // 1. User override
        let overrideKey = "appCategory.\(bundleIdentifier)"
        if let override = UserDefaults.standard.string(forKey: overrideKey),
           let category = AppCategory(rawValue: override) {
            return category
        }

        // 2. Exact match
        if let category = Self.bundleIDToCategory[bundleIdentifier] {
            return category
        }

        // 3. Prefix match
        for (prefix, category) in Self.prefixToCategory {
            if bundleIdentifier.hasPrefix(prefix) {
                return category
            }
        }

        return .other
    }

    /// A fallback context used when the frontmost app cannot be determined.
    static let unknown = InsertionContext(
        appName: "Unknown",
        bundleIdentifier: "",
        fieldType: .unknown
    )

    /// Build an `InsertionContext` from the currently focused element.
    ///
    /// Returns `nil` if no frontmost application can be determined.
    ///
    /// - Note: Uses `NSWorkspace` and Accessibility APIs — should be called
    ///   from the main thread. Consider adding `@MainActor` in a future
    ///   concurrency audit.
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
