# Port OpenSpell to iOS: a companion app plus an "OpenSpell" keyboard with a Fix button

## Context

OpenSpell (this repo) is a macOS menu bar app written in Swift with SwiftPM, for macOS 15 and later. You select text, press ⇧⌘Space, and the corrected text replaces the selection. scripts/build.sh builds it by running xcodebuild on Package.swift (`swift build` can't compile MLX's Metal shaders). Read these files before planning:

- README.md: features, privacy, how it works.
- Sources/OpenSpell/Core/CorrectionEngine.swift: the pipeline (capture → 12,000-char limit → `ModelStore.complete` → `CorrectionPrompt.postProcess` → write back → history).
- Sources/OpenSpell/Models/: CorrectionPrompt, GeminiClient, OpenRouterClient, ModelStore, LocalLLM (MLX), HFDownloader.
- Sources/OpenSpell/Core/: AppSettings (`CorrectionLanguage`), Keychain, History.
- Sources/OpenSpell/UI/: HistoryView (`WordDiff`), SetupAssistantView, ModelsSettingsView, TestSettingsView.

## Goal

Bring OpenSpell to iPhone as a native app plus a custom keyboard extension. The keyboard's toolbar has a **Fix** button. In any app, it proofreads the selected text (or, with no selection, the text before the cursor) and replaces it in place. It uses the same prompt, post-processing and cloud providers as the Mac app. The companion app handles setup, API keys, model choice, the language hint, history and a playground. Keep one codebase: shared logic goes in a module that both the Mac app and the iOS app use.

## iOS constraints (design around them)

1. Apps can't add buttons to Apple's keyboard. The only system-wide option is a custom keyboard extension (`UIInputViewController`) that the user switches to with the globe key.
2. Without Full Access, a keyboard has no network access and no shared container with its app. Full Access requires `RequestsOpenAccess` = YES; check it with `hasFullAccess`. Fix needs Full Access. Typing must still work without it, and the toolbar should explain how to turn it on.
3. Keyboard extensions get only a few tens of MB of memory before iOS kills them (jetsam). Never link or load MLX, swift-transformers or model weights in the extension.
4. The keyboard can only reach text through `textDocumentProxy`:
   - `selectedText`.
   - `documentContextBeforeInput`/`AfterInput`: often cut off at the current paragraph, and can be empty in web views.
   - `insertText`, `deleteBackward`, `adjustTextPosition`, `documentIdentifier`.
     Proxy state updates asynchronously after each edit, so wait for `textDidChange`.
5. iOS switches to Apple's keyboard in secure fields and phone pads. Apps can also block custom keyboards.
6. Keyboards can't open URLs or their containing app. Show instructions instead.
7. App Review guideline 4.4.1: a keyboard must offer real typing and a next-keyboard key, and must work without Full Access. Personal use comes first, but don't rule out the App Store.
8. In the extension, `Bundle.main` is the extension's own bundle. Never derive shared identifiers (Keychain service, defaults suite) from it.

## Architecture

- Package.swift: add `.iOS(.v26)` and a library product named **OpenSpellCore**.
  - Core uses Foundation, plus SwiftUI only where needed. No AppKit, UIKit, MLX or Tokenizers.
  - Move or extract into Core: `CorrectionPrompt`, `CorrectionLanguage`, `GeminiClient`, `OpenRouterClient`, `Keychain`, `HistoryItem` and history storage, `ModelEntry` and the model-selection logic of `ModelStore` (Gemini retired-model healing, OpenRouter free-tier handling), and `WordDiff`.
  - Add a `CorrectionService` to Core for the platform-neutral half of `CorrectionEngine.run`: length limit, prompt, `complete`, `postProcess`, and the "no mistakes" check.
- Put MLX and Hugging Face downloads behind a protocol that only the macOS app implements. The macOS target keeps its AppKit parts (AX text access, hotkey, force click, bubble, windows) and calls into Core.
- The macOS app must behave exactly as before. Keep:
  - the same UserDefaults domain and keys (`language`, `keepHistory`, `models.entries`, `models.selected`, `openrouter.freeTier`, …);
  - the same Keychain service and accounts (`gemini-api-key`, `openrouter-api-key`);
  - the same history path.
    Make storage injectable: `UserDefaults.standard` on macOS, the App Group suite on iOS.
