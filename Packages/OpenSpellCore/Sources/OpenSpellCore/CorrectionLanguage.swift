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

    /// ISO 639-1 code, or nil for auto-detect.
    public var code: String? {
        switch self {
        case .auto: nil
        case .english: "en"
        case .chinese: "zh"
        case .hindi: "hi"
        case .spanish: "es"
        case .french: "fr"
        case .arabic: "ar"
        case .portuguese: "pt"
        case .russian: "ru"
        case .indonesian: "id"
        case .german: "de"
        case .japanese: "ja"
        case .turkish: "tr"
        case .korean: "ko"
        case .vietnamese: "vi"
        case .italian: "it"
        case .dutch: "nl"
        case .polish: "pl"
        }
    }
}
