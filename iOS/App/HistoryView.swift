import OpenSpellCore
import OpenSpellUI
import SwiftUI

struct HistoryView: View {
    @ObservedObject private var store = HistoryStore.shared
    @State private var search = ""
    @State private var confirmClear = false

    private var items: [HistoryItem] {
        guard !search.isEmpty else { return store.items }
        return store.items.filter {
            $0.original.localizedCaseInsensitiveContains(search) || $0.corrected.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { item in
                    NavigationLink {
                        HistoryDetail(item: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.corrected).lineLimit(2)
                            Text("\(item.appName) · \(item.date, format: .relative(presentation: .named))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in store.delete(Set(offsets.map { items[$0].id })) }
            }
            .overlay {
                if store.items.isEmpty {
                    ContentUnavailableView("No corrections yet", systemImage: "text.badge.checkmark",
                                           description: Text("Fixes you make show up here."))
                }
            }
            .searchable(text: $search)
            .refreshable { store.reload() }
            .navigationTitle("History")
            .toolbar {
                Button("Clear", role: .destructive) { confirmClear = true }
                    .disabled(store.items.isEmpty)
            }
            .confirmationDialog("Delete all corrections?", isPresented: $confirmClear) {
                Button("Clear History", role: .destructive) { store.clear() }
            }
            .onAppear { store.reload() }
        }
    }
}

private struct HistoryDetail: View {
    let item: HistoryItem

    var body: some View {
        List {
            Section("Changes") {
                Text(WordDiff.attributed(from: item.original, to: item.corrected)).textSelection(.enabled)
            }
            Section("Corrected") {
                Text(item.corrected).textSelection(.enabled)
                Button("Copy corrected text") { UIPasteboard.general.string = item.corrected }
            }
            Section("Original") {
                Text(item.original).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Copy original text") { UIPasteboard.general.string = item.original }
            }
            Section {
                LabeledContent("Model", value: item.model)
                LabeledContent("Time", value: String(format: "%.1f s", item.duration))
                LabeledContent("Date", value: item.date.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .navigationTitle(item.appName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
