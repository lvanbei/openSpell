import OpenSpellCore
import OpenSpellUI
import SwiftUI

struct HistoryView: View {
    @ObservedObject private var store = HistoryStore.shared
    @State private var selection: UUID?
    @State private var search = ""
    @State private var confirmClear = false

    private var filtered: [HistoryItem] {
        guard !search.isEmpty else { return store.items }
        return store.items.filter {
            $0.original.localizedCaseInsensitiveContains(search) ||
            $0.corrected.localizedCaseInsensitiveContains(search) ||
            $0.appName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selection) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.appName).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(item.date, format: .relative(presentation: .named))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text(item.corrected).lineLimit(2).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .tag(item.id)
                .contextMenu {
                    Button("Copy corrected") { TextAccess.copyToClipboard(item.corrected) }
                    Button("Copy original") { TextAccess.copyToClipboard(item.original) }
                    Divider()
                    Button("Delete", role: .destructive) { store.delete([item.id]) }
                }
            }
            .searchable(text: $search, placement: .sidebar)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .overlay {
                if store.items.isEmpty {
                    ContentUnavailableView("No corrections yet", systemImage: "text.badge.checkmark",
                                           description: Text("Select text anywhere and press your shortcut."))
                }
            }
        } detail: {
            if let item = store.items.first(where: { $0.id == selection }) {
                HistoryDetail(item: item)
            } else {
                ContentUnavailableView("Select a correction", systemImage: "clock.arrow.circlepath")
            }
        }
        .toolbar {
            ToolbarItem {
                Button { confirmClear = true } label: { Label("Clear History", systemImage: "trash") }
                    .disabled(store.items.isEmpty)
            }
        }
        .confirmationDialog("Delete all corrections?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { store.clear() }
        }
        .frame(minWidth: 700, minHeight: 420)
    }
}

private struct HistoryDetail: View {
    let item: HistoryItem
    @State private var copied: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.appName).font(.title3.weight(.semibold))
                        Text("\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(item.model) · \(String(format: "%.1f", item.duration)) s")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(copied == "c" ? "Copied ✓" : "Copy corrected") { copy(item.corrected, tag: "c") }
                        .buttonStyle(.borderedProminent)
                    Button(copied == "o" ? "Copied ✓" : "Copy original") { copy(item.original, tag: "o") }
                }

                block(title: "Changes") {
                    Text(WordDiff.attributed(from: item.original, to: item.corrected)).textSelection(.enabled)
                }
                block(title: "Corrected") { Text(item.corrected).textSelection(.enabled) }
                block(title: "Original") { Text(item.original).textSelection(.enabled).foregroundStyle(.secondary) }
            }
            .padding(20)
        }
    }

    private func copy(_ s: String, tag: String) {
        TextAccess.copyToClipboard(s)
        copied = tag
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = nil }
    }

    private func block<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
