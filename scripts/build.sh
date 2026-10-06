#!/usr/bin/env bash
# Builds OpenSpell.app into ./build
#
#   ./scripts/build.sh                 # Release build, ad-hoc signed
#   CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./scripts/build.sh
#   ./scripts/build.sh --install       # also copy to /Applications and launch
#
# A stable signing identity is strongly recommended: with ad-hoc signing macOS
# forgets the Accessibility permission every time the binary changes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-Release}"
DERIVED="$ROOT/.build/xcode"
PRODUCTS="$DERIVED/Build/Products/$CONFIG"
APP="$ROOT/build/OpenSpell.app"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  IDENTITY="$CODESIGN_IDENTITY"
else
  # Prefer a local Apple Development certificate (by hash, names can be ambiguous); else ad-hoc.
  IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null | awk '/Apple Development/ {print $2; exit}')"
  IDENTITY="${IDENTITY:--}"
fi

if ! xcrun -f metal >/dev/null 2>&1 || ! xcrun metal -v >/dev/null 2>&1; then
  echo "› Installing the Metal toolchain (needed to compile MLX kernels)…"
  xcodebuild -downloadComponent MetalToolchain
fi

echo "› Compiling ($CONFIG)…"
xcodebuild -scheme OpenSpell -configuration "$CONFIG" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  -skipMacroValidation -skipPackagePluginValidation \
  build > "$ROOT/build.log" 2>&1 || { grep -E "error:" "$ROOT/build.log" | sort -u; echo "Build failed — see build.log"; exit 1; }

echo "› Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/OpenSpell" "$APP/Contents/MacOS/OpenSpell"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# SwiftPM resource bundles (MLX's default.metallib lives in mlx-swift_Cmlx.bundle).
for b in "$PRODUCTS"/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done

if [ ! -f "$ROOT/build/AppIcon.icns" ]; then
  echo "› Rendering icon…"
  rm -rf "$ROOT/build/AppIcon.iconset"
  swift "$ROOT/scripts/make-icon.swift" "$ROOT/build/AppIcon.iconset" >/dev/null
  iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$ROOT/build/AppIcon.icns"
fi
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "› Signing ($IDENTITY)…"
codesign --force --deep --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "✓ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x OpenSpell 2>/dev/null || true
  rm -rf /Applications/OpenSpell.app
  cp -R "$APP" /Applications/
  open /Applications/OpenSpell.app
  echo "✓ Installed to /Applications and launched"
fi
