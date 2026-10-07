import Combine
import Foundation

public struct HistoryItem: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var original: String
    public var corrected: String
    public var appName: String
    public var bundleID: String?
    public var model: String
    public var duration: TimeInterval

    public init(original: String, corrected: String, appName: String, bundleID: String?, model: String,
                duration: TimeInterval) {
        self.original = original
        self.corrected = corrected
        self.appName = appName
        self.bundleID = bundleID
        self.model = model
        self.duration = duration
    }
}

/// The correction log. On iOS the app and the keyboard both write it, so every change is applied to the
/// latest file contents under NSFileCoordinator instead of overwriting the file with a stale copy.
@MainActor
public final class HistoryStore: ObservableObject {
    public static let shared = HistoryStore()
    public nonisolated static let limit = 1000

    @Published public private(set) var items: [HistoryItem] = []

    nonisolated private static let url = SharedStorage.directory.appending(path: "history.json")
    nonisolated private static let queue = DispatchQueue(label: "app.openspell.history", qos: .utility)

    private init() {
        items = Self.read()
    }

    /// Re-reads the file, e.g. after the iOS keyboard logged corrections.
    public func reload() {
        items = Self.read()
    }

    public func add(_ item: HistoryItem) {
        change { Self.insert(item, into: &$0) }
    }

    public func delete(_ ids: Set<UUID>) {
        change { $0.removeAll { ids.contains($0.id) } }
    }

    public func clear() {
        change { $0.removeAll() }
    }

    /// Logs a correction without loading the history into memory (the iOS keyboard has little to spare).
    public nonisolated static func record(_ item: HistoryItem) {
        persist { insert(item, into: &$0) }
    }

    private func change(_ edit: @escaping @Sendable (inout [HistoryItem]) -> Void) {
        edit(&items)
        Self.persist(edit)
    }

    nonisolated private static func insert(_ item: HistoryItem, into items: inout [HistoryItem]) {
        items.insert(item, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
    }

    nonisolated private static func decode(_ url: URL) -> [HistoryItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([HistoryItem].self, from: data)) ?? []
    }

    nonisolated private static func read() -> [HistoryItem] {
        var items: [HistoryItem] = []
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { items = decode($0) }
        return items
    }

    nonisolated private static func persist(_ edit: @escaping @Sendable (inout [HistoryItem]) -> Void) {
        queue.async {
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: nil) { url in
                var items = decode(url)
                edit(&items)
                if let data = try? JSONEncoder().encode(items) {
                    try? data.write(to: url, options: [.atomic, .completeFileProtection])
                }
            }
        }
    }
}
