// swift-tools-version: 6.2
import PackageDescription

// Platform-neutral OpenSpell logic shared by the macOS app, the iOS app and the iOS keyboard.
// OpenSpellCore stays Foundation-only so the keyboard, which has very little memory, never loads SwiftUI.
let package = Package(
    name: "OpenSpellCore",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [
        .library(name: "OpenSpellCore", targets: ["OpenSpellCore"]),
        .library(name: "OpenSpellUI", targets: ["OpenSpellUI"]),
    ],
    targets: [
        .target(name: "OpenSpellCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "OpenSpellUI", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "OpenSpellCoreTests", dependencies: ["OpenSpellCore", "OpenSpellUI"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
