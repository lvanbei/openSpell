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

@MainActor
public final class HistoryStore: ObservableObject {
    public static let shared = HistoryStore()
    public static let limit = 1000

    @Published public private(set) var items: [HistoryItem] = []

    private let url = SharedStorage.directory.appending(path: "history.json")

    private init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            items = decoded
        }
    }

    public func add(_ item: HistoryItem) {
        items.insert(item, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
    }

    public func delete(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        save()
    }

    public func clear() {
        items.removeAll()
        save()
    }

    private func save() {
        let snapshot = items
        let url = url
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: [.atomic, .completeFileProtection])
            }
        }
    }
}
