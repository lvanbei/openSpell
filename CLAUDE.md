# OpenSpell

macOS menu bar app (plus an iOS keyboard) that fixes spelling, grammar and punctuation of the selected text in any app, in place, with an LLM: Apple Intelligence, MLX models on device, or Gemini / OpenRouter with the user's key. Swift 6 toolchain, Swift 5 language mode, SwiftUI + AppKit, no Xcode project for macOS (SwiftPM), XcodeGen for iOS.

## Layout

| Path | What |
| --- | --- |
| `Packages/OpenSpellCore/Sources/OpenSpellCore` | Platform-neutral logic shared by macOS, the iOS app and the keyboard. **Foundation + FoundationModels only**: no AppKit, UIKit or SwiftUI (the keyboard's memory limit). Use raw keys such as `NSAttributedString.Key("NSLink")` instead of AppKit/UIKit constants. |
| `Packages/OpenSpellCore/Sources/OpenSpellUI` | SwiftUI helpers shared by both apps (`WordDiff`). |
| `Packages/OpenSpellCore/Tests` | Swift Testing (`import Testing`, `@Test`, `#expect`). All logic tests live here. |
| `Sources/OpenSpell` | macOS app: `App` (entry point, menu bar, hidden CLI flags in `main.swift`), `Core` (pipeline, Accessibility, triggers, settings), `Models` (MLX, Hugging Face downloads), `UI`. |
| `iOS/` | iOS app and keyboard extension (`project.yml` → XcodeGen). |
| `scripts/` | `build.sh`, `build-ios.sh`, `package.sh`, `release.sh`. |

## Correction pipeline

1. **Trigger** — `HotKey` (Carbon hotkey) or `ForceTouchMonitor` (CGEvent tap) → `CorrectionEngine.trigger`.
2. **Read** — `TextAccess.captureSelection`: Accessibility (`kAXSelectedTextAttribute`), else synthesized ⌘C. iOS: `TextFixer.capture` through `UITextDocumentProxy`.
3. **Correct** — `CorrectionService.correct` → `ask`: prompt (`CorrectionPrompt.system/user`), model call, `CorrectionPrompt.clean`, `CorrectionCheck.correction` (rejects replies, translations, summaries; one retry with `CorrectionPrompt.retry`), `LayoutGuard.restore` (puts back whitespace between kept words, list/Markdown markers, URLs, emails, paths, numbers, mentions, code), `CorrectionPrompt.surrounded`. Apple Intelligence chunks long text with `TextChunker` and calls `ask` per chunk.
4. **Write back** — macOS `TextAccess.writeBack`: restores the AX selection, pastes the fix as **plain text** with ⌘V, restores the clipboard. Own windows replace the `NSTextView` range directly. iOS: `TextFixer.apply` + `ReplacementPlanner` (fewest deletes/inserts, plain text only).

Invariants to keep:
- A model answer only replaces the user's text if `CorrectionCheck` accepts it. Never weaken that to "make a test pass".
- Layout is never the model's job alone: whatever the prompt says, `LayoutGuard` must keep line breaks, tabs, list and Markdown markers, URLs and code.
- Write-back is plain text on purpose. Patching the app's rich copy (RTF/HTML) to keep bold and links was tried and removed: in Microsoft Teams it broke links (Teams splits a link into several `<a>` on copy and handles pasted HTML its own way). Don't reintroduce it without testing in Teams, Outlook and a browser.
- Prompt changes affect every backend, including Apple Intelligence's small context window (`inputBudget` in `AppleIntelligence.swift`). Keep the prompt short and test with `--correct`.

## Build and test

```sh
swift test --package-path Packages/OpenSpellCore     # core logic, fast; run after any core change
./scripts/build.sh                                   # macOS Release build into build/OpenSpell.app (log: build.log)
./scripts/build.sh --install                         # also copies to /Applications and launches
./scripts/build-ios.sh                               # iOS app + keyboard for the simulator
```

- Don't use `swift build` for the macOS app: SwiftPM on the command line can't compile MLX's Metal shaders. To only compile: `xcodebuild -scheme OpenSpell -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -skipMacroValidation -skipPackagePluginValidation build`.
- Check the core still builds for iOS after core changes: `cd Packages/OpenSpellCore && xcodebuild -scheme OpenSpellCore -destination 'generic/platform=iOS Simulator' build`.
- Smoke-test a real model: `build/OpenSpell.app/Contents/MacOS/OpenSpell --correct apple "I beleive its definately ready."` (see README › Developer CLI).
- Accessibility, paste and force click can't be tested headless; say so instead of claiming they work.

## Releases — careful

`.githooks/post-commit` publishes **every commit on `main`** as a signed, notarized GitHub release (`scripts/release.sh`) when `core.hooksPath` is `.githooks`. Don't commit unless asked; work on a branch, or put `[skip release]` in the message for commits on `main` that shouldn't ship.

## Code style

- Match the surrounding code: small `enum` namespaces with static functions, `struct`s for values, `@MainActor` for UI and pipeline state, async/await (no Combine, no completion handlers).
- Doc comments (`///`) say what something is or why it exists, in plain sentences; inline comments only for the non-obvious why.
- Naming reads as English: `correction(in:of:)`, `restore(_:from:)`, `isProtected`.
- No new dependencies. OpenSpellCore must stay Foundation-only.
- Errors: user-facing ones are `LocalizedError` with a short actionable message (no trailing period); log diagnostics with `NSLog("OpenSpell: …")` or `Logger`.
- Never hard-code secrets: API keys live in the Keychain (`Keychain.swift`); tests use fakes (`FakeModel`, `FakeDocument`).
- Every behaviour change in OpenSpellCore comes with Swift Testing tests in `Packages/OpenSpellCore/Tests`.
- Keep `README.md` in sync when user-visible behaviour, settings or the pipeline change.
