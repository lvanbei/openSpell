import Foundation

/// The fewest edits that turn the text just before the caret into its corrected version.
public struct ReplacementPlan: Equatable, Sendable {
    /// Unchanged text at the end that stays in place: step the caret back over it, edit, then step forward.
    public var keptSuffix: String
    /// `deleteBackward()` calls (one per character) made just before `keptSuffix`.
    public var deletions: Int
    public var insertion: String

    /// `adjustTextPosition` offset to step over `keptSuffix`; UIKit counts UTF-16 units.
    public var caretOffset: Int { keptSuffix.utf16.count }
    public var isEmpty: Bool { deletions == 0 && insertion.isEmpty }
}

public enum ReplacementPlanner {
    /// Short unchanged tails are retyped: moving the caret is less reliable than a few extra keystrokes.
    public static func plan(from original: String, to corrected: String, minKeptSuffix: Int = 40) -> ReplacementPlan {
        let a = Array(original), b = Array(corrected)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        if suffix < minKeptSuffix { suffix = 0 }
        return ReplacementPlan(keptSuffix: String(a[(a.count - suffix)...]),
                               deletions: a.count - prefix - suffix,
                               insertion: String(b[prefix..<(b.count - suffix)]))
    }
}
