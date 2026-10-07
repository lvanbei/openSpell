import Foundation
@testable import OpenSpellCore

/// An in-memory host text field that behaves like UIKit's keyboard document proxy as measured in the Simulator:
/// the keyboard sees a cached context that its own edits update at once, while the host only reports its real
/// text after caret moves (late, partially, or never), and may count caret offsets in UTF-16 units or characters.
@MainActor
final class FakeDocument: TextProxy {
    enum OffsetUnit { case utf16, characters }

    private(set) var text: [Character]
    private(set) var caret: Int
    private var selection: Range<Int>?
    var documentIdentifier = UUID()
    var unit = OffsetUnit.utf16
    var contextLimit = 100_000
    var updateDelay = Duration.zero
    var frozen = false
    private(set) var hostUpdates = 0
    /// insertText and deleteBackward calls (caret moves excluded).
    private(set) var textEdits = 0

    private var cachedBefore = ""
    private var cachedAfter = ""
    private var cachedSelection: String?

    init(_ string: String, selecting range: Range<Int>? = nil, contextLimit: Int = 100_000) {
        text = Array(string)
        caret = range?.upperBound ?? text.count
        selection = range
        self.contextLimit = contextLimit
        report()
    }

    var string: String { String(text) }

    var documentContextBeforeInput: String? { cachedBefore }
    var documentContextAfterInput: String? { cachedAfter }
    var selectedText: String? { cachedSelection }

    func insertText(_ s: String) {
        removeSelection()
        text.insert(contentsOf: Array(s), at: caret)
        caret += s.count
        cachedBefore += s
        cachedSelection = nil
        textEdits += 1
    }

    func deleteBackward() {
        if selection != nil {
            removeSelection()
        } else if caret > 0 {
            text.remove(at: caret - 1)
            caret -= 1
            cachedBefore = String(cachedBefore.dropLast())
        }
        cachedSelection = nil
        textEdits += 1
    }

    func adjustTextPosition(byCharacterOffset offset: Int) {
        selection = nil
        switch unit {
        case .characters:
            caret = min(max(caret + offset, 0), text.count)
        case .utf16:
            let target = utf16Offset(caret) + offset
            caret = (0...text.count).first { utf16Offset($0) >= target } ?? text.count
        }
        scheduleReport()
    }

    /// Text typed, pasted or dictated without this keyboard: the host doesn't report it.
    func typeElsewhere(_ s: String) {
        text.insert(contentsOf: Array(s), at: caret)
        caret += s.count
    }

    private func utf16Offset(_ index: Int) -> Int { String(text[..<index]).utf16.count }

    private func removeSelection() {
        guard let range = selection else { return }
        text.removeSubrange(range)
        caret = range.lowerBound
        selection = nil
    }

    private func scheduleReport() {
        guard !frozen else { return }
        guard updateDelay > .zero else { return report() }
        let delay = updateDelay
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            if !self.frozen { self.report() }
        }
    }

    private func report() {
        let start = selection?.lowerBound ?? caret
        let end = selection?.upperBound ?? caret
        cachedBefore = String(text[max(0, start - contextLimit)..<start])
        cachedAfter = String(text[end..<min(text.count, end + contextLimit)])
        cachedSelection = selection.map { String(text[$0]) }
        hostUpdates += 1
    }
}
