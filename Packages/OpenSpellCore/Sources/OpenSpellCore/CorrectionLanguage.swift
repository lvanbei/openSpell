import Foundation

/// Language hint passed to the model. `auto` keeps whatever language the text is written in.
public enum CorrectionLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto, english, chinese, hindi, spanish, french, arabic, portuguese, russian,
         indonesian, german, japanese, turkish, korean, vietnamese, italian, dutch, polish

    public var id: String { rawValue }

    public var flag: String {
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

    public var name: String {
        switch self {
        case .auto: "Auto-detect"
        default: rawValue.capitalized
        }
    }
}
