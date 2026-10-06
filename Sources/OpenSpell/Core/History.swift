import AppKit
import Combine

struct HistoryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var date = Date()
    var original: String
    var corrected: String
    var appName: String
    var bundleID: String?
    var model: String
    var duration: TimeInterval
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let limit = 1000

    @Published private(set) var items: [HistoryItem] = []

    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "OpenSpell", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "history.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            items = decoded
        }
    }

    func add(_ item: HistoryItem) {
        items.insert(item, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        save()
    }

    func delete(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func clear() {
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
