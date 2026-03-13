import AppKit
import os.log

/// Orchestrates text insertion into the frontmost application.
///
/// Tries insertion strategies in order of preference:
/// 1. **Accessibility API** — least destructive, native text field manipulation
/// 2. **Keystroke simulation** — clipboard paste via simulated Cmd+V
/// 3. **Clipboard only** — copies text and shows a notification
///
/// Per-app overrides allow forcing a specific strategy for applications where
/// the default cascade doesn't work well (e.g. always use keystroke simulation
/// for Terminal).
final class TextInsertionManager {

    private let accessibilityManager = AccessibilityManager()
    private let keystrokeSimulator = KeystrokeSimulator()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Aawaaz",
        category: "TextInsertion"
    )

    // MARK: - Per-App Preferences

    /// UserDefaults key prefix for per-app insertion method overrides.
    private static let perAppPrefKeyPrefix = "insertionMethod."

    /// Retrieve the preferred insertion method for a given bundle identifier.
    func preferredMethod(forBundleID bundleID: String) -> InsertionContext.InsertionMethod? {
        guard let raw = UserDefaults.standard.string(forKey: Self.perAppPrefKeyPrefix + bundleID),
              let method = InsertionContext.InsertionMethod(rawValue: raw) else {
            return nil
        }
        return method
    }

    /// Set (or clear) a per-app insertion method override.
    func setPreferredMethod(
        _ method: InsertionContext.InsertionMethod?,
        forBundleID bundleID: String
    ) {
        let key = Self.perAppPrefKeyPrefix + bundleID
        if let method {
            UserDefaults.standard.set(method.rawValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Public API

    /// Insert text into the currently focused text field of the frontmost app.
    ///
    /// Returns an `InsertionContext` describing where and how the text was inserted.
    /// The context can be forwarded to post-processing in Phase 3.
    @discardableResult
    func insertText(_ text: String) async -> InsertionContext {
        var context = InsertionContext.current() ?? InsertionContext(
            appName: "Unknown",
            bundleIdentifier: "",
            fieldType: .unknown
        )

        // Check for a per-app override
        if let override = preferredMethod(forBundleID: context.bundleIdentifier) {
            context.insertionMethod = override
            Self.logger.info("Using per-app override (\(override.rawValue)) for \(context.appName)")

            switch override {
            case .accessibility:
                if tryAccessibility(text) { return context }
                // Override failed — fall through to cascade
                Self.logger.warning("Per-app AX override failed for \(context.appName), cascading")

            case .keystrokeSimulation:
                if await tryKeystrokeSimulation(text) {
                    return context
                }
                // Override failed — fall through to clipboard
                Self.logger.warning("Per-app keystroke override failed for \(context.appName), falling back to clipboard")
                clipboardOnly(text)
                context.insertionMethod = .clipboardOnly
                return context

            case .clipboardOnly:
                clipboardOnly(text)
                return context
            }
        }

        // Default cascade: AX → Keystroke → Clipboard
        if tryAccessibility(text) {
            context.insertionMethod = .accessibility
            Self.logger.info("Inserted via Accessibility API into \(context.appName)")
            return context
        }

        if await tryKeystrokeSimulation(text) {
            context.insertionMethod = .keystrokeSimulation
            Self.logger.info("Inserted via keystroke simulation into \(context.appName)")
            return context
        }

        clipboardOnly(text)
        context.insertionMethod = .clipboardOnly
        Self.logger.info("Copied to clipboard (fallback) for \(context.appName)")
        return context
    }

    // MARK: - Strategy Implementations

    /// Attempt insertion via the Accessibility API. Returns `true` on success.
    private func tryAccessibility(_ text: String) -> Bool {
        do {
            try accessibilityManager.insertText(text)
            return true
        } catch {
            Self.logger.debug("AX insertion failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Attempt insertion via keystroke simulation (Cmd+V paste). Returns `true` on success.
    private func tryKeystrokeSimulation(_ text: String) async -> Bool {
        do {
            try await keystrokeSimulator.insertText(text)
            return true
        } catch {
            Self.logger.debug("Keystroke simulation failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Last-resort: copy to clipboard. The overlay (managed by the pipeline)
    /// already shows "Copied to clipboard", so no additional notification is needed.
    private func clipboardOnly(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
