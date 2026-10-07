import Combine
import Foundation
import OpenSpellCore

/// Settings shared by the app and the keyboard through the App Group, under the Mac app's key names.
@MainActor
final class SharedSettings: ObservableObject {
    static let shared = SharedSettings()
    private let defaults = SharedStorage.defaults

    @Published var language: CorrectionLanguage {
        didSet { defaults.set(language.rawValue, forKey: "language") }
    }
    @Published var keepHistory: Bool {
        didSet { defaults.set(keepHistory, forKey: "keepHistory") }
    }
    @Published var hasCompletedSetup: Bool {
        didSet { defaults.set(hasCompletedSetup, forKey: "hasCompletedSetup") }
    }

    private init() {
        language = CorrectionLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .auto
        keepHistory = defaults.object(forKey: "keepHistory") as? Bool ?? true
        hasCompletedSetup = defaults.bool(forKey: "hasCompletedSetup")
    }

    /// Picks up changes the other process (app or keyboard) made.
    func reload() {
        let language = CorrectionLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .auto
        if language != self.language { self.language = language }
        let keepHistory = defaults.object(forKey: "keepHistory") as? Bool ?? true
        if keepHistory != self.keepHistory { self.keepHistory = keepHistory }
    }

    // The keyboard leaves a heartbeat so the app can tell it's set up. It can only write it with Full Access.

    var keyboardLastSeen: Date? { defaults.object(forKey: "keyboard.lastSeen") as? Date }

    func recordKeyboardVisit() {
        defaults.set(Date(), forKey: "keyboard.lastSeen")
    }
}
