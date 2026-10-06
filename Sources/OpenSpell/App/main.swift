import AppKit

// Hidden developer CLI (used for smoke tests):
//   OpenSpell --download <hf-repo>
//   OpenSpell --correct <hf-repo | openrouter:slug> "text with tpyos"
let args = CommandLine.arguments
if args.count >= 3, ["--download", "--correct"].contains(args[1]) {
    Task.detached {
        do {
            switch args[1] {
            case "--download":
                let repo = args[2]
                let dir = ModelStore.directory(for: repo)
                var last = -1
                try await HFDownloader().download(repo: repo, to: dir) { p in
                    let pct = Int(p * 100)
                    if pct != last { last = pct; FileHandle.standardError.write("\rdownloading \(pct)%".data(using: .utf8)!) }
                }
                FileManager.default.createFile(atPath: dir.appending(path: ".complete").path, contents: Data())
                print("\nsaved to \(dir.path)")
            default:
                let target = args[2], text = args.count > 3 ? args[3] : "I beleive we can definately ship the new featur by tommorow."
                let system = CorrectionPrompt.system(language: .auto)
                let start = Date()
                let raw: String
                if target.hasPrefix("openrouter:") {
                    raw = try await OpenRouterClient.complete(model: String(target.dropFirst(11)), system: system, user: text)
                } else if target.hasPrefix("gemini:") {
                    raw = try await GeminiClient.complete(model: String(target.dropFirst(7)), system: system, user: text,
                                                          apiKey: ProcessInfo.processInfo.environment["GEMINI_API_KEY"])
                } else {
                    raw = try await LocalLLM.shared.complete(
                        directory: ModelStore.directory(for: target),
                        extraEOSTokens: ModelStore.extraEOSTokens(for: target), system: system, user: text)
                }
                print(CorrectionPrompt.postProcess(raw, original: text))
                FileHandle.standardError.write(String(format: "(%.2fs)\n", Date().timeIntervalSince(start)).data(using: .utf8)!)
            }
        } catch {
            FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
        exit(0)
    }
    dispatchMain() // keep the main queue alive for any main-actor work
}

// Menu bar ("agent") application: no Dock icon, no main window.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
