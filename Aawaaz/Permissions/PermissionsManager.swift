import AVFoundation
import AppKit

/// Centralized permission checking for the app.
///
/// Handles microphone permission and accessibility (input monitoring) permission.
/// Accessibility is required for global hotkey monitoring of key events.
final class PermissionsManager {

    // MARK: - Microphone

    /// Current microphone authorization status.
    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Whether microphone access has been granted.
    static var isMicrophoneGranted: Bool {
        microphoneStatus == .authorized
    }

    /// Whether microphone permission has not yet been requested.
    static var isMicrophoneNotDetermined: Bool {
        microphoneStatus == .notDetermined
    }

    /// Request microphone permission. Returns `true` if granted.
    @discardableResult
    static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Accessibility (Input Monitoring)

    /// Whether accessibility (input monitoring) access has been granted.
    /// Required for global hotkey detection via NSEvent monitors.
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant accessibility permission.
    /// Opens the system prompt if permission has not been granted.
    static func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Open System Settings to the Accessibility privacy pane.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - First Launch

    private static let hasCompletedOnboardingKey = "hasCompletedOnboarding"

    /// Whether the user has completed the onboarding flow.
    static var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: hasCompletedOnboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasCompletedOnboardingKey) }
    }

    /// Whether onboarding should be shown (first launch or permissions not granted).
    static var shouldShowOnboarding: Bool {
        !hasCompletedOnboarding
    }
}
