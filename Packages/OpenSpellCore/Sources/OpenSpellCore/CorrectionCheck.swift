import Foundation

/// Tells a corrected copy of a text apart from what models sometimes return instead: a reply, a translation,
/// a summary, only part of the text, or the text with a label or notes around it.
enum CorrectionCheck {
    /// `output` if it is `original` corrected; else the part of it that is, when the model put a label, a preamble
    /// or notes around it; else nil.
    static func correction(in output: String, of original: String) -> String? {
        guard !output.allSatisfy(\.isWhitespace) else { return nil }
        let before = words(in: original)
        let verdict = assess(output, against: before)
        if verdict.accepted { return output }
        // Cutting lines off can't bring back missing words.
        guard verdict.kept * 2 >= before.count else { return nil }
        return candidates(in: output).first { assess($0, against: before).accepted }
    }

    // MARK: Assessment

    private struct Word {
        /// Lowercased, without accents or punctuation, so fixing those doesn't count as a change.
        let key: String
        let range: Range<String.Index>
    }

    private static func assess(_ output: String, against before: [Word]) -> (accepted: Bool, kept: Int) {
        let after = words(in: output)
        let n = before.count
        guard n > 0 else { return (after.isEmpty, 0) }
        guard 2 * after.count + 4 >= n else { return (false, 0) }

        let alignment = Alignment(before.map(\.key), after.map(\.key))
        let steps = alignment.steps
        guard let first = steps.firstIndex(where: \.isKept), let last = steps.lastIndex(where: \.isKept),
              case .kept(let firstKept) = steps[first], case .kept(let lastKept) = steps[last] else { return (false, 0) }
        let head = steps[..<first], tail = steps[(last + 1)...]
        let headAdded = head.compactMap(\.insertion), tailAdded = tail.compactMap(\.insertion)

        // A label or a line before the text ("Corrected text:"), or a note on its own line after it.
        if let j = headAdded.last,
           output[after[j].range.upperBound..<after[firstKept].range.lowerBound].contains(where: { $0 == ":" || $0.isNewline }) {
            return (false, alignment.kept)
        }
        if let j = tailAdded.first, output[after[lastKept].range.upperBound..<after[j].range.lowerBound].contains(where: \.isNewline) {
            return (false, alignment.kept)
        }
        let accepted = alignment.kept * 2 >= n
            // A correction changes a few words, and keeps some exactly as they were unless it only fixes spelling.
            && alignment.edits <= max(2, n / 4) && (alignment.exact > 0 || alignment.edits == 0)
            // Replies, continuations and answers that stop early begin or end differently.
            && headAdded.count <= 1 && tailAdded.count <= 1
            && head.count - headAdded.count <= 1 && tail.count - tailAdded.count <= 1
        return (accepted, alignment.kept)
    }

    /// Lines the output's words up with the original's: equal words first (a diff), then, within each run of
    /// differences, misspelled words with their fixes and split or joined words ("alot" → "a lot").
    private struct Alignment {
        enum Step {
            case kept(Int), added(Int), dropped

            var isKept: Bool { if case .kept = self { true } else { false } }
            var insertion: Int? { if case .added(let j) = self { j } else { nil } }
        }

        /// The output's words in order (by index), with the original's dropped words where they were.
        var steps: [Step] = []
        /// The original's words found in the output, as they were or corrected.
        var kept = 0
        /// The original's words found exactly as they were.
        var exact = 0
        /// Words added, removed or replaced by a different word.
        var edits = 0

        init(_ a: [String], _ b: [String]) {
            var removed = Set<Int>(), inserted = Set<Int>()
            for change in b.difference(from: a) {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
            var i = 0, j = 0
            while i < a.count || j < b.count {
                let i0 = i, j0 = j
                while i < a.count, removed.contains(i) { i += 1 }
                while j < b.count, inserted.contains(j) { j += 1 }
                differences(a[i0..<i], b, j0..<j)
                guard i < a.count, j < b.count else { break }
                steps.append(.kept(j))
                kept += 1
                exact += 1
                i += 1
                j += 1
            }
        }

        /// Pairs the original's words `old` with the output's words in `range` that replaced them.
        private mutating func differences(_ old: ArraySlice<String>, _ b: [String], _ range: Range<Int>) {
            if old.count != range.count, !old.isEmpty, !range.isEmpty, old.count + range.count <= 6,
               CorrectionCheck.distance(Array(old.joined()), Array(b[range].joined())) <= 1 {
                steps += range.map { .kept($0) }
                kept += old.count
                return
            }
            var next = range.lowerBound, pairs = 0
            for word in old {
                // Fixes sit next to each other, so only look a few words ahead.
                let window = next..<min(range.upperBound, next + 8)
                if let match = window.first(where: { CorrectionCheck.isTypo(word, b[$0]) }) {
                    steps += (next..<match).map { .added($0) }
                    steps.append(.kept(match))
                    next = match + 1
                    pairs += 1
                } else {
                    steps.append(.dropped)
                }
            }
            steps += (next..<range.upperBound).map { .added($0) }
            kept += pairs
            edits += max(old.count, range.count) - pairs
        }
    }

    /// Whether `b` is `a` with a typo fixed: up to 40 % of its letters changed.
    private static func isTypo(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        let limit = max(1, max(x.count, y.count) * 2 / 5)
        return abs(x.count - y.count) <= limit && distance(x, y) <= limit
    }

    /// Insertions, deletions, substitutions and swaps of neighbours that turn `x` into `y`.
    private static func distance(_ x: [Character], _ y: [Character]) -> Int {
        guard !x.isEmpty, !y.isEmpty else { return max(x.count, y.count) }
        var older = [Int](repeating: 0, count: y.count + 1)
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    current[j] = min(current[j], older[j - 2] + 1)
                }
            }
            (older, previous, current) = (previous, current, older)
        }
        return previous[y.count]
    }

    private static func words(in text: String) -> [Word] {
        var words: [Word] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
            guard let word else { return }
            let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            let key = String(folded.unicodeScalars.filter(CharacterSet.alphanumerics.contains))
            if !key.isEmpty { words.append(Word(key: key, range: range)) }
        }
        return words
    }

    // MARK: Salvage

    /// The output without up to three lines at either end, or without a short label ("Corrected text: …"),
    /// fewest cuts first.
    private static func candidates(in output: String) -> [String] {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        var result = [unlabeled(output)].compactMap { $0 }
        for cut in 1..<min(lines.count, 7) {
            for head in max(0, cut - 3)...min(cut, 3) {
                let text = lines[head..<(lines.count - cut + head)].joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                result.append(text)
                if let text = unlabeled(text) { result.append(text) }
            }
        }
        return result
    }

    /// The text after a label of up to six words that ends with a colon on its first line.
    private static func unlabeled(_ text: String) -> String? {
        guard let colon = text.firstIndex(of: ":"), !text[..<colon].contains(where: \.isNewline),
              text[..<colon].split(whereSeparator: \.isWhitespace).count <= 6 else { return nil }
        let rest = text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? nil : rest
    }
}
