import AppKit
import Combine
import CryptoKit
import Security

enum UpdateError: LocalizedError {
    case noRelease
    case http(Int)
    case notAnApp
    case noDiskImage
    case checksumMismatch
    case mountFailed
    case untrusted

    var errorDescription: String? {
        switch self {
        case .noRelease: "No release has been published on GitHub yet."
        case .http(let code): "GitHub answered with HTTP \(code)."
        case .notAnApp: "OpenSpell isn't running from an app bundle."
        case .noDiskImage: "The release has no disk image."
        case .checksumMismatch: "The download was corrupted (checksum mismatch)."
        case .mountFailed: "The disk image couldn't be opened."
        case .untrusted: "The download isn't signed by the OpenSpell developer."
        }
    }
}

/// Looks for a newer GitHub release and installs it over the running app.
@MainActor
final class Updater: ObservableObject {
    enum Status: Equatable {
        case idle, checking, upToDate, available, downloading(Double), installing
        case failed(String)
    }

    struct Release: Decodable, Equatable {
        struct Asset: Decodable, Equatable {
            let name: String
            let url: URL
            /// "sha256:<hex>", computed by GitHub on upload.
            let digest: String?

            enum CodingKeys: String, CodingKey { case name, url = "browser_download_url", digest }
        }

        let tag: String
        let page: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey { case tag = "tag_name", page = "html_url", assets }

        var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
    }

    static let shared = Updater()
    nonisolated static let repo = "lvanbei/openSpell"
    /// Team of the Developer ID that signs releases (scripts/release.sh).
    nonisolated static let teamID = "4QSC7566DR"

    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    @Published private(set) var status = Status.idle
    /// The newer release found by the last check.
    @Published private(set) var update: Release?

    private var isBusy: Bool {
        switch status {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    func check() {
        guard !isBusy else { return }
        status = .checking
        Task {
            do {
                let latest = try await Self.fetchLatest()
                update = Self.isVersion(latest.version, newerThan: Self.currentVersion) ? latest : nil
                status = update == nil ? .upToDate : .available
            } catch {
                status = .failed("Couldn't check for updates. \(error.localizedDescription)")
            }
        }
    }

    /// Downloads the update, swaps it in for the running app and relaunches.
    func install() {
        guard let update, !isBusy else { return }
        status = .downloading(0)
        Task {
            do {
                try await installUpdate(update, replacing: Bundle.main.bundleURL)
                try Self.relaunch(Bundle.main.bundleURL)
            } catch {
                status = .failed("Couldn't install the update. \(error.localizedDescription)")
            }
        }
    }

    private func installUpdate(_ release: Release, replacing app: URL) async throws {
        guard app.pathExtension == "app" else { throw UpdateError.notAnApp }
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else { throw UpdateError.noDiskImage }
        let fm = FileManager.default
        // On the app's volume, so the final swap is an atomic rename.
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? fm.removeItem(at: work) }

        let image = work.appending(path: "update.dmg")
        try await Self.download(asset.url, to: image) { fraction in
            Task { @MainActor in
                if case .downloading = Updater.shared.status { Updater.shared.status = .downloading(fraction) }
            }
        }
        status = .installing
        try await Self.replace(app, withAppIn: image, digest: asset.digest, workDir: work)
    }

    // MARK: Steps (off the main actor)

    nonisolated private static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw UpdateError.noRelease }
        guard (200..<300).contains(code) else { throw UpdateError.http(code) }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// "1.0.10" is newer than "1.0.9"; a pre-release ("1.1.0-beta.1") is older than its release.
    nonisolated private static func isVersion(_ a: String, newerThan b: String) -> Bool {
        switch a.prefix(while: { $0 != "-" }).compare(b.prefix(while: { $0 != "-" }), options: .numeric) {
        case .orderedDescending: true
        case .orderedAscending: false
        case .orderedSame: b.contains("-") && !a.contains("-")
        }
    }

    nonisolated private static func download(_ url: URL, to file: URL,
                                             progress: @escaping @Sendable (Double) -> Void) async throws {
        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                if let error { cont.resume(throwing: error); return }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(code), let tmp else { cont.resume(throwing: UpdateError.http(code)); return }
                do {
                    try FileManager.default.moveItem(at: tmp, to: file)
                    cont.resume()
                } catch { cont.resume(throwing: error) }
            }
            observation = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
            task.resume()
        }
    }

    /// Checks the disk image and the app inside it, then swaps that app in for `app`.
    nonisolated private static func replace(_ app: URL, withAppIn image: URL, digest: String?, workDir: URL) async throws {
        if let digest, digest.hasPrefix("sha256:") {
            let actual = SHA256.hash(data: try Data(contentsOf: image)).map { String(format: "%02x", $0) }.joined()
            guard actual == digest.dropFirst("sha256:".count).lowercased() else { throw UpdateError.checksumMismatch }
        }

        let fm = FileManager.default
        let volume = workDir.appending(path: "volume")
        try fm.createDirectory(at: volume, withIntermediateDirectories: true)
        try hdiutil("attach", image.path, "-mountpoint", volume.path, "-readonly", "-nobrowse", "-noautoopen", "-quiet")
        defer { try? hdiutil("detach", volume.path, "-force", "-quiet") }

        let staged = workDir.appending(path: app.lastPathComponent)
        try fm.copyItem(at: volume.appending(path: "OpenSpell.app"), to: staged)
        try verifySignature(of: staged)
        _ = try fm.replaceItemAt(app, withItemAt: staged)
    }

    nonisolated private static func hdiutil(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.mountFailed }
    }

    /// Only accepts OpenSpell signed with the release Developer ID — the identity macOS ties the
    /// Accessibility permission to, so the permission carries over to the new version.
    nonisolated private static func verifySignature(of app: URL) throws {
        let requirement = "identifier \"app.openspell.OpenSpell\" and anchor apple generic"
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"      // Developer ID CA
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"  // Developer ID Application
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        var code: SecStaticCode?
        var rule: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &rule) == errSecSuccess,
              SecStaticCodeCheckValidity(code, flags, rule) == errSecSuccess
        else { throw UpdateError.untrusted }
    }

    /// Quits, then reopens `app` once this process is gone (so the new copy can claim the shortcut).
    private static func relaunch(_ app: URL) throws {
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; open \"$2\"",
                            "sh", String(ProcessInfo.processInfo.processIdentifier), app.path]
        try reopen.run()
        NSApp.terminate(nil)
    }
}
