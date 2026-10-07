#!/usr/bin/env bash
# Builds the iOS app and its keyboard for the Simulator.
#
#   ./scripts/build-ios.sh                         # Debug build for the "iPhone 17 Pro" simulator
#   SIMULATOR="iPhone 17" ./scripts/build-ios.sh   # pick another simulator
#   ./scripts/build-ios.sh --install               # also install and launch it on that simulator
#
# The Xcode project is generated from iOS/project.yml with XcodeGen (brew install xcodegen).
# Open iOS/OpenSpell.xcodeproj afterwards to run it on your iPhone.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-Debug}"
SIMULATOR="${SIMULATOR:-iPhone 17 Pro}"
DERIVED="$ROOT/.build/ios"
APP="$DERIVED/Build/Products/$CONFIG-iphonesimulator/OpenSpell.app"
ICON="$ROOT/iOS/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

command -v xcodegen >/dev/null || { echo "XcodeGen is missing: brew install xcodegen"; exit 1; }

if [ ! -f "$ICON" ]; then
    echo "› Rendering icon…"
    swift "$ROOT/scripts/make-icon.swift" "$ICON" >/dev/null
fi

echo "› Generating the Xcode project…"
xcodegen generate --spec "$ROOT/iOS/project.yml" --quiet

echo "› Compiling ($CONFIG, $SIMULATOR)…"
xcodebuild -project "$ROOT/iOS/OpenSpell.xcodeproj" -scheme OpenSpell -configuration "$CONFIG" \
    -destination "platform=iOS Simulator,name=$SIMULATOR" \
    -derivedDataPath "$DERIVED" \
    build > "$ROOT/build-ios.log" 2>&1 || { grep -E "error:" "$ROOT/build-ios.log" | sort -u; echo "Build failed — see build-ios.log"; exit 1; }
echo "✓ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
    open -b com.apple.iphonesimulator 2>/dev/null || true
    xcrun simctl install "$SIMULATOR" "$APP"
    xcrun simctl launch "$SIMULATOR" app.openspell.ios >/dev/null
    echo "✓ Installed and launched on $SIMULATOR"
fi
