import AppKit
import ApplicationServices
import Combine

/// Powers the Settings › Test tab: automatic health checks, live trigger tests,
/// and a real end-to-end correction inside TextEdit.
@MainActor
final class Diagnostics: ObservableObject {
    static let shared = Diagnostics()

    enum Status: Equatable {
        case pending, running, pass, warn, fail, off
    }

    struct Check: Identifiable, Equatable {
        enum ID: String, CaseIterable { case accessibility, shortcut, forceClick, model, modelResponse }
        let id: ID
        var title: String
        var status: Status = .pending
        var detail: String = ""
        /// Optional rich result (sample correction diff).
        var sampleOriginal: String?
        var sampleCorrected: String?
    }

    static let sample = "I beleive we can definately ship the new featur by tommorow."
    private static let typos = ["beleive", "definately", "featur ", "tommorow"]

    @Published private(set) var checks: [Check] = [
        Check(id: .accessibility, title: "Accessibility permission"),
        Check(id: .shortcut, title: "Keyboard shortcut"),
        Check(id: .forceClick, title: "Force click listener"),
        Check(id: .model, title: "Language model"),
        Check(id: .modelResponse, title: "Model answers a sample"),
    ]
    @Published private(set) var isRunningChecks = false

    // Live listeners
    enum Listen: Equatable { case idle, waiting, received(Date), timedOut }
    @Published private(set) var shortcutListen: Listen = .idle
    @Published private(set) var forceListen: Listen = .idle
    @Published private(set) var livePressure: Double = 0
    private var listenTimeouts: [String: DispatchWorkItem] = [:]
    private var pressureSub: AnyCancellable?

    // End-to-end
    enum E2E: Equatable {
        case idle
        case running(String)
        case pass(String)
        case fail(String)
    }
    @Published private(set) var e2e: E2E = .idle
    @Published private(set) var e2eOriginal: String?
    @Published private(set) var e2eResult: String?

    // MARK: - Trigger interception

    /// Called by the hotkey handler. Returns true when a test consumed the trigger.
    func interceptShortcut() -> Bool {
        guard shortcutListen == .waiting else { return false }
        shortcutListen = .received(Date())
        listenTimeouts["shortcut"]?.cancel()
        NSSound(named: "Tink")?.play()
        return true
    }

    /// Called by the force-click handler. Returns true when a test consumed the trigger.
    func interceptForceClick() -> Bool {
        guard forceListen == .waiting else { return false }
        forceListen = .received(Date())
        listenTimeouts["force"]?.cancel()
        pressureSub = nil
        return true
    }

    func listenForShortcut() {
        shortcutListen = .waiting
        schedule("shortcut", after: 15) { [weak self] in
            if self?.shortcutListen == .waiting { self?.shortcutListen = .timedOut }
        }
    }

    func listenForForceClick() {
        ForceTouchMonitor.shared.resetDiagnostics()
        forceListen = .waiting
        pressureSub = ForceTouchMonitor.shared.$livePressure
            .receive(on: RunLoop.main)
            .sink { [weak self] p in self?.livePressure = p }
        schedule("force", after: 20) { [weak self] in
            guard let self, self.forceListen == .waiting else { return }
            self.forceListen = .timedOut
            self.pressureSub = nil
            self.livePressure = 0
        }
    }

