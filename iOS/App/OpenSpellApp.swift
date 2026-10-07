import OpenSpellCore
import SwiftUI

@main
struct OpenSpellApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var settings = SharedSettings.shared

    init() {
        ModelStore.shared.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                Tab("Fix", systemImage: "text.badge.checkmark") { HomeView() }
                Tab("Models", systemImage: "brain") { ModelsView() }
                Tab("History", systemImage: "clock.arrow.circlepath") { HistoryView() }
                Tab("Settings", systemImage: "gearshape") { SettingsView() }
            }
            .fullScreenCover(isPresented: Binding(get: { !settings.hasCompletedSetup }, set: { _ in })) {
                OnboardingView()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                // The keyboard may have logged corrections or swapped a retired model meanwhile.
                ModelStore.shared.reload()
                SharedSettings.shared.reload()
                HistoryStore.shared.reload()
            }
        }
    }
}
