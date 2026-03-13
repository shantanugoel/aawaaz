import SwiftUI

/// First-launch onboarding flow that guides the user through:
/// 1. Welcome screen
/// 2. Microphone permission
/// 3. Accessibility permission (for global hotkey)
/// 4. Model download
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var currentStep: OnboardingStep = .welcome
    @State private var micPermissionGranted = PermissionsManager.isMicrophoneGranted
    @State private var accessibilityGranted = PermissionsManager.isAccessibilityGranted

    // Timer to poll accessibility status (no callback API for this)
    let accessibilityTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            stepIndicator
                .padding(.top, 24)
                .padding(.bottom, 16)

            Divider()

            // Content
            Group {
                switch currentStep {
                case .welcome:
                    welcomeStep
                case .microphone:
                    microphoneStep
                case .accessibility:
                    accessibilityStep
                case .model:
                    modelStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation
            navigationButtons
                .padding(16)
        }
        .frame(width: 520, height: 480)
        .onReceive(accessibilityTimer) { _ in
            accessibilityGranted = PermissionsManager.isAccessibilityGranted
        }
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 16) {
            ForEach(OnboardingStep.allCases) { step in
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(stepColor(for: step))
                            .frame(width: 24, height: 24)
                        if isStepCompleted(step) {
                            Image(systemName: "checkmark")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                        } else {
                            Text("\(step.number)")
                                .font(.caption2.bold())
                                .foregroundStyle(currentStep == step ? .white : .secondary)
                        }
                    }
                    Text(step.title)
                        .font(.caption)
                        .foregroundStyle(currentStep == step ? .primary : .secondary)
                }
            }
        }
    }

    // MARK: - Welcome Step

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "mic.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Welcome to Aawaaz")
                .font(.largeTitle.bold())

            Text("System-wide voice-to-text dictation,\nfully local and private.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "lock.shield", text: "All transcription happens on-device")
                featureRow(icon: "globe", text: "Hindi, English, and Hinglish support")
                featureRow(icon: "bolt", text: "Fast — optimized for Apple Silicon")
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Microphone Step

    private var microphoneStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: micPermissionGranted ? "mic.fill" : "mic.slash")
                .font(.system(size: 48))
                .foregroundStyle(micPermissionGranted ? .green : .orange)

            Text("Microphone Access")
                .font(.title2.bold())

            Text("Aawaaz needs microphone access to hear your voice and transcribe it into text.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if micPermissionGranted {
                Label("Microphone access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            } else if PermissionsManager.isMicrophoneNotDetermined {
                Button("Grant Microphone Access") {
                    Task {
                        micPermissionGranted = await PermissionsManager.requestMicrophoneAccess()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                // Permission was denied
                VStack(spacing: 8) {
                    Label("Microphone access denied", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("Please enable it in System Settings → Privacy & Security → Microphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Accessibility Step

    private var accessibilityStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: accessibilityGranted ? "keyboard.fill" : "keyboard")
                .font(.system(size: 48))
                .foregroundStyle(accessibilityGranted ? .green : .orange)

            Text("Input Monitoring")
                .font(.title2.bold())

            Text("Aawaaz needs Input Monitoring (Accessibility) permission to detect your global hotkey shortcut, even when other apps are focused.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if accessibilityGranted {
                Label("Input monitoring granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
            } else {
                VStack(spacing: 12) {
                    Button("Grant Access") {
                        PermissionsManager.promptAccessibility()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text("You may need to add Aawaaz in System Settings → Privacy & Security → Input Monitoring")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Model Step

    private var modelStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundStyle(hasDownloadedModel ? .green : .blue)

            Text("Download a Model")
                .font(.title2.bold())

            if hasDownloadedModel {
                Label("Model ready!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.headline)
                Text("You can download additional models later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Download a speech recognition model to get started.\nWe recommend Turbo for the best balance of speed and quality.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            // Embedded model download list
            ModelDownloadView()
                .frame(maxHeight: 180)

            Spacer()
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Navigation

    private var navigationButtons: some View {
        HStack {
            if currentStep != .welcome {
                Button("Back") {
                    withAnimation { currentStep = currentStep.previous }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if currentStep == .model {
                Button("Get Started") {
                    PermissionsManager.hasCompletedOnboarding = true
                    appState.showOnboarding = false
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasDownloadedModel)
            } else {
                Button("Continue") {
                    withAnimation { currentStep = currentStep.next }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Helpers

    private var hasDownloadedModel: Bool {
        !appState.modelManager.downloadedModels.isEmpty
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.blue)
            Text(text)
                .font(.body)
        }
    }

    private func stepColor(for step: OnboardingStep) -> Color {
        if isStepCompleted(step) { return .green }
        if step == currentStep { return .blue }
        return .secondary.opacity(0.3)
    }

    private func isStepCompleted(_ step: OnboardingStep) -> Bool {
        switch step {
        case .welcome: return currentStep.rawValue > step.rawValue
        case .microphone: return micPermissionGranted && currentStep.rawValue > step.rawValue
        case .accessibility: return accessibilityGranted && currentStep.rawValue > step.rawValue
        case .model: return false
        }
    }
}

// MARK: - Onboarding Step Enum

private enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome = 0
    case microphone = 1
    case accessibility = 2
    case model = 3

    var id: Int { rawValue }
    var number: Int { rawValue + 1 }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .microphone: return "Microphone"
        case .accessibility: return "Access"
        case .model: return "Model"
        }
    }

    var next: OnboardingStep {
        OnboardingStep(rawValue: rawValue + 1) ?? self
    }

    var previous: OnboardingStep {
        OnboardingStep(rawValue: rawValue - 1) ?? self
    }
}
