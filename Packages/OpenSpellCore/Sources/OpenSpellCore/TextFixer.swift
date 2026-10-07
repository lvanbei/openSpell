import Foundation
import os

/// The parts of UIKit's `UITextDocumentProxy` that a fix needs, so tests can use a fake document.
@MainActor
public protocol TextProxy: AnyObject {
    var documentContextBeforeInput: String? { get }
    var documentContextAfterInput: String? { get }
    var selectedText: String? { get }
    var documentIdentifier: UUID { get }
    /// Counts the host's reports of its document (`textDidChange`/`selectionDidChange`).
    var hostUpdates: Int { get }
    func insertText(_ text: String)
    func deleteBackward()
    func adjustTextPosition(byCharacterOffset offset: Int)
}

/// Writes corrections into a keyboard's document. It only edits when the document still holds the text that
/// was captured, uses the fewest keystrokes, checks the result and can undo the last fix.
///
/// The keyboard's view of the document is a cache: its own edits update it right away, but text typed, pasted or
/// dictated any other way may never reach it. Moving the caret makes the host report its real context, so every
/// decision here is made right after such a report (see `refresh`), never on the cache alone.
@MainActor
public final class TextFixer {
    public struct Capture: Equatable, Sendable {
        public let text: String
        public let isSelection: Bool
        public let documentID: UUID
    }

    public enum Result: Equatable, Sendable {
        case replaced
        /// Written, but the host's report afterwards didn't show the corrected text.
        case unverified
        /// The text changed meanwhile, so nothing was written.
        case textChanged
        /// The host didn't report its text, so nothing was written (a selection still works there).
        case unreadable
    }

    private struct Fix {
        let documentID: UUID
        let original: String
        let corrected: String
    }

    private var lastFix: Fix?
    private let timeout: Duration
    private let settle: Duration
    private let logger = Logger(subsystem: "app.openspell", category: "TextFixer")

    /// `settle` is how long the host must stay quiet before a report counts as its last word.
    public init(timeout: Duration = .milliseconds(1500), settle: Duration = .milliseconds(60)) {
        self.timeout = timeout
        self.settle = settle
    }

    public var canUndo: Bool { lastFix != nil }

    /// The selection if there is one, else the text before the caret (hosts often share only the current paragraph).
    /// Call `refresh` first.
    public static func capture(from proxy: TextProxy) -> Capture? {
        if let selection = proxy.selectedText, !selection.isEmpty {
            // Typing into a selection replaces it, so never fall back to the text before the caret here.
            guard !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Capture(text: selection, isSelection: true, documentID: proxy.documentIdentifier)
        }
        let before = proxy.documentContextBeforeInput ?? ""
        guard !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Capture(text: before, isSelection: false, documentID: proxy.documentIdentifier)
    }

    /// Steps the caret back and forward over one character so the host reports its real context.
    /// Returns false if the host didn't answer or the caret didn't come back to where it was.
    public func refresh(_ proxy: TextProxy) async -> Bool {
        // Selection changes are reported as they happen, and moving the caret would drop the selection.
        if let selection = proxy.selectedText, !selection.isEmpty { return true }
        let before = proxy.documentContextBeforeInput ?? ""
        // Offsets count UTF-16 units, so step over a whole emoji rather than into it.
        let step = before.last.map { String($0).utf16.count } ?? 1
        let start = proxy.hostUpdates
        proxy.adjustTextPosition(byCharacterOffset: -step)
        guard await waitForHost(after: start, in: proxy, timeout: before.isEmpty ? .milliseconds(300) : timeout) else {
            return before.isEmpty
        }
        let stepped = String((proxy.documentContextAfterInput ?? "").dropFirst())
        let back = proxy.hostUpdates
        proxy.adjustTextPosition(byCharacterOffset: step)
        guard await waitForHost(after: back, in: proxy, timeout: timeout) else { return false }
        let after = proxy.documentContextAfterInput ?? ""
        return stepped.hasPrefix(after) || after.hasPrefix(stepped)
    }