- iOS project: generate it with XcodeGen from iOS/project.yml (ask me before installing XcodeGen). It defines an app and a keyboard extension, both depending on the local package's `OpenSpellCore`.
  - Gitignore the generated .xcodeproj.
  - Never put an .xcodeproj or .xcworkspace in the repo root: scripts/build.sh runs xcodebuild there.
  - Add scripts/build-ios.sh: it generates the project and builds for a Simulator, with derived data in .build/ios.
- Identifiers: app `app.openspell.ios`, keyboard `app.openspell.ios.keyboard`, App Group `group.app.openspell`.
  - On iOS, the Keychain uses a fixed service, with the App Group as `kSecAttrAccessGroup`.
  - Team 4QSC7566DR, automatic signing, iOS 26.0, Swift 5 language mode like the package.
  - Keep signing on for Simulator builds so the entitlements apply.
  - Add a PrivacyInfo.xcprivacy to both targets (App Group UserDefaults → reason 1C8F.1).
- Backends on iOS: Gemini and OpenRouter through the existing clients, plus a new `.apple` model kind built on FoundationModels (`SystemLanguageModel`, a fresh `LanguageModelSession` per request, greedy sampling). For `.apple`:
  - Check `availability` and the supported languages.
  - The context window is small (4,096 tokens on iOS 26), so split long text by paragraph.
  - Map guardrail and context-size errors to clear messages.
  - Check that it actually works inside the keyboard extension. If it doesn't, offer it only in the app and the App Intent.
  - Hide `.apple` on macOS for now.
- Don't use `ModelStore.isAppleSilicon` on iOS: it reads `uname().machine`, which is a device model ID there, not an architecture.

## Keyboard extension (UIKit, for low memory and instant touch handling)

- Layout:
  - A toolbar above the keys: Fix, Undo, a status line, and a small model/language label.
  - Show the globe key only when `needsInputModeSwitchKey` is true, and wire it to `handleInputModeList(from:with:)`.
  - Follow `keyboardAppearance` and dark mode, and take the return key's label from `returnKeyType`.
  - Support landscape and VoiceOver labels.
- Startup:
  - Reload shared settings in `viewWillAppear`: the extension process can outlive changes made in the app.
  - Don't run `ModelStore.bootstrap`'s side effects (OpenRouter tier refresh, model preload) in the extension.
  - Write a heartbeat (`keyboard.lastSeen`, `keyboard.hasFullAccess`) to the App Group so the app can show setup status.
- Fix flow (mirror `CorrectionEngine` and its messages):
  1. Target: `selectedText` if it's not empty, otherwise `documentContextBeforeInput`.
     - No text → "Select or type some text first".
     - Over 12,000 characters → error.
     - Disable Fix for password, one-time code and credit card `textContentType`s.
  2. Show "Correcting…" and turn Fix into Cancel. Cancel the request in `viewWillDisappear`.
  3. Run `CorrectionService`.
     - Unchanged result → "No mistakes found".
     - Errors go to the status line. Reword hints that point to macOS UI, such as "Settings › Models".
  4. Before writing back, check two things: `documentIdentifier` hasn't changed, and the selection or context still ends with the captured text. If either check fails, leave the document alone, put the fix on the pasteboard, and show "Text changed — fix copied".
  5. Replace the text:
     - Selection: `insertText(corrected)`.
     - Text before the cursor: by default, `deleteBackward()` back to the first changed character, then `insertText` the corrected tail. This doesn't move the caret, which makes it the most reliable option.
     - If the unchanged tail is long, use `adjustTextPosition` to step back over it instead. Its offsets act like UTF-16 units in UIKit hosts, so verify that. Confirm the caret landed where expected, edit only the changed span, then move the caret back.
     - Never delete more than was captured.
  6. After `textDidChange`, verify that the context ends with the corrected text. Save a history entry (appName "Keyboard") if history is on, then show "Corrected".
  7. Undo reverts the last fix, but only while the context still ends with it.
