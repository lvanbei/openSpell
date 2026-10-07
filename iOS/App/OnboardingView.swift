import OpenSpellCore
import SwiftUI

/// First-run setup: what OpenSpell does, adding the keyboard with Full Access, a model, and a try-out.
struct OnboardingView: View {
    @ObservedObject private var settings = SharedSettings.shared
    @State private var step = 0
    private let lastStep = 3

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case 0: WelcomeStep()
                case 1: KeyboardStep()
                case 2: ModelStep()
                default: TryStep()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step > 0 { Button("Back") { step -= 1 } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(step == lastStep ? "Done" : "Next") {
                        if step == lastStep { settings.hasCompletedSetup = true } else { step += 1 }
                    }
                    .bold()
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

private struct StepHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            Text(title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(subtitle).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        Form {
            StepHeader(symbol: "text.badge.checkmark", title: "Fix typos in any app",
                       subtitle: "Write anywhere, tap Fix on the OpenSpell keyboard, and the corrected text replaces yours.")
            Section {
                Label("Fixes the selection, or the text before the cursor.", systemImage: "character.cursor.ibeam")
                Label("Only fixes mistakes. It never rewrites or translates.", systemImage: "checkmark.seal")
                Label("Use Google Gemini or any OpenRouter model with your own key.", systemImage: "cloud")
                Label("A history of every fix, so you can go back.", systemImage: "clock.arrow.circlepath")
            }
        }
    }
}

private struct KeyboardStep: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            StepHeader(symbol: "keyboard", title: "Add the OpenSpell keyboard",
                       subtitle: "Turn it on once in Settings. You'll switch to it with the globe key when you want a fix.")
            Section {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .bold()
                Label("Tap Keyboards and turn on OpenSpell.", systemImage: "1.circle")
                Label("Turn on Allow Full Access.", systemImage: "2.circle")
            } footer: {
                Text("If Keyboards isn't listed there, go to General › Keyboard › Keyboards › Add New Keyboard.")
            }
            Section("Why Full Access?") {
                Text("""
                Without it, iOS doesn't let a keyboard use the network or read the settings you choose here, \
                so it can't reach your model. OpenSpell sends text only when you tap Fix, and only to the \
                provider you choose. It doesn't log or keep what you type.
                """)
                .font(.footnote)
            }
            Section("Status") {
                KeyboardStatusRow()
            }
        }
    }
}

private struct ModelStep: View {
    var body: some View {
        Form {
            StepHeader(symbol: "brain", title: "Choose a language model",
                       subtitle: "Paste an API key. You can change this any time in Models.")
            Section {
                KeyField(provider: .gemini)
            } header: {
                Text("Google Gemini")
            } footer: {
                Text("Free tier available. Your text is sent to Google when you tap Fix.")
            }
            Section {
                KeyField(provider: .openRouter)
            } header: {
                Text("OpenRouter")
            } footer: {
                Text("Free models work with a free key. Your text is sent to OpenRouter when you tap Fix.")
            }
            Section {
                ModelStatusRow()
            }
        }
    }
}

private struct TryStep: View {
    var body: some View {
        Form {
            StepHeader(symbol: "sparkles", title: "Try it",
                       subtitle: "Tap in the text, switch to OpenSpell with the globe key, then tap Fix.")
            Section {
                Playground()
            }
            Section {
                KeyboardStatusRow()
                ModelStatusRow()
            }
        }
    }
}
