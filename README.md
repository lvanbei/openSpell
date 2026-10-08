# OpenSpell

OpenSpell is a macOS menu bar app that fixes spelling, grammar and punctuation in any app. Select some text and press **⇧⌘Space**, or press firmly on the trackpad. The corrected text replaces your selection in place.

You can run corrections on your Mac with Apple Intelligence or [MLX](https://github.com/ml-explore/mlx-swift) models, or in the cloud with your own Google Gemini or OpenRouter API key.

[![OpenSpell demo: select text, then press ⇧⌘Space or press firmly on the trackpad, and the fix replaces the selection](docs/screenshots/OpenSpell_QuickDemo_Static.gif)](docs/screenshots/OpenSpell_QuickDemo_Static.mp4)

![The OpenSpell Setup Assistant welcome screen](docs/screenshots/setup.png)

## Install

1. Download **OpenSpell-&lt;version&gt;.dmg** from the [latest release](https://github.com/lvanbei/openSpell/releases/latest).
2. Open it and drag **OpenSpell** to **Applications**.
3. Open OpenSpell from Applications. Releases are signed with a Developer ID and notarized by Apple, so macOS opens them without a warning.

To update, open **Settings › About** and click **Check for Updates**. If GitHub has a newer release, **Download and Install** downloads it, checks its checksum and Developer ID signature, replaces the app and relaunches it.

OpenSpell needs macOS 15 or later on an Apple silicon Mac. To build it yourself, see [Build from source](#build-from-source).

## Features

- **Works in any app.** It fixes the selection in place and restores your clipboard afterwards.
- **Two triggers.** Use a global keyboard shortcut, or a force click with adjustable sensitivity. The force click fires before macOS's Look Up.
- **On-device models.** Use Apple Intelligence on macOS 26, or download MLX models from Hugging Face: pick a recommended one or search for others. Your text stays on your Mac.
- **Cloud models.** Use the Google Gemini API or any text model on OpenRouter, including free ones.
- **Minimal edits.** It fixes mistakes without rephrasing or translating, and leaves formatting, URLs, mentions and code alone.
- **Only corrections.** OpenSpell checks that the model returned your whole text, corrected. A reply, a translation, a summary or part of the text never replaces your selection.
- **Language hint.** Auto-detect the language, or choose one of 17 languages.
- **History.** Your last 1,000 corrections are kept in a local log that you can search.
- **Guided setup and self-test.** A setup assistant helps with permissions and models. The Test tab runs health checks and an end-to-end correction in TextEdit.
- **Menu bar only.** There's no Dock icon, and the app can launch at login.

## Requirements

- macOS 15 or later (Apple Intelligence needs macOS 26)
- An Apple silicon Mac (the build targets arm64, and on-device models need Apple silicon)
- Xcode with Swift 6.3 or later (mlx-swift requires it)

## Build from source

```sh
git clone https://github.com/lvanbei/openSpell.git
cd openSpell
./scripts/build.sh --install
```

[scripts/build.sh](scripts/build.sh) builds the Release configuration with `xcodebuild`, then assembles and signs `build/OpenSpell.app`. With `--install`, it also copies the app to `/Applications` and launches it. Compiler output goes to `build.log`. If Xcode's Metal toolchain is missing, the script installs it first.

| Option                                                            | Effect                                        |
| ----------------------------------------------------------------- | --------------------------------------------- |
| `--install`                                                       | Copy the app to `/Applications` and launch it |
| `CONFIG=Debug`                                                    | Build the Debug configuration                 |
| `CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)"` | Sign with a specific identity                 |
| `VERSION=1.2.0 BUILD_NUMBER=42`                                   | Set the version and build number              |

By default, the script signs with your Developer ID Application certificate, the identity releases use. macOS ties the Accessibility permission to the signing identity, so a local build and a release can then replace each other without losing it. Without a Developer ID, the script uses the first Apple Development certificate in your keychain, and otherwise signs ad-hoc. Use a stable identity if you can: with an ad-hoc signature, macOS forgets the Accessibility permission every time the binary changes.

To make a disk image, run `./scripts/package.sh` after building. It writes `build/OpenSpell-<version>.dmg` and a SHA-256 checksum next to it.

> [!NOTE]
> Build with the script or Xcode, not `swift build`. SwiftPM on the command line can't compile MLX's Metal shaders.

## Getting started

The first time you launch OpenSpell, the Setup Assistant walks you through four steps:

1. **Allow Accessibility.** Turn on OpenSpell in System Settings › Privacy & Security › Accessibility. OpenSpell needs this to read the selection, paste the fix and detect force clicks.
2. **Choose a language model.** Use Apple Intelligence, download the recommended on-device model, or paste a Gemini or OpenRouter API key.
3. **Learn your press.** Press firmly three times to calibrate force click sensitivity. If you don't have a Force Touch trackpad, skip this step.
4. **Try it.** Correct a sample sentence.

After setup, correcting text works like this:

1. Select text in any app.
2. Press **⇧⌘Space**, or press firmly on the trackpad.
3. A "Correcting…" bubble appears. When the model answers, the corrected text replaces your selection. If there's nothing to fix, the bubble says "No mistakes found".

Selections can be up to 12,000 characters long. If you switch to another app before the correction is ready, OpenSpell copies the fix to the clipboard instead of pasting it.

### Settings

To open Settings or History, click the menu bar icon.

| Tab      | What it does                                                                                                                               |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| General  | Set the language hint, launch at login, force click sensitivity, bubble position and history. Also shows whether Accessibility is allowed. |
| Shortcut | Record a different global shortcut                                                                                                         |
| Models   | Use Apple Intelligence, download or search for on-device models, add API keys, and browse and choose cloud models                          |
| Test     | Run a health check, test the triggers, run an end-to-end correction in TextEdit, or try the playground                                     |
| About    | See the version and check GitHub for updates                                                                                               |

## Models

![The Models tab in OpenSpell settings](docs/screenshots/settings-models.png)

### Apple Intelligence

On macOS 26 or later with Apple Intelligence turned on, OpenSpell can use Apple's on-device model. It's free, needs no download and keeps your text on your Mac. Whenever no model is selected, such as after a fresh install or after you remove the model in use, OpenSpell uses it automatically; otherwise click **Use** in the Models tab. The Models tab lists the languages it supports; for others, use another model. Its context window is small, so OpenSpell corrects long text a few paragraphs at a time.

### On-device (MLX)

On-device models are free, keep your text private, and work offline once they're downloaded. They need an Apple silicon Mac. These are the recommended models:

| Model                 | Hugging Face repo                           | Size   | Notes                                           |
| --------------------- | ------------------------------------------- | ------ | ----------------------------------------------- |
| Qwen3 4B Instruct     | `mlx-community/Qwen3-4B-Instruct-2507-4bit` | 2.3 GB | The best balance of speed and quality           |
| Qwen3.5 4B            | `mlx-community/Qwen3.5-4B-MLX-4bit`         | 3.1 GB | Newer, and accurate in many languages           |
| Gemma 3n E4B          | `mlx-community/gemma-3n-E4B-it-lm-4bit`     | 3.9 GB | Trained on more than 140 languages              |
| Gemma 4 E4B           | `mlx-community/gemma-4-e4b-it-4bit`         | 5.2 GB | The most accurate; works best with 16 GB of RAM |
| Llama 3.2 3B Instruct | `mlx-community/Llama-3.2-3B-Instruct-4bit`  | 1.8 GB | The smallest and fastest; best in English       |

To find others, click **Search Hugging Face…**. It lists the MLX models that OpenSpell can run, most downloaded first, with their download size, and warns about models that are large for your Mac's memory. You can also enter any Hugging Face repo that contains MLX weights (`*.safetensors`). Downloads use several parallel connections and resume where they left off. Each file is checked against its SHA-256 checksum.

The model stays in memory while you use it. After 30 secondes without a correction, OpenSpell frees that memory, so the next correction takes a few seconds longer.

### Google Gemini

Paste an API key from [Google AI Studio](https://aistudio.google.com), which offers a free tier. OpenSpell picks a fast, current Flash model for your key and keeps reasoning to a minimum. When Google retires a model, OpenSpell switches to its replacement automatically.

### OpenRouter

Paste an [OpenRouter](https://openrouter.ai) key. Then browse the catalogue, which shows prices, or enter a model slug. Models whose slugs end in `:free` cost nothing. If your key is on the free tier, OpenSpell switches to a free model automatically.

## Privacy

- On-device models never send your text anywhere.
- Cloud models send the selected text to Google or OpenRouter.
- API keys are stored in the macOS Keychain.
- History stays on your Mac. You can turn it off or clear it at any time.

| Data     | Location                                               |
| -------- | ------------------------------------------------------ |
| Settings | `UserDefaults` domain `app.openspell.OpenSpell`        |
| API keys | Keychain, service `app.openspell.OpenSpell`            |
| History  | `~/Library/Application Support/OpenSpell/history.json` |
| Models   | `~/Library/Application Support/OpenSpell/Models/`      |

## How it works

1. **Trigger.** The shortcut is registered as a Carbon global hotkey. For force clicks, a CGEvent tap reads the trackpad pressure. Once a correction starts, the tap swallows the rest of the press so the app underneath doesn't react.
2. **Read.** OpenSpell gets the selected text and its position on screen through the Accessibility API. If an app doesn't expose its text, OpenSpell sends ⌘C instead. Chromium and Electron apps are asked to turn on their accessibility tree.
3. **Correct.** The text goes to the selected model with a proofreading prompt ([CorrectionPrompt.swift](Packages/OpenSpellCore/Sources/OpenSpellCore/CorrectionPrompt.swift)). The temperature is 0, and reasoning is turned off or kept to a minimum. OpenSpell removes think blocks, code fences and wrapping quotes from the output, keeps your apostrophe style, then restores the original leading and trailing whitespace.
4. **Check.** OpenSpell lines up the words of the answer with your text ([CorrectionCheck.swift](Packages/OpenSpellCore/Sources/OpenSpellCore/CorrectionCheck.swift)). Spelling, accents, punctuation and capitalization can change freely, but only a few words can be added, removed or replaced, and the answer has to start and end like your text. A label or notes around the corrected text are cut off. Anything else, such as a reply, a translation, a summary or part of the text, is asked for again with a reminder. If the second answer isn't a correction either, nothing is changed and the bubble says so.
5. **Write back.** If the original selection was lost, OpenSpell selects it again. It then pastes the fix with ⌘V and restores the clipboard. The temporary clipboard entry is marked so that clipboard managers ignore it.

## Troubleshooting

Start with **Settings › Test**. It checks the Accessibility permission, the shortcut, the force click listener and the model.

- **Accessibility is revoked after every rebuild.** The app is signed ad-hoc. Sign it with a stable identity (see [Build from source](#build-from-source)). To remove the stale permission entry, run `tccutil reset Accessibility app.openspell.OpenSpell`, then allow OpenSpell again.
- **The shortcut does nothing.** Another app might already use it. Record a different shortcut in Settings › Shortcut.
- **Force click doesn't trigger.** Turn on "Force Click and haptic feedback" in System Settings › Trackpad. The force click listener also needs the Accessibility permission.
- **The bubble says "fix copied, press ⌘V".** You switched apps, or the text changed, before the correction finished. The fix is on the clipboard.
- **OpenRouter returns error 402 or 429.** Error 402 means the model needs credits, and 429 means it's rate-limited. Pick a model marked Free, or try a different model.

## iPhone

On iPhone, OpenSpell is a keyboard with a **Fix** button. In any app, switch to the OpenSpell keyboard with the globe key and tap **Fix**. It corrects the paragraph before the cursor, or only the selection if you selected text. **Undo** puts the original back. The keyboard also has space, delete and return keys; switch back to your usual keyboard to type. The OpenSpell app holds your settings, API keys and history, and has a playground to try a fix.

Corrections run on the iPhone with Apple Intelligence, or in the cloud with your own Google Gemini or OpenRouter key.

### Build and run

You need iOS 26 or later, Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
./scripts/build-ios.sh --install
```

[scripts/build-ios.sh](scripts/build-ios.sh) generates `iOS/OpenSpell.xcodeproj` from [iOS/project.yml](iOS/project.yml) and builds the app and its keyboard for the iPhone 17 Pro simulator. With `--install`, it also installs and launches the app there. Set `SIMULATOR="iPhone 17"` to use another simulator. Compiler output goes to `build-ios.log`.

To run it on your iPhone, open `iOS/OpenSpell.xcodeproj` in Xcode, select your iPhone and click Run. To sign with another team, change `DEVELOPMENT_TEAM` in `iOS/project.yml`. If the bundle IDs or the App Group `group.app.openspell` aren't available to your team, change them in `project.yml`, both `.entitlements` files and [SharedStorage.swift](Packages/OpenSpellCore/Sources/OpenSpellCore/SharedStorage.swift).

Debug builds have a **Fake corrections** switch in Settings › Debug. It fixes a few common typos without a model, for testing in the Simulator.

### Set up the keyboard

1. Open OpenSpell and follow the setup.
2. In Settings, go to General › Keyboard › Keyboards › Add New Keyboard and choose **OpenSpell**.
3. Tap **OpenSpell** in the list of keyboards and turn on **Allow Full Access**.
4. In the app's **Models** tab, choose **Apple Intelligence** or add a Gemini or OpenRouter key.

### Apple Intelligence

On an iPhone 15 Pro or later with Apple Intelligence turned on, OpenSpell can use Apple's on-device model. It's free, works offline and keeps your text on the iPhone. A fresh install picks it automatically when Apple Intelligence is on. The Models tab lists the languages it supports; for others, use a cloud model.

The model runs in a system process, so it doesn't count against the keyboard's memory limit. Its context window is small (4,096 tokens on iOS 26), so OpenSpell corrects long text a few paragraphs at a time.

### Full Access and privacy

The keyboard needs Full Access to reach the network and to read the API key and settings it shares with the app. Without it, the keys still work but **Fix** doesn't.

- The keyboard reads text only when you tap **Fix**. With Apple Intelligence, the text stays on your iPhone. With a cloud model, the paragraph before the cursor, or the selection, goes to Google or OpenRouter. The keyboard never records keystrokes.
- **Fix** is turned off in password, one-time code and credit card fields.
- API keys are stored in the iOS Keychain, shared by the app and the keyboard.
- Settings and history stay in the App Group container on your iPhone. You can turn history off or clear it in the app.

### How the keyboard edits text

iOS keyboards see only some of the text around the cursor and can only delete backwards and type. Before reading, OpenSpell moves the cursor by one character and back, so the app reports its current text. After the model answers, it deletes and retypes only the part that changed. If the text changed while the model was working, OpenSpell leaves it alone and copies the fix to the clipboard.

The logic shared by the Mac and iPhone apps lives in [Packages/OpenSpellCore](Packages/OpenSpellCore). The `OpenSpellCore` library only uses Foundation and FoundationModels, so the keyboard stays within its small memory limit. Run its tests with `swift test --package-path Packages/OpenSpellCore`.

## Releases

Releases are built on your Mac and published with the [GitHub CLI](https://cli.github.com). Sign in once with `gh auth login`, and enable the repository's git hooks once per clone:

```sh
git config core.hooksPath .githooks
```

From then on, every commit on `main` is published as the next patch release (1.0.1, 1.0.2, …). The [post-commit hook](.githooks/post-commit) runs [scripts/release.sh](scripts/release.sh), so the commit waits while the app builds, `main` is pushed and the release is uploaded. To commit without releasing, put `[skip release]` in the commit message. Commits made during a rebase, merge or cherry-pick aren't released.

To release a specific version, such as a minor update or a beta, commit and run the script yourself:

```sh
./scripts/release.sh 1.1.0
```

The script only releases from `main` with no uncommitted changes. It builds and packages `OpenSpell-1.1.0.dmg`, pushes `main`, then creates the `v1.1.0` tag and a release with the disk image, its checksum and install notes. A version with a suffix, such as `1.1.0-beta.1`, becomes a pre-release.

### Signing and notarization

Every release is signed with a Developer ID and notarized by Apple, so it opens without a Gatekeeper warning and keeps its Accessibility permission across updates. `release.sh` refuses to publish without both, and checks the result with Gatekeeper before it pushes anything. Set this up once per Mac (it needs a paid Apple Developer account):

1. **Developer ID certificate.** In Xcode, open Settings › Accounts, select your team and click **Manage Certificates**. Click **+** and choose **Developer ID Application**. Only the team's Account Holder can create it.
2. **Notarization credentials.** Create an app-specific password at [account.apple.com](https://account.apple.com) (Sign-In and Security › App-Specific Passwords), then save it in your keychain:

   ```sh
   xcrun notarytool store-credentials openspell --apple-id you@example.com --team-id TEAMID
   ```

`release.sh` finds the certificate on its own and uses the `openspell` profile. To use others, set `CODESIGN_IDENTITY` and `NOTARY_PROFILE`.

## Developer CLI

The app binary has a few hidden flags for smoke tests:

```sh
APP=build/OpenSpell.app/Contents/MacOS/OpenSpell

# Download an MLX model
$APP --download mlx-community/Qwen3-4B-Instruct-2507-4bit

# Correct a string with a downloaded model, an OpenRouter slug, a Gemini model or Apple Intelligence
$APP --correct mlx-community/Qwen3-4B-Instruct-2507-4bit "I beleive its definately ready."
$APP --correct openrouter:google/gemini-2.5-flash "I beleive its definately ready."
GEMINI_API_KEY=your-key $APP --correct gemini:gemini-flash-latest "I beleive its definately ready."
$APP --correct apple "I beleive its definately ready."

# Run the health checks and the TextEdit end-to-end test (the local model is optional)
$APP --e2e mlx-community/Qwen3-4B-Instruct-2507-4bit

# Save every window as a PNG file
$APP --snapshot /tmp/openspell-snapshots
```

`openrouter:` uses the API key saved in the Keychain. `gemini:` uses `GEMINI_API_KEY` if it's set, and the saved key if it isn't. `--correct` checks the answer like a real correction does: it asks again after an answer that isn't the corrected text, and fails if the second one isn't either.

## Project structure

| Path                                                 | Contents                                                                                                         |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| [Sources/OpenSpell/App](Sources/OpenSpell/App)       | Entry point, menu bar item and developer CLI                                                                     |
| [Sources/OpenSpell/Core](Sources/OpenSpell/Core)     | Correction pipeline, text access, shortcut and force click triggers, settings, history, Keychain and diagnostics |
| [Sources/OpenSpell/Models](Sources/OpenSpell/Models) | Prompt, MLX runtime, Hugging Face downloader, Gemini and OpenRouter clients, and the model store                 |
| [Sources/OpenSpell/UI](Sources/OpenSpell/UI)         | SwiftUI views for settings, history and the setup assistant                                                      |
| [Resources/Info.plist](Resources/Info.plist)         | App bundle metadata                                                                                              |
| [scripts/build.sh](scripts/build.sh)                 | Script that builds, signs and installs the app                                                                   |
| [scripts/package.sh](scripts/package.sh)             | Script that packages the app into a disk image and can sign and notarize it                                      |
| [scripts/release.sh](scripts/release.sh)             | Script that builds the app on your Mac and publishes it as a GitHub release                                      |
| [.githooks/post-commit](.githooks/post-commit)       | Git hook that publishes every commit on `main` as the next patch release                                         |
| [scripts/make-icon.swift](scripts/make-icon.swift)   | Script that renders the app icon                                                                                 |
