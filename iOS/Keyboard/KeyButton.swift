import UIKit

/// A keyboard key: light keys for characters, darker ones for functions, swapped while pressed.
final class KeyButton: UIButton {
    enum Kind { case character, function }

    private let kind: Kind

    init(kind: Kind, title: String? = nil, symbol: String? = nil) {
        self.kind = kind
        super.init(frame: .zero)
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = symbol.map { UIImage(systemName: $0) } ?? nil
        config.baseForegroundColor = .label
        config.background.cornerRadius = 6
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var attributes = $0
            attributes.font = .systemFont(ofSize: 16)
            return attributes
        }
        configuration = config
        configurationUpdateHandler = { button in
            guard let key = button as? KeyButton else { return }
            button.configuration?.background.backgroundColor = key.color(pressed: button.isHighlighted)
        }
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setTitle(_ title: String) {
        configuration?.title = title
    }

    private func color(pressed: Bool) -> UIColor {
        let light = (kind == .character) != pressed
        return UIColor { traits in
            switch (light, traits.userInterfaceStyle == .dark) {
            case (true, false): .white
            case (true, true): UIColor(white: 0.42, alpha: 1)
            case (false, false): UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1)
            case (false, true): UIColor(white: 0.27, alpha: 1)
            }
        }
    }
}
