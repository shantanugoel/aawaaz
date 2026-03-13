import SwiftUI

@main
struct AawaazApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            AppMenuBarLabel(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Window("Welcome to Aawaaz", id: "onboarding") {
            OnboardingView()
                .environment(appState)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate()
                }
                .onDisappear {
                    NSApp.setActivationPolicy(.accessory)
                }
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}

/// Menu bar label that also opens the onboarding window on first launch.
private struct AppMenuBarLabel: View {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label("Aawaaz", systemImage: appState.menuBarIconName)
            .onAppear {
                if appState.showOnboarding {
                    openWindow(id: "onboarding")
                }
            }
    }
}
