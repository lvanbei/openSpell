#!/usr/bin/env bash
# Builds OpenSpell on this Mac, pushes main and publishes it as a GitHub release.
# The .githooks/post-commit hook runs this for every commit on main.
#
#   ./scripts/release.sh 1.2.0          # release v1.2.0 with OpenSpell-1.2.0.dmg and its checksum
#   ./scripts/release.sh 1.3.0-beta.1   # a version with a suffix becomes a pre-release
#
# Needs the GitHub CLI (`gh auth login`), a Developer ID Application certificate and the "openspell"
# notarytool profile (see README › Signing and notarization). CODESIGN_IDENTITY and NOTARY_PROFILE override them.
set -euo pipefail

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
    echo "Usage: $0 <version>   (for example: $0 1.2.0)"
    exit 1
fi
TAG="v$VERSION"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Only release committed code from main, under a new tag.
if [ "$(git branch --show-current)" != main ]; then
    echo "Releases are made from main."
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "Not releasing: commit or stash your other changes first."
    exit 1
fi
git fetch --quiet --tags origin
if ! git merge-base --is-ancestor origin/main HEAD; then
    echo "Not releasing: origin/main has commits you don't have. Pull first."
    exit 1
fi
if git rev-parse --quiet --verify "refs/tags/$TAG" > /dev/null; then
    echo "$TAG already exists."
    exit 1
fi

# Without a Developer ID signature and notarization, Gatekeeper blocks the download.
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application/ && !found { print $2; found = 1 }')"
fi
if [[ "$CODESIGN_IDENTITY" != "Developer ID Application"* ]]; then
    echo "Not releasing: no Developer ID Application certificate in your keychain (see README › Signing and notarization)."
    exit 1
fi
export CODESIGN_IDENTITY
export NOTARY_PROFILE="${NOTARY_PROFILE:-openspell}"
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1; then
    echo "Not releasing: the notarytool profile \"$NOTARY_PROFILE\" is missing or invalid (see README › Signing and notarization)."
    exit 1
fi

VERSION="$VERSION" BUILD_NUMBER="$(git rev-list --count HEAD)" ./scripts/build.sh
./scripts/package.sh
DMG="build/OpenSpell-$VERSION.dmg"

echo "› Checking Gatekeeper…"
spctl --assess --type open --context context:primary-signature -v "$DMG"
spctl --assess --type execute -v build/OpenSpell.app

NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
{
    echo "## Install"
    echo
    echo "1. Download **OpenSpell-$VERSION.dmg** below and open it."
    echo "2. Drag **OpenSpell** to **Applications**, then open it from there."
    echo
    echo "Signed with a Developer ID and notarized by Apple. Requires macOS 15 or later on an Apple silicon Mac. To verify the download, run \`shasum -a 256 -c OpenSpell-$VERSION.dmg.sha256\`."
} > "$NOTES"

PRERELEASE=false
if [[ "$VERSION" == *-* ]]; then PRERELEASE=true; fi
git push --quiet origin main
# gh creates the tag on GitHub, at this commit, together with the release.
gh release create "$TAG" "$DMG" "$DMG.sha256" --target "$(git rev-parse HEAD)" \
    --title "OpenSpell $VERSION" --notes-file "$NOTES" --generate-notes --prerelease="$PRERELEASE"
git fetch --quiet --tags origin
echo "✓ Published $TAG"