- Testing: keep the replacement planner in Core as a pure function (original + corrected → deletes + caret moves + insert) and unit-test it. Put a small protocol over the proxy so that a fake proxy can simulate truncated context, async updates, emoji, ZWJ sequences, accents, CJK and newlines.
- Privacy: text leaves the device only when the user taps Fix, and only goes to the chosen provider. Never log or store typed text, except in history when the user has it turned on. The app and the keyboard both write history, so coordinate writes with NSFileCoordinator and reload before changing it.

## Companion app (SwiftUI; reuse the copy and look of the macOS views, not their AppKit code)

- Onboarding:
  1. Welcome.
  2. Add the keyboard and allow Full Access. Explain exactly what's sent and when, add a button that opens `UIApplication.openSettingsURLString`, and show live status from the heartbeat.
  3. Choose a model: Apple on-device, or a Gemini or OpenRouter key. On a fresh install, default to Apple when it's available.
  4. Try it: a text field to try the keyboard in.
- Screens:
  - Language hint.
  - Models: enter and test keys, Gemini model list, OpenRouter catalogue with a Free filter.
  - History: search, word diff, delete, clear, on/off.
  - Status: keyboard seen, Full Access, model ready, test correction.
  - About.
- Playground: a text editor with a Fix button that calls `CorrectionService` directly.
- An App Intent "Fix Spelling" (text in, corrected text out) plus an `AppShortcutsProvider`. That way it also works with Apple's keyboard through Shortcuts, the share sheet, the Action Button and Back Tap.
- App icon: adapt scripts/make-icon.swift to render a 1024×1024 PNG that is opaque and full-bleed, with no rounded corners or shadow.

## Phases (after each phase: build, run tests, commit on the branch, give a short report)

0. Plan. Read the files above, then post a short plan and any questions before you edit anything.
1. Extract Core. Add OpenSpellCore and OpenSpellCoreTests, with tests for `postProcess`, `WordDiff`, Gemini `normalize`/`recommended(from:)`/`suggestedReplacement`, OpenRouter `recommendedFree`, and the replacement planner.
   - Done when `swift test` passes, `./scripts/build.sh` (without `--install`) succeeds, and the macOS app behaves exactly as before.
2. iOS MVP. The XcodeGen project and the app (onboarding, keys, model, language, history, playground). The keyboard has the toolbar plus one compact row: globe, space, delete with repeat, return.
   - Done when, in the Simulator, "I beleive its definately ready." becomes "I believe it's definitely ready." with Fix. Check this in Reminders, in Messages, in a Safari text field and in the app's Try-it field.
   - Also verify: Undo, fixing a selection, "No mistakes found", the missing-key message, the no-Full-Access message, and typing without Full Access.
   - Log `os_proc_available_memory()` and report the keyboard's peak memory.
   - **Stop here so I can test on my iPhone.**
3. The Apple on-device backend and the App Intent.
4. A full typing keyboard (required for the App Store): QWERTY, shift and caps lock, auto-capitalization from the proxy traits, 123 and #+= layers, key popups, delete repeat.

Out of scope: MLX on iOS (maybe later in the app only, never in the keyboard), Mac↔iPhone sync, swipe typing and predictions, iPad-specific layouts, App Store submission.

## Repo rules

- Run `git status` first. Don't stash or discard my changes. Create the branch `ios-app` and work there.
- Every commit on `main` automatically publishes a macOS release (.githooks/post-commit). So: never commit to `main`, never merge, never push, never run scripts/release.sh. Put "[skip release]" in every commit message anyway. Never use sudo or `build.sh --install`.
- Ask me before installing tools (XcodeGen, iOS platforms or Simulator runtimes), changing identifiers, or deleting files.
- Edit one shell script per change, then run `bash -n scripts/*.sh`. A format-on-save extension has corrupted scripts here before.
- Match the existing style: concise Swift, with a one-line comment only where the code can't explain itself.
- Add an iOS section to README.md covering setup, what Full Access means for privacy, and how to build. Add no other docs.
- For end-to-end checks in the Simulator, use the MobAI / controlling-mobile-devices skill if it's available. If the software keyboard doesn't appear because a hardware keyboard is connected, press ⌘K.
