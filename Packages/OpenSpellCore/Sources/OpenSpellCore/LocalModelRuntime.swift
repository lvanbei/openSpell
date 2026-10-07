import Foundation

/// Runs and downloads on-device models. The macOS app provides one backed by MLX; iOS has none.
public protocol LocalModelRuntime: Sendable {
    func makeDownloader() -> any ModelDownloader
    func complete(directory: URL, extraEOSTokens: Set<String>, system: String, user: String) async throws -> String
    func preload(directory: URL, extraEOSTokens: Set<String>) async throws
    func unload() async
}

public protocol ModelDownloader: AnyObject, Sendable {
    /// `progress` gets 0…1, possibly from a background thread.
    func download(repo: String, to destination: URL, revision: String,
                  progress: @escaping @Sendable (Double) -> Void) async throws
    func cancel()
}
