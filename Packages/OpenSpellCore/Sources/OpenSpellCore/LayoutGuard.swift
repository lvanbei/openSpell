import Foundation

/// Puts back what a model changed in a text's layout and markup while correcting it: the whitespace between the
/// words it kept (line breaks, blank lines, tabs, indentation, runs of spaces, non-breaking spaces), list and
/// Markdown markers, and URLs, email addresses, paths, numbers, mentions and code. Works on whitespace-separated
/// tokens, so the model's fixes to the words themselves stay.
enum LayoutGuard {
    static func restore(_ corrected: String, from original: String) -> String {
        let a = Layout(original), b = Layout(corrected)
        var out = ""
        // The original's token that the last written one stands for, when it stands for one.
        var previous: Int?

        func write(_ gap: Substring, _ token: Substring) {
            out += gap
            out += token
        }

        for segment in segments(a.tokens.map(key), b.tokens.map(key)) {
            switch segment {
            case let .same(i, j):
                write(gap(before: i, after: previous, in: a, else: b.gaps[j]), token(i, of: a, fixedAs: b.tokens[j]))
                previous = i
            case let .hunk(old, new) where old.count == new.count:
                // Words replaced one for one ("teh" → "the").
                for (i, j) in zip(old, new) {
                    write(gap(before: i, after: previous, in: a, else: b.gaps[j]), token(i, of: a, fixedAs: b.tokens[j]))
                    previous = i
                }
            case let .hunk(old, new) where old.count > new.count
                && old.count { !isKeptAsIs($0, in: a) } == new.count:
                // Markers or protected tokens dropped, maybe next to fixed words ("- teh" → "The"): put them back.
                var j = new.lowerBound
                for i in old {
                    if isKeptAsIs(i, in: a) {
                        write(gap(before: i, after: previous, in: a, else: i == 0 ? "" : a.gaps[i]), a.tokens[i])
                    } else {
                        write(gap(before: i, after: previous, in: a, else: b.gaps[j]), token(i, of: a, fixedAs: b.tokens[j]))
                        j += 1
                    }
                    previous = i
                }
            case let .hunk(_, new) where new.isEmpty:
                // Dropped words: the next gap is chosen among the original's gaps around them.
                continue
            case let .hunk(old, new) where old.isEmpty:
                // Added words. If the model also dropped the line break or tab where they were added, put it
                // back before them: added words usually belong to the next one ("I went\nthe store").
                let lost = previous != nil && old.lowerBound < a.tokens.count ? a.gaps[old.lowerBound] : " "
                let keepsLost = b.gaps[new.lowerBound...new.upperBound].contains(lost)
                for j in new {
                    write(j == new.lowerBound && lost != " " && !keepsLost ? lost : b.gaps[j], b.tokens[j])
                }
                previous = nil
            case let .hunk(old, new):
                // Words split or joined ("alot" → "a lot"): keep the original's gaps around them.
                for j in new {
                    write(j == new.lowerBound ? gap(before: old.lowerBound, after: previous, in: a, else: b.gaps[j]) : b.gaps[j],
                          b.tokens[j])
                }
                previous = old.upperBound - 1
            }
        }
        return out + b.gaps[b.tokens.count]
    }

    // MARK: Gaps

    /// The whitespace to write before the original's token `i`, after the one standing for `previous`.
    private static func gap(before i: Int, after previous: Int?, in a: Layout, else modelGap: Substring) -> Substring {
        guard let previous, previous < i else { return modelGap }
        let gaps = a.gaps[(previous + 1)...i]
        if gaps.count == 1 { return gaps.first! }
        // Words were dropped in between: keep the original's line break or tab there, else the model's gap if the
        // original had it, else the original's first run of spaces.
        if let structural = gaps.first(where: { $0.contains { $0.isNewline || $0 == "\t" } }) { return structural }
        if gaps.contains(modelGap) { return modelGap }
        return gaps.first { $0 != " " } ?? modelGap
    }

    // MARK: Tokens

    /// The model's version of the original's token `i`, unless it broke a protected token, a marker or markup.
    private static func token(_ i: Int, of a: Layout, fixedAs fixed: Substring) -> Substring {
        let original = a.tokens[i]
        guard fixed != original else { return fixed }
        // Punctuation added around a URL or a number is a fix; a change inside it isn't.
        if isProtected(original) { return fixed.contains(original) ? fixed : original }
        if isMarker(at: i, in: a) { return original }
        let markup = original.filter(isMarkup)
        guard fixed.filter(isMarkup) != markup else { return fixed }
        // "**teh**" corrected as "the": the fix, inside the original's markup.
        let (head, tail) = edges(of: original)
        let merged = head + core(of: fixed) + tail
        return merged.filter(isMarkup) == markup ? Substring(merged) : original
    }

