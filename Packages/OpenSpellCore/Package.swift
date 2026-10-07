// swift-tools-version: 6.2
import PackageDescription

// Platform-neutral OpenSpell logic shared by the macOS app, the iOS app and the iOS keyboard.
let package = Package(
    name: "OpenSpellCore",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [
        .library(name: "OpenSpellCore", targets: ["OpenSpellCore"])
    ],
    targets: [
        .target(name: "OpenSpellCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "OpenSpellCoreTests", dependencies: ["OpenSpellCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
