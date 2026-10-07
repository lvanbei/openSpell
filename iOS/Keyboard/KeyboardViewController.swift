import OpenSpellCore
import os
import UIKit

final class KeyboardViewController: UIInputViewController {
    private enum Status {
        case idle, working
        case done(String), info(String), error(String)
    }

    private let fixer = TextFixer()
    private lazy var document = DocumentProxy(controller: self)
    private var task: Task<Void, Never>?
    private var deleteRepeat: Timer?

    private let fixButton = UIButton(type: .system)
    private let undoButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let globeKey = KeyButton(kind: .function, symbol: "globe")
    private let returnKey = KeyButton(kind: .function, title: "return")
    private var status = Status.idle { didSet { updateToolbar() } }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()
        MemoryLog.record("loaded")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if hasFullAccess {
            SharedSettings.shared.reload()
            ModelStore.shared.reload()
            SharedSettings.shared.recordKeyboardVisit()
        }
        status = .idle
        updateKeys()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        MemoryLog.record("appeared")
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        task?.cancel()
        stopDeleting()
    }

    override func viewWillLayoutSubviews() {
        globeKey.isHidden = !needsInputModeSwitchKey
        super.viewWillLayoutSubviews()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        document.hostDidReport()
        updateKeys()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        document.hostDidReport()
    }

    // MARK: Fix

    @objc private func fixTapped() {
        if let task {
            task.cancel()
            return
        }
        guard hasFullAccess else {
            status = .info("Turn on Allow Full Access: Settings › General › Keyboard › Keyboards › OpenSpell.")
            return
        }
        let language = SharedSettings.shared.language
        status = .working
        task = Task {
            defer {
                task = nil
                updateKeys()
                MemoryLog.record("after fix")
            }
            guard await fixer.refresh(document) else {
                status = .info("This app doesn't share its text. Select the text, then tap Fix.")
                return
            }
            guard let capture = TextFixer.capture(from: document) else {
                status = .info("Select or type some text first")
                return
            }
            do {
                let correction = try await correct(capture.text, language: language)
                guard correction.hasChanges else {
                    status = .done("No mistakes found")
                    return
                }
                switch await fixer.apply(correction.corrected, over: capture, in: document) {
                case .replaced:
                    log(correction)
                    status = .done("Corrected")
                case .unverified:
                    log(correction)
                    status = .info("Corrected — tap Undo if something looks wrong")
                case .textChanged, .unreadable:
                    UIPasteboard.general.string = correction.corrected
                    status = .info("Text changed — fix copied")
                }
            } catch is CancellationError {
                status = .idle
            } catch let error as URLError where error.code == .cancelled {
                status = .idle
            } catch let error as CorrectionError {
                status = .error(error == .tooLong || error == .modelNotReady(.apple) ? error.localizedDescription
                                : "\(error.localizedDescription) in the OpenSpell app")
            } catch {
                status = .error(error.localizedDescription)
            }
        }
        updateKeys()
    }

    @objc private func undoTapped() {
        guard task == nil else { return }
        task = Task {
            defer {
                task = nil
                updateKeys()
            }
            if await fixer.undo(in: document) {
                status = .done("Original text restored")
            } else {
                fixer.forgetLastFix()
                status = .info("Can't undo — the text changed")
            }
        }
        updateKeys()
    }

    private func log(_ correction: Correction) {
        guard SharedSettings.shared.keepHistory else { return }
        HistoryStore.record(HistoryItem(original: correction.original, corrected: correction.corrected,
                                        appName: "Keyboard", bundleID: nil, model: correction.model.displayName,
                                        duration: correction.duration))
    }

    private func correct(_ text: String, language: CorrectionLanguage) async throws -> Correction {
        #if DEBUG
        if SharedStorage.defaults.bool(forKey: "debug.fakeCorrections") { return Self.fakeCorrection(of: text) }
        #endif
        return try await CorrectionService.correct(text, language: language)
    }

    #if DEBUG
    /// Fixes a fixed list of typos without a model, to test writing back into host apps (Debug builds only).
    private static func fakeCorrection(of text: String) -> Correction {
        var fixed = text
        let typos = ["beleive": "believe", "definately": "definitely", "featur": "feature", "tommorow": "tomorrow",
                     "teh": "the", "thier": "their", "recieve": "receive"]
        for (typo, word) in typos {
            fixed = fixed.replacingOccurrences(of: "\\b\(typo)\\b", with: word, options: .regularExpression)
        }
        return Correction(original: text, corrected: fixed,
                          model: ModelEntry(kind: .cloud, repo: "debug", displayName: "Debug corrections"), duration: 0)
    }
    #endif

    // MARK: Keys

    @objc private func spaceTapped() { type(" ") }
    @objc private func returnTapped() { type("\n") }

    private func type(_ text: String) {
        fixer.forgetLastFix()
        textDocumentProxy.insertText(text)
        updateKeys()
    }

    @objc private func deletePressed() {
        deleteOnce()
        deleteRepeat?.invalidate()
        deleteRepeat = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.deleteRepeat = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.deleteOnce() }
                }
            }
        }
    }

    @objc private func stopDeleting() {
        deleteRepeat?.invalidate()
        deleteRepeat = nil
    }

    private func deleteOnce() {
        fixer.forgetLastFix()
        textDocumentProxy.deleteBackward()
        updateKeys()
    }

    // MARK: Layout and state

    private func buildLayout() {
        fixButton.addTarget(self, action: #selector(fixTapped), for: .touchUpInside)
        fixButton.accessibilityLabel = "Fix spelling"
        undoButton.configuration = .plain()
        undoButton.configuration?.image = UIImage(systemName: "arrow.uturn.backward")
        undoButton.addTarget(self, action: #selector(undoTapped), for: .touchUpInside)
        undoButton.accessibilityLabel = "Undo fix"
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.numberOfLines = 3
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.8
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let toolbar = UIStackView(arrangedSubviews: [fixButton, statusLabel, undoButton])
        toolbar.spacing = 10
        toolbar.alignment = .center

        let space = KeyButton(kind: .character, title: "space")
        space.addTarget(self, action: #selector(spaceTapped), for: .touchUpInside)
        let delete = KeyButton(kind: .function, symbol: "delete.left")
        delete.accessibilityLabel = "Delete"
        delete.addTarget(self, action: #selector(deletePressed), for: .touchDown)
        delete.addTarget(self, action: #selector(stopDeleting), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        returnKey.addTarget(self, action: #selector(returnTapped), for: .touchUpInside)
        globeKey.accessibilityLabel = "Next keyboard"
        globeKey.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        let keys = UIStackView(arrangedSubviews: [globeKey, space, delete, returnKey])
        keys.spacing = 6

        let stack = UIStackView(arrangedSubviews: [toolbar, keys])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        // Below required: the system animates the keyboard's height when it appears.
        let height = view.heightAnchor.constraint(equalToConstant: 114)
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            height,
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
            toolbar.heightAnchor.constraint(equalToConstant: 46),
            keys.heightAnchor.constraint(equalToConstant: 46),
            globeKey.widthAnchor.constraint(equalToConstant: 46),
            delete.widthAnchor.constraint(equalToConstant: 56),
            returnKey.widthAnchor.constraint(equalToConstant: 96),
        ])
        updateToolbar()
    }

    private func updateKeys() {
        let proxy = textDocumentProxy
        overrideUserInterfaceStyle = proxy.keyboardAppearance == .dark ? .dark : .unspecified
        returnKey.setTitle(Self.returnTitle(proxy.returnKeyType ?? .default))
        updateToolbar()
    }

    private func updateToolbar() {
        var fix = UIButton.Configuration.filled()
        fix.cornerStyle = .capsule
        fix.imagePadding = 6
        if task == nil {
            fix.title = "Fix"
            fix.image = UIImage(systemName: "text.badge.checkmark")
        } else {
            fix.title = "Cancel"
            fix.showsActivityIndicator = true
        }
        fixButton.configuration = fix
        fixButton.isEnabled = task != nil || !isSensitiveField
        undoButton.isEnabled = task == nil && fixer.canUndo

        switch status {
        case .idle: setStatus(idleHint, color: .secondaryLabel)
        case .working: setStatus("Correcting…", color: .secondaryLabel)
        case .done(let text): setStatus(text, color: .systemGreen)
        case .info(let text): setStatus(text, color: .label)
        case .error(let text): setStatus(text, color: .systemRed)
        }
    }

    private func setStatus(_ text: String, color: UIColor) {
        statusLabel.text = text
        statusLabel.textColor = color
    }

    private var idleHint: String {
        guard hasFullAccess else { return "Allow Full Access to fix text" }
        let store = ModelStore.shared
        guard let model = store.selected, store.isReady(model) else {
            if store.selected?.kind == .apple, let reason = AppleIntelligence.status.message { return reason }
            return "Choose a model in the OpenSpell app"
        }
        return "\(SharedSettings.shared.language.flag) \(model.displayName)"
    }

    private var isSensitiveField: Bool {
        let proxy = textDocumentProxy
        if proxy.isSecureTextEntry == true { return true }
        guard let type = proxy.textContentType.flatMap({ $0 }) else { return false }
        return [.password, .newPassword, .oneTimeCode, .creditCardNumber, .creditCardSecurityCode].contains(type)
    }

    private static func returnTitle(_ type: UIReturnKeyType) -> String {
        switch type {
        case .go: "go"
        case .google, .yahoo, .search: "search"
        case .join: "join"
        case .next: "next"
        case .route: "route"
        case .send: "send"
        case .done: "done"
        case .emergencyCall: "emergency"
        case .continue: "continue"
        default: "return"
        }
    }
}

/// Hands the keyboard's document to OpenSpellCore's TextFixer.
@MainActor
final class DocumentProxy: TextProxy {
    private unowned let controller: UIInputViewController
    private(set) var hostUpdates = 0

    init(controller: UIInputViewController) {
        self.controller = controller
    }

    func hostDidReport() {
        hostUpdates += 1
    }

    private var proxy: UITextDocumentProxy { controller.textDocumentProxy }

    var documentContextBeforeInput: String? { proxy.documentContextBeforeInput }
    var documentContextAfterInput: String? { proxy.documentContextAfterInput }
    var selectedText: String? { proxy.selectedText }
    var documentIdentifier: UUID { proxy.documentIdentifier }
    func insertText(_ text: String) { proxy.insertText(text) }
    func deleteBackward() { proxy.deleteBackward() }
    func adjustTextPosition(byCharacterOffset offset: Int) { proxy.adjustTextPosition(byCharacterOffset: offset) }
}

/// Keyboards are killed past a small memory limit, so log the footprint (Console › subsystem app.openspell.ios.keyboard).
enum MemoryLog {
    private static let logger = Logger(subsystem: "app.openspell.ios.keyboard", category: "memory")

    static func record(_ moment: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let footprint = result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
        let available = Double(os_proc_available_memory()) / 1_048_576
        logger.notice("\(moment, privacy: .public): footprint \(footprint, format: .fixed(precision: 1)) MB, available \(available, format: .fixed(precision: 1)) MB")
    }
}