    public func apply(_ corrected: String, over capture: Capture, in proxy: TextProxy) async -> Result {
        guard await refresh(proxy) else { return .unreadable }
        let unchanged = capture.isSelection
            ? proxy.selectedText == capture.text
            : Self.contextEnds(with: capture.text, in: proxy)
        guard proxy.documentIdentifier == capture.documentID, unchanged else { return .textChanged }

        if capture.isSelection {
            proxy.insertText(corrected)
        } else {
            let plan = ReplacementPlanner.plan(from: capture.text, to: corrected)
            guard await edit(plan, of: capture.text, in: proxy) else { return .textChanged }
        }
        lastFix = Fix(documentID: capture.documentID, original: capture.text, corrected: corrected)
        let verified = await refresh(proxy) && Self.contextEnds(with: corrected, in: proxy)
        return verified ? .replaced : .unverified
    }

    /// Puts the original text back, as long as the document still ends with the last fix.
    public func undo(in proxy: TextProxy) async -> Bool {
        guard let fix = lastFix, proxy.documentIdentifier == fix.documentID, await refresh(proxy),
              Self.contextEnds(with: fix.corrected, in: proxy) else { return false }
        lastFix = nil
        let plan = ReplacementPlanner.plan(from: fix.corrected, to: fix.original)
        guard await edit(plan, of: fix.corrected, in: proxy) else { return false }
        return await refresh(proxy) && Self.contextEnds(with: fix.original, in: proxy)
    }

    public func forgetLastFix() {
        lastFix = nil
    }

    /// Whether the text before the caret is consistent with `text` ending at the caret (hosts may show less of it).
    static func contextEnds(with text: String, in proxy: TextProxy) -> Bool {
        guard !text.isEmpty else { return true }
        let before = proxy.documentContextBeforeInput ?? ""
        return !before.isEmpty && (before.hasSuffix(text) || text.hasSuffix(before))
    }

    static func contextStarts(with text: String, in proxy: TextProxy) -> Bool {
        guard !text.isEmpty else { return true }
        let after = proxy.documentContextAfterInput ?? ""
        return !after.isEmpty && (after.hasPrefix(text) || text.hasPrefix(after))
    }

    /// Applies `plan` to `text`, which ends at the caret. Returns false, having deleted nothing, if the caret
    /// can't be confirmed back at the end of `text`.
    private func edit(_ plan: ReplacementPlan, of text: String, in proxy: TextProxy) async -> Bool {
        var plan = plan
        if !plan.keptSuffix.isEmpty {
            let start = proxy.hostUpdates
            proxy.adjustTextPosition(byCharacterOffset: -plan.caretOffset)
            let head = String(text.dropLast(plan.keptSuffix.count))
            let landed = await waitForHost(after: start, in: proxy, timeout: timeout)
                && Self.contextEnds(with: head, in: proxy) && Self.contextStarts(with: plan.keptSuffix, in: proxy)
            logger.notice("Caret move of \(plan.caretOffset) UTF-16 units \(landed ? "landed" : "missed, retyping the tail", privacy: .public)")
            if !landed {
                // The host counts offsets differently: step back to the end and retype the tail instead.
                let back = proxy.hostUpdates
                proxy.adjustTextPosition(byCharacterOffset: plan.caretOffset)
                guard await waitForHost(after: back, in: proxy, timeout: timeout),
                      Self.contextEnds(with: text, in: proxy) else { return false }
                plan = ReplacementPlan(keptSuffix: "", deletions: plan.deletions + plan.keptSuffix.count,
                                       insertion: plan.insertion + plan.keptSuffix)
            }
        }
        for _ in 0..<plan.deletions { proxy.deleteBackward() }
        if !plan.insertion.isEmpty { proxy.insertText(plan.insertion) }
        if !plan.keptSuffix.isEmpty { proxy.adjustTextPosition(byCharacterOffset: plan.caretOffset) }
        return true
    }

    /// Waits for a host report newer than `count`, then until the host has been quiet for `settle`.
    private func waitForHost(after count: Int, in proxy: TextProxy, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while proxy.hostUpdates <= count {
            if ContinuousClock.now >= deadline || Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        var seen = proxy.hostUpdates
        while true {
            try? await Task.sleep(for: settle)
            if proxy.hostUpdates == seen || ContinuousClock.now >= deadline { return !Task.isCancelled }
            seen = proxy.hostUpdates
        }
    }
}