    private static func isMarkup(_ c: Character) -> Bool { "*_~`|<>[]{}\\".contains(c) }

    /// Tokens the model must never drop: markers and protected tokens.
    private static func isKeptAsIs(_ i: Int, in a: Layout) -> Bool {
        isProtected(a.tokens[i]) || isMarker(at: i, in: a)
    }

    /// URLs, domains and file names, email addresses, paths, numbers like 3.5 or 10:30, @mentions, #hashtags,
    /// identifiers, code and placeholders.
    static func isProtected(_ token: Substring) -> Bool {
        let lower = token.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") || token.contains(where: { "`{}\\".contains($0) }) {
            return true
        }
        if let first = token.first, first == "@" || first == "#",
           let second = token.dropFirst().first, second.isLetter || second.isNumber {
            return true
        }
        let chars = Array(token)
        guard chars.count >= 3 else { return false }
        for k in 1..<(chars.count - 1) {
            let before = chars[k - 1], c = chars[k], after = chars[k + 1]
            guard before.isLetter || before.isNumber else { continue }
            if c == "@", chars[(k + 1)...].contains(".") { return true }
            if "_/".contains(c), after.isLetter || after.isNumber { return true }
            if c == ".", after.isLowercase { return true }
            if ".,:".contains(c), before.isNumber, after.isNumber { return true }
        }
        return false
    }

    /// A list, heading or quote marker at the start of a line: "-", "*", "•", "##", ">", "1.", "a)".
    private static func isMarker(at i: Int, in a: Layout) -> Bool {
        guard i == 0 || a.gaps[i].contains(where: \.isNewline) else { return false }
        let token = a.tokens[i]
        if token.allSatisfy({ "-*+•·◦▪‣–—>#|=".contains($0) }) { return true }
        guard let last = token.last, last == "." || last == ")" else { return false }
        let label = token.dropLast()
        return !label.isEmpty && label.count <= 3 && label.allSatisfy { $0.isNumber || $0.isLetter }
    }

    /// The punctuation and markup before the token's first letter or digit, and after its last.
    private static func edges(of token: Substring) -> (head: Substring, tail: Substring) {
        guard let first = token.firstIndex(where: { $0.isLetter || $0.isNumber }),
              let last = token.lastIndex(where: { $0.isLetter || $0.isNumber }) else { return (token, "") }
        return (token[..<first], token[token.index(after: last)...])
    }

    private static func core(of token: Substring) -> Substring {
        guard let first = token.firstIndex(where: { $0.isLetter || $0.isNumber }),
              let last = token.lastIndex(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return token[first...last]
    }

    // MARK: Alignment

    /// Lowercased letters and digits without accents, so fixing those doesn't count as a change; punctuation-only
    /// tokens keep their characters.
    private static func key(_ token: Substring) -> String {
        let folded = token.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let key = String(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains))
        return key.isEmpty ? String(token) : key
    }

    private enum Segment {
        case same(Int, Int)
        /// The original's tokens `old` became the corrected tokens `new`.
        case hunk(Range<Int>, Range<Int>)
    }

    private static func segments(_ a: [String], _ b: [String]) -> [Segment] {
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var segments: [Segment] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            let i0 = i, j0 = j
            while i < a.count, removed.contains(i) { i += 1 }
            while j < b.count, inserted.contains(j) { j += 1 }
            if i > i0 || j > j0 { segments.append(.hunk(i0..<i, j0..<j)) }
            guard i < a.count, j < b.count else { break }
            segments.append(.same(i, j))
            i += 1
            j += 1
        }
        return segments
    }
}

/// A text as tokens separated by whitespace. `gaps[k]` is the whitespace before `tokens[k]`; the last gap ends the text.
private struct Layout {
    var tokens: [Substring] = []
    var gaps: [Substring] = []

    init(_ text: String) {
        var i = text.startIndex, gapStart = i
        while i < text.endIndex {
            guard !text[i].isWhitespace else {
                i = text.index(after: i)
                continue
            }
            gaps.append(text[gapStart..<i])
            let start = i
            while i < text.endIndex, !text[i].isWhitespace { i = text.index(after: i) }
            tokens.append(text[start..<i])
            gapStart = i
        }
        gaps.append(text[gapStart...])
    }
}
