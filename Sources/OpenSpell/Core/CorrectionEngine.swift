import AppKit

/// Orchestrates one correction: read selection → show bubble → ask the model → write back → log.
@MainActor
final class CorrectionEngine {
    static let shared = CorrectionEngine()

    enum Source { case shortcut, forceClick, test }

    /// What happened during a run — used by the Test tab.
    struct Outcome {
        enum Status: Equatable {
            case replaced
            case copiedToClipboard(String)
            case noMistakes
            case noSelection
            case notReady(String)
            case failed(String)
        }
        var status: Status
        var original: String?
        var corrected: String?
        var model: String?
        var appName: String?
        var duration: TimeInterval = 0
    }

    private(set) var isRunning = false
    private var task: Task<Void, Never>?

    static let maxCharacters = 12_000

    func trigger(source: Source) {
        guard !isRunning else { NSSound.beep(); return }
        guard AccessibilityPermission.isTrusted else {
            AccessibilityPermission.request()
            Bubble.shared.flash(.error("OpenSpell needs Accessibility access"), anchor: nil)
            WindowManager.shared.showSetupAssistant()
            return
        }
        isRunning = true
        task = Task {
            _ = await run(source: source)
            isRunning = false
        }
    }

    /// Runs one correction on the current selection and reports the outcome (used by self-tests).
    func runForTest() async -> Outcome {
        guard !isRunning else { return Outcome(status: .failed("Another correction is already running")) }
        isRunning = true
        defer { isRunning = false }
        return await run(source: .test)
    }

    func cancel() { task?.cancel() }

    private func run(source: Source) async -> Outcome {
        guard let snapshot = await TextAccess.captureSelection(),
              !snapshot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // A force click without a selection is just a click — stay silent.
            if source != .forceClick { Bubble.shared.flash(.info("Select some text first"), anchor: nil) }
            return Outcome(status: .noSelection)
        }
        var outcome = Outcome(status: .noSelection, original: snapshot.text, appName: snapshot.app?.localizedName)

        guard snapshot.text.count <= Self.maxCharacters else {
            let message = "Selection is too long (max \(Self.maxCharacters) characters)"
            Bubble.shared.flash(.info(message), anchor: snapshot.screenRect)
            outcome.status = .failed(message)
            return outcome
        }

        let store = ModelStore.shared
        guard let model = store.selected, store.isReady(model) else {
            let message = switch store.selected?.kind {
            case .cloud: "Add your OpenRouter API key"
            case .gemini: "Add your Gemini API key"
            default: "Choose a language model first"
            }
            Bubble.shared.flash(.error(message), anchor: snapshot.screenRect)
            if source != .test { WindowManager.shared.showSettings(tab: .models) }
            outcome.status = .notReady(message)
            return outcome
        }
        outcome.model = model.displayName

        Bubble.shared.show(.correcting, anchor: snapshot.screenRect)
        let started = Date()

        do {
            let system = CorrectionPrompt.system(language: AppSettings.shared.language)
            let raw = try await store.complete(system: system, user: CorrectionPrompt.user(snapshot.text))
            try Task.checkCancellation()
            let corrected = CorrectionPrompt.postProcess(raw, original: snapshot.text)
            outcome.corrected = corrected
            outcome.duration = Date().timeIntervalSince(started)

            if corrected == snapshot.text {
                Bubble.shared.flash(.done("No mistakes found"), anchor: snapshot.screenRect)
                outcome.status = .noMistakes
                return outcome
            }

            let result = await TextAccess.writeBack(corrected, over: snapshot)

            if AppSettings.shared.keepHistory {
                HistoryStore.shared.add(HistoryItem(
                    original: snapshot.text, corrected: corrected,
                    appName: snapshot.app?.localizedName ?? "Unknown app",
                    bundleID: snapshot.app?.bundleIdentifier,
                    model: model.displayName,
                    duration: outcome.duration))
            }

            switch result {
            case .replaced:
                Bubble.shared.flash(.done("Corrected"), anchor: snapshot.screenRect)
                outcome.status = .replaced
            case .copiedToClipboard(let reason):
                Bubble.shared.flash(.info("\(reason) — fix copied, press ⌘V"), anchor: snapshot.screenRect, duration: 3.5)
                outcome.status = .copiedToClipboard(reason)
            }
        } catch is CancellationError {
            Bubble.shared.hide()
            outcome.status = .failed("Cancelled")
        } catch {
            NSLog("OpenSpell: correction failed: \(error)")
            Bubble.shared.flash(.error(error.localizedDescription), anchor: snapshot.screenRect, duration: 4)
            outcome.status = .failed(error.localizedDescription)
        }
        return outcome
    }
}
