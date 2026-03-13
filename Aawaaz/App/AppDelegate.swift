import AppKit

/// NSApplicationDelegate for AppKit-level setup.
///
/// Onboarding is handled via a native SwiftUI `Window` scene (not NSWindow)
/// so SwiftUI manages the full event dispatch lifecycle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // If onboarding will be shown, pre-emptively switch to regular activation
        // policy so the SwiftUI Window can receive focus and events.
        if PermissionsManager.shouldShowOnboarding {
            NSApp.setActivationPolicy(.regular)
        }
    }
}
