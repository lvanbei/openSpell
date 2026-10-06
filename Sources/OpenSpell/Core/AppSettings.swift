import AppKit
import Combine
import ServiceManagement

enum BubblePosition: String, CaseIterable, Identifiable, Codable {
    case auto, top, bottom, cursor
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Auto"
        case .top: "Top"
        case .bottom: "Bottom"
        case .cursor: "Cursor"
        }
    }
}

/// Language hint passed to the model. `auto` keeps whatever language the text is written in.
enum CorrectionLanguage: String, CaseIterable, Identifiable, Codable {
    case auto, english, chinese, hindi, spanish, french, arabic, portuguese, russian,
         indonesian, german, japanese, turkish, korean, vietnamese, italian, dutch, polish

    var id: String { rawValue }

    var flag: String {
        switch self {
        case .auto: "🌐"
        case .english: "🇬🇧"
        case .chinese: "🇨🇳"
        case .hindi: "🇮🇳"
        case .spanish: "🇪🇸"
        case .french: "🇫🇷"
        case .arabic: "🇸🇦"
        case .portuguese: "🇧🇷"
        case .russian: "🇷🇺"
        case .indonesian: "🇮🇩"
        case .german: "🇩🇪"
        case .japanese: "🇯🇵"
        case .turkish: "🇹🇷"
        case .korean: "🇰🇷"
        case .vietnamese: "🇻🇳"
        case .italian: "🇮🇹"
        case .dutch: "🇳🇱"
        case .polish: "🇵🇱"
        }
    }

    var name: String {
        switch self {
        case .auto: "Auto-detect"
        default: rawValue.capitalized
        }
    }
}

/// Force-click sensitivity. The value is an arbitrary 50…550 scale (Medium = 300)
/// mapped onto the stage-1 trackpad pressure, so a correction fires *before*
/// the system force click (Look Up) kicks in.
enum ForceSensitivity {
    static let range: ClosedRange<Double> = 50...550
    static let light: Double = 100
    static let medium: Double = 300
    static let firm: Double = 500

    /// Stage-1 pressure (0…1) required to trigger.
    static func pressureThreshold(for value: Double) -> Double {
        min(0.99, 0.45 + value / 1000)
    }

    /// Inverse of `pressureThreshold`, used by calibration.
    static func value(forPressure p: Double) -> Double {
        ((p - 0.45) * 1000).clamped(to: range)
    }

    static func label(for value: Double) -> String {
        switch value {
        case ..<200: "Light"
        case ..<400: "Medium"
        default: "Firm"
        }
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var language: CorrectionLanguage {
        didSet { defaults.set(language.rawValue, forKey: "language") }
    }
    @Published var forceClickEnabled: Bool {
        didSet { defaults.set(forceClickEnabled, forKey: "forceClickEnabled") }
    }
    @Published var forceSensitivity: Double {
        didSet { defaults.set(forceSensitivity, forKey: "forceSensitivity") }
    }
    @Published var bubblePosition: BubblePosition {
        didSet { defaults.set(bubblePosition.rawValue, forKey: "bubblePosition") }
    }
    @Published var hotKey: KeyCombo? {
        didSet {
            if let hotKey, let data = try? JSONEncoder().encode(hotKey) {
                defaults.set(data, forKey: "hotKey")
            } else {
                defaults.set(Data(), forKey: "hotKey") // explicit "none"
            }
        }
    }
    @Published var hasCompletedSetup: Bool {
        didSet { defaults.set(hasCompletedSetup, forKey: "hasCompletedSetup") }
    }
    @Published var keepHistory: Bool {
        didSet { defaults.set(keepHistory, forKey: "keepHistory") }
    }

    @Published private(set) var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    private init() {
        language = CorrectionLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .auto
        forceClickEnabled = defaults.object(forKey: "forceClickEnabled") as? Bool ?? true
        forceSensitivity = defaults.object(forKey: "forceSensitivity") as? Double ?? ForceSensitivity.medium
        bubblePosition = BubblePosition(rawValue: defaults.string(forKey: "bubblePosition") ?? "") ?? .auto
        hasCompletedSetup = defaults.bool(forKey: "hasCompletedSetup")
        keepHistory = defaults.object(forKey: "keepHistory") as? Bool ?? true

        if let data = defaults.data(forKey: "hotKey") {
            hotKey = data.isEmpty ? nil : (try? JSONDecoder().decode(KeyCombo.self, from: data))
        } else {
            hotKey = .defaultCombo
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("OpenSpell: launch-at-login change failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
