import AVFoundation
import AppKit

/// Centralized permission checking for the app.
///
/// Handles microphone and Accessibility permissions.
/// - **Microphone**: Required for audio capture / speech recognition.
/// - **Accessibility**: Required for (1) suppressing the global hotkey so it
///   does not leak into the frontmost app, and (2) inserting transcribed text
///   into arbitrary applications via the AX API.
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

    // MARK: - Accessibility

    /// Whether Accessibility access has been granted.
    ///
    /// This single permission covers both:
    /// - Global hotkey suppression (CGEvent tap)
    /// - Text insertion into other apps (AXUIElement)
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompt the user to grant Accessibility permission by opening System Settings.
    static func promptAccessibility() {
        openAccessibilitySettings()
    }

    /// Open System Settings to the Accessibility privacy pane.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Combined Checks

    /// Whether all permissions required for full functionality are granted.
    static var areRequiredPermissionsGranted: Bool {
        isMicrophoneGranted && isAccessibilityGranted
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
