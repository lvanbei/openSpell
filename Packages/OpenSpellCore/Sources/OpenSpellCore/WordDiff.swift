import SwiftUI

/// Word-level diff rendered as an AttributedString (removed = red strikethrough, added = green).
public enum WordDiff {
    static func tokens(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentIsSpace: Bool?
        for ch in s {
            let isSpace = ch.isWhitespace
            if let c = currentIsSpace, c != isSpace {
                result.append(current)
                current = ""
            }
            current.append(ch)
            currentIsSpace = isSpace
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    public static func attributed(from old: String, to new: String) -> AttributedString {
        let a = tokens(old), b = tokens(new)
        let diff = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var out = AttributedString()
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                var part = AttributedString(a[i])
                part.foregroundColor = .red
                part.strikethroughStyle = .single
                out += part
                i += 1
            } else if j < b.count, inserted.contains(j) {
                var part = AttributedString(b[j])
                part.foregroundColor = .green
                part.backgroundColor = .green.opacity(0.15)
                out += part
                j += 1
            } else {
                if j < b.count { out += AttributedString(b[j]) }
                i += 1
                j += 1
            }
        }
        return out
    }
}