    private func schedule(_ key: String, after seconds: Double, _ block: @escaping () -> Void) {
        listenTimeouts[key]?.cancel()
        let work = DispatchWorkItem(block: block)
        listenTimeouts[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: - Automatic checks

    func runChecks() async {
        guard !isRunningChecks else { return }
        isRunningChecks = true
        defer { isRunningChecks = false }
        for i in checks.indices {
            checks[i].status = .pending
            checks[i].detail = ""
            checks[i].sampleOriginal = nil
            checks[i].sampleCorrected = nil
        }

        // 1. Accessibility
        update(.accessibility) {
            if AccessibilityPermission.isTrusted {
                $0.status = .pass; $0.detail = "Granted — OpenSpell can read and replace selections."
            } else {
                $0.status = .fail; $0.detail = "Not granted. Open System Settings › Privacy & Security › Accessibility and enable OpenSpell."
            }
        }

        // 2. Shortcut
        update(.shortcut) {
            let hk = HotKeyCenter.shared
            if let combo = AppSettings.shared.hotKey {
                if hk.isRegistered {
                    $0.status = .pass; $0.detail = "\(combo.displayString) is registered system-wide."
                } else {
                    $0.status = .fail
                    $0.detail = "\(combo.displayString) couldn't be registered (error \(hk.registrationError ?? 0)). Another app probably uses it — quit it or record a different shortcut."
                }
            } else {
                $0.status = .warn; $0.detail = "No shortcut set. Record one in the Shortcut tab."
            }
        }

        // 3. Force click
        update(.forceClick) {
            if !AppSettings.shared.forceClickEnabled {
                $0.status = .off; $0.detail = "Disabled in General. The keyboard shortcut still works."
            } else if !ForceTouchMonitor.systemForceClickEnabled {
                $0.status = .fail
                $0.detail = "“Force Click and haptic feedback” is turned off in System Settings › Trackpad, so macOS doesn't report firm presses. Turn it on."
            } else if ForceTouchMonitor.shared.isRunning || ForceTouchMonitor.shared.hasGlobalMonitor {
                $0.status = ForceTouchMonitor.shared.isRunning ? .pass : .warn
                $0.detail = "Listening. Trigger at \(Int(ForceSensitivity.pressureThreshold(for: AppSettings.shared.forceSensitivity) * 100)) % pressure (\(ForceSensitivity.label(for: AppSettings.shared.forceSensitivity)))."
            } else {
                $0.status = .fail; $0.detail = "Event tap not installed — this needs Accessibility permission."
            }
        }

        // 4. Model configured
        let store = ModelStore.shared
        var modelUsable = false
        update(.model) {
            guard let m = store.selected else {
                $0.status = .fail; $0.detail = "No model selected. Pick one in the Models tab."; return
            }
            switch m.kind {
            case .cloud:
                if store.hasAPIKey {
                    let key = OpenRouterClient.apiKey ?? ""
                    if key.hasPrefix("sk-or-") {
                        $0.status = .pass; $0.detail = "\(m.displayName) (cloud, OpenRouter)."
                    } else {
                        $0.status = .warn; $0.detail = "\(m.displayName) — the saved key doesn't look like an OpenRouter key (sk-or-v1-…)."
                    }
                    modelUsable = true
                } else {
                    $0.status = .fail; $0.detail = "\(m.displayName) needs an OpenRouter API key (Models tab)."
                }
            case .gemini:
                if store.hasGeminiKey {
                    $0.status = .pass; $0.detail = "\(m.displayName) (cloud, Google Gemini API)."
                    modelUsable = true
                } else {
                    $0.status = .fail; $0.detail = "\(m.displayName) needs a Gemini API key (Models tab)."
                }
            case .local:
                switch store.state(of: m) {
                case .ready:
                    $0.status = .pass; $0.detail = "\(m.displayName) (on-device, MLX)."; modelUsable = true
                case .downloading(let p):
                    $0.status = .warn; $0.detail = "\(m.displayName) is still downloading (\(Int(p * 100)) %)."
                case .notDownloaded:
                    $0.status = .fail; $0.detail = "\(m.displayName) isn't downloaded."
                case .failed(let e):
                    $0.status = .fail; $0.detail = "\(m.displayName) download failed: \(e)"
                }
            }
        }

        // 5. Model response
        guard modelUsable else {
            update(.modelResponse) { $0.status = .fail; $0.detail = "Skipped — no usable model." }
            return
        }
        update(.modelResponse) { $0.status = .running; $0.detail = "Asking the model… (a local model loads on first use)" }
        let start = Date()
        do {
            let raw = try await store.complete(system: CorrectionPrompt.system(language: AppSettings.shared.language),
                                               user: Self.sample)
            let fixed = CorrectionPrompt.postProcess(raw, original: Self.sample)
            let seconds = Date().timeIntervalSince(start)
            let remaining = Self.typos.filter { fixed.contains($0) }
            update(.modelResponse) {
                $0.sampleOriginal = Self.sample
                $0.sampleCorrected = fixed
                if fixed == Self.sample {
                    $0.status = .fail; $0.detail = "The model returned the text unchanged (\(String(format: "%.1f", seconds)) s)."
                } else if !remaining.isEmpty {
                    $0.status = .warn; $0.detail = "Answered in \(String(format: "%.1f", seconds)) s but missed: \(remaining.joined(separator: ", "))."
                } else {
                    $0.status = .pass; $0.detail = "Answered in \(String(format: "%.1f", seconds)) s."
                }
            }
        } catch {
            update(.modelResponse) { $0.status = .fail; $0.detail = error.localizedDescription }
        }
    }

    private func update(_ id: Check.ID, _ change: (inout Check) -> Void) {
        guard let i = checks.firstIndex(where: { $0.id == id }) else { return }
        change(&checks[i])
    }

    // MARK: - End-to-end test in TextEdit

    /// Opens a scratch document in TextEdit, selects its text through Accessibility and runs
    /// the exact same pipeline as the shortcut (AX read → model → paste back), then verifies.
    func runEndToEnd() async {
        guard !isE2ERunning else { return }
        e2eOriginal = nil
        e2eResult = nil

        guard AccessibilityPermission.isTrusted else {
            e2e = .fail("Accessibility permission is required.")
            return
        }
        guard let model = ModelStore.shared.selected, ModelStore.shared.isReady(model) else {
            e2e = .fail("No ready language model — fix the “Language model” check first.")
            return
        }

        e2e = .running("Opening TextEdit…")
        let stamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory.appending(path: "OpenSpell Test \(stamp).txt")
        do {
            try Self.sample.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            e2e = .fail("Couldn't create the scratch file: \(error.localizedDescription)")
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }

        guard let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
            e2e = .fail("TextEdit isn't installed.")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let app: NSRunningApplication
        do {
            app = try await NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: config)
        } catch {
            e2e = .fail("Couldn't open TextEdit: \(error.localizedDescription)")
            return
        }

        // Wait for the document's text area to be focused.
        e2e = .running("Waiting for the document…")
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1)
        var textArea: AXUIElement?
        for _ in 0..<40 {
            app.activate()
            if let el = Self.focusedElement(of: axApp),
               Self.string(el, kAXRoleAttribute) == kAXTextAreaRole as String,
               Self.string(el, kAXValueAttribute)?.contains("beleive") == true,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                textArea = el
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let textArea else {
            e2e = .fail("TextEdit didn't come to the front with the test document.")
            return
        }

        // Select everything through Accessibility (exercises the same API apps expose).
        e2e = .running("Selecting the text…")
        let length = (Self.string(textArea, kAXValueAttribute) ?? "").utf16.count
        var range = CFRange(location: 0, length: length)
        if let value = AXValueCreate(.cfRange, &range) {
            AXUIElementSetAttributeValue(textArea, kAXSelectedTextRangeAttribute as CFString, value)
        }
        try? await Task.sleep(for: .milliseconds(200))
        let selected = Self.string(textArea, kAXSelectedTextAttribute) ?? ""
        guard !selected.isEmpty else {
            e2e = .fail("Couldn't select text in TextEdit through Accessibility.")
            return
        }
        e2eOriginal = selected

        // Run the real pipeline.
        e2e = .running("Correcting with \(model.displayName)…")
        let outcome = await CorrectionEngine.shared.runForTest()

        try? await Task.sleep(for: .milliseconds(700)) // let TextEdit process the paste
        let after = Self.string(textArea, kAXValueAttribute) ?? ""
        e2eResult = after

        // Bring the Test tab back.
        WindowManager.shared.showSettings(tab: .test)

        switch outcome.status {
        case .replaced:
            let remaining = Self.typos.filter { after.contains($0) }
            if after == Self.sample {
                e2e = .fail("The paste didn't change the document.")
            } else if after.contains(Self.sample) || after.count > Self.sample.count * 2 {
                e2e = .fail("Text was inserted instead of replacing the selection.")
            } else if !remaining.isEmpty {
                e2e = .pass("Replaced in TextEdit in \(String(format: "%.1f", outcome.duration)) s, but the model missed: \(remaining.joined(separator: ", ")).")
            } else {
                e2e = .pass("Selection read, corrected and replaced in TextEdit in \(String(format: "%.1f", outcome.duration)) s.")
            }
        case .copiedToClipboard(let reason):
            e2e = .fail("Couldn't paste back (\(reason)); the fix went to the clipboard instead.")
        case .noMistakes:
            e2e = .fail("The model said there were no mistakes.")
        case .noSelection:
            e2e = .fail("OpenSpell couldn't read the selection in TextEdit.")
        case .notReady(let m), .failed(let m):
            e2e = .fail(m)
        }
    }

    var isE2ERunning: Bool {
        if case .running = e2e { return true }
        return false
    }

    // MARK: AX helpers

    private static func focusedElement(of app: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
