import Foundation

/// Splits text into consecutive pieces that each fit a model's input budget, cutting at paragraph breaks,
/// then sentence ends, then spaces. Joining the pieces gives back the text exactly.
enum TextChunker {
    static func chunks(of text: String, budget: Int, cost: (Substring) -> Int) -> [Substring] {
        var chunks: [Substring] = []
        var start: String.Index?
        var end = text.startIndex
        for unit in units(of: text[...], level: 0, budget: budget, cost: cost) {
            if let start, cost(text[start..<unit.endIndex]) <= budget {
                end = unit.endIndex
                continue
            }
            if let start { chunks.append(text[start..<end]) }
            start = unit.startIndex
            end = unit.endIndex
        }
        if let start { chunks.append(text[start..<end]) }
        return chunks
    }

    /// Pieces that fit the budget: paragraphs, else sentences, else words, else runs of characters.
    private static func units(of text: Substring, level: Int, budget: Int, cost: (Substring) -> Int) -> [Substring] {
        guard cost(text) > budget else { return [text] }
        let parts: [Substring]
        switch level {
        case 0: parts = cut(text, after: \.isNewline)
        case 1: parts = sentences(of: text)
        case 2: parts = cut(text, after: \.isWhitespace)
        default: return hardSplit(text, budget: budget, cost: cost)
        }
        return parts.flatMap { units(of: $0, level: level + 1, budget: budget, cost: cost) }
    }

    /// Cuts after every run of separators, which stay with the piece before them.
    private static func cut(_ text: Substring, after isSeparator: (Character) -> Bool) -> [Substring] {
        var parts: [Substring] = []
        var start = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            guard isSeparator(text[i]) else {
                i = text.index(after: i)
                continue
            }
            while i < text.endIndex, isSeparator(text[i]) { i = text.index(after: i) }
            parts.append(text[start..<i])
            start = i
        }
        if start < text.endIndex { parts.append(text[start...]) }
        return parts
    }

    private static func sentences(of text: Substring) -> [Substring] {
        var ends: [String.Index] = []
        text.base.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences, .substringNotRequired]) { _, _, enclosing, _ in
            ends.append(enclosing.upperBound)
        }
        var parts: [Substring] = []
        var start = text.startIndex
        for end in ends where end > start && end < text.endIndex {
            parts.append(text[start..<end])
            start = end
        }
        parts.append(text[start...])
        return parts
    }

    private static func hardSplit(_ text: Substring, budget: Int, cost: (Substring) -> Int) -> [Substring] {
        var parts: [Substring] = []
        var start = text.startIndex
        var end = text.startIndex
        while end < text.endIndex {
            let next = text.index(after: end)
            if end > start, cost(text[start..<next]) > budget {
                parts.append(text[start..<end])
                start = end
            }
            end = next
        }
        parts.append(text[start...])
        return parts
    }
}
